import Foundation
import Combine
import Network

/// S02LB Wi-Fi 热点与 RTSP/FTP 业务协调器
///
/// 核心职责：
/// 1. 协调 BLE 命令下发与 Wi-Fi 热点自动连接 (NEHotspotConfiguration)；
/// 2. 状态机驱动：AP 就绪 -> 端口可达性探测 -> RTSP 启动 -> DESCRIBE 校验 -> 释放回收；
/// 3. 设备多媒体互斥管理：严格遵守硬件互斥规则（RTSP 推流中禁止拍照/录像/格式化）；
/// 4. 严密跟踪设备 RTSP_STOP 序列号确认，避免盲目切断导致固件死锁或重启。
public final class WifiRtspCoordinator: ObservableObject {
    
    public enum Phase: String {
        case off         = "关闭"
        case waitAp      = "等待热点与连接"
        case ready       = "热点与服务就绪"
        case waitRtsp    = "等待推流就绪"
        case streaming   = "推流传输中"
        case stopping    = "正在停止推流"
        case waitOff     = "等待关闭 WiFi"
        case failed      = "流程异常"
    }
    
    public static let shared = WifiRtspCoordinator()
    
    // MARK: - 响应式属性
    @Published public private(set) var phase: Phase = .off
    @Published public private(set) var statusText: String = "未开启"
    @Published public private(set) var isError: Bool = false
    @Published public private(set) var isWifiConnected: Bool = false
    @Published public private(set) var isFtpReady: Bool = false
    @Published public private(set) var isRtspReady: Bool = false
    @Published public var rtspUrl: String = "rtsp://192.168.43.1:554/6600"
    
    // MARK: - 回调
    public var onStartPlayer: ((String) -> Void)?
    public var onStopPlayer: (() -> Void)?
    
    private let bleManager = BleManager.shared
    private let hotspotManager = HotspotManager.shared
    private let prober = NetworkServiceProber.shared
    
    private var targetSSID: String = ""
    private var targetPassword: String = "12345678"
    
    private var wifiWanted: Bool = false
    private var rtspWanted: Bool = false
    private var previewWanted: Bool = false
    
    private var isStopPending: Bool = false
    private var stopConfirmed: Bool = false
    private var lastStopSequence: Int64 = -1
    private var pendingStopSequence: Int64 = -1
    
    private var generation: Int64 = 0
    private var timer: AnyCancellable?
    private var isProbing: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupSubscriptions()
        startPeriodicTicker()
    }
    
    private func setupSubscriptions() {
        // 监听 BLE 上行状态变化
        bleManager.$latestReport
            .compactMap { $0 }
            .sink { [weak self] report in
                self?.handleBleReport(report)
            }
            .store(in: &cancellables)
        
        // 监听热点管理器 Wi-Fi 物理连接状态
        hotspotManager.$isWifiActive
            .sink { [weak self] isActive in
                guard let self = self else { return }
                self.isWifiConnected = isActive
                if !isActive && (self.phase == .streaming || self.phase == .ready) {
                    self.show("Wi-Fi 已断开，等待重新连接...", isError: true)
                }
            }
            .store(in: &cancellables)
    }
    
    private func startPeriodicTicker() {
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }
    
    // MARK: - 公开控制动作
    
    /// 开启眼镜 WiFi 热点并自动加入
    public func enableWifi() {
        guard bleManager.isConnected else {
            show("请先连接眼镜蓝牙", isError: true)
            return
        }
        
        wifiWanted = true
        rtspWanted = false
        isStopPending = false
        generation += 1
        
        if phase != .stopping && phase != .waitOff {
            begin(phase: .waitAp)
        }
    }
    
    /// 关闭 WiFi 热点并断开关联
    public func disableWifi() {
        guard bleManager.isConnected else { return }
        
        generation += 1
        wifiWanted = false
        rtspWanted = false
        previewWanted = false
        
        stopRtspFlow()
    }
    
    /// 启动 RTSP 推流 (可选择是否立即渲染画面)
    public func startRtsp(url: String? = nil, preview: Bool = true) {
        guard bleManager.isConnected else {
            show("请先连接眼镜蓝牙", isError: true)
            return
        }
        
        if let customUrl = url, !customUrl.isEmpty {
            self.rtspUrl = customUrl
        }
        
        if isStopPending && phase == .failed {
            show("设备媒体资源尚未确认释放，请先重试停止 RTSP", isError: true)
            return
        }
        
        wifiWanted = true
        rtspWanted = true
        previewWanted = preview
        generation += 1
        
        if phase == .off || phase == .failed {
            begin(phase: .waitAp)
        }
    }
    
    /// 停止 RTSP 推流并等待设备释放硬件编码器
    public func stopRtsp() {
        guard bleManager.isConnected else { return }
        generation += 1
        rtspWanted = false
        previewWanted = false
        stopRtspFlow()
    }
    
    private func stopRtspFlow() {
        onStopPlayer?()
        if phase == .stopping { return }
        
        if isStopPending || isRtspReady || phase == .streaming {
            begin(phase: .stopping)
            isStopPending = true
            stopConfirmed = false
            S02Logger.shared.log("下发停止 RTSP 命令 (CMD_RTSP_STOP)...", tag: "WiFiFlow")
            bleManager.send(command: .rtspStop)
        } else {
            begin(phase: wifiWanted ? .waitAp : .waitOff)
        }
    }
    
    // MARK: - 内部状态机调度
    
    private func begin(phase target: Phase) {
        self.phase = target
        S02Logger.shared.log("状态机切换 -> \(target.rawValue)", tag: "WiFiFlow")
    }
    
    private func tick() {
        guard phase != .off && phase != .failed else { return }
        
        // 1. 停止推流中：等待设备释放确认
        if phase == .stopping {
            show("RTSP 正在停止，等待设备释放媒体资源...", isError: false)
            if stopConfirmed && !isRtspReady {
                isStopPending = false
                begin(phase: wifiWanted ? .ready : .waitOff)
            }
            return
        }
        
        // 2. 关闭热点中
        if !wifiWanted || phase == .waitOff {
            show("正在关闭 WiFi 传输...", isError: false)
            bleManager.send(command: .setWifiOff)
            if !targetSSID.isEmpty {
                hotspotManager.disconnectHotspot(ssid: targetSSID)
            }
            begin(phase: .off)
            return
        }
        
        // 3. 等待热点开启与连接
        if phase == .waitAp {
            show("下发开 WiFi 命令，等待热点就绪与手机连接...", isError: false)
            bleManager.send(command: .setWifiOn)
            
            // 如果已知 SSID 且当前未连上 Wi-Fi，尝试自动加入
            let ssid = self.targetSSID
            let pass = self.targetPassword
            if !ssid.isEmpty && !hotspotManager.isWifiActive && !hotspotManager.isConnectingHotspot {
                Task {
                    do {
                        try await self.hotspotManager.connectToHotspot(ssid: ssid, passphrase: pass)
                    } catch {
                        S02Logger.shared.log("自动关联热点重试: \(error.localizedDescription)", tag: "WiFiFlow")
                    }
                }
            }
            
            // 触发服务可达性探测
            triggerServiceProbe()
            return
        }
        
        // 4. 等待推流就绪
        if phase == .waitRtsp {
            show("热点已连接，下发推流命令并等待 RTSP DESCRIBE 响应...", isError: false)
            bleManager.send(command: .rtspStart)
            triggerServiceProbe()
            return
        }
        
        // 5. 推流中
        if phase == .streaming {
            if previewWanted {
                show("RTSP 推流中，已启动画面实时预览", isError: false)
            } else {
                show("RTSP 推流中 (未开启预览)", isError: false)
            }
        }
    }
    
    // MARK: - 服务探测执行
    
    private func triggerServiceProbe() {
        guard !isProbing, hotspotManager.isWifiActive else { return }
        isProbing = true
        let currentToken = generation
        let currentUrl = self.rtspUrl
        let wanted = self.rtspWanted
        
        Task {
            let host = URL(string: currentUrl)?.host ?? "192.168.43.1"
            let ftpOk = await prober.probeFtp(host: host)
            
            let finalRtspOk: Bool
            if wanted, let url = URL(string: currentUrl) {
                let rtspRes = await prober.probeRtsp(url: url)
                finalRtspOk = rtspRes.isReachable
            } else {
                finalRtspOk = false
            }
            
            await MainActor.run {
                self.isProbing = false
                guard currentToken == self.generation else { return }
                
                self.isFtpReady = ftpOk
                self.isRtspReady = finalRtspOk
                
                if ftpOk && !wanted && self.phase == .waitAp {
                    self.begin(phase: .ready)
                    self.show("眼镜热点与 FTP 服务已就绪 (\(host))", isError: false)
                }
                
                if finalRtspOk && wanted && (self.phase == .waitAp || self.phase == .waitRtsp) {
                    self.begin(phase: .streaming)
                    if self.previewWanted {
                        self.onStartPlayer?(currentUrl)
                    }
                }
            }
        }
    }
    
    // MARK: - 处理 BLE 上报信息
    
    private func handleBleReport(_ report: S02LbReport) {
        // 提取 Wi-Fi SSID 与密码
        if let ssid = report.wifiSSID, !ssid.isEmpty, ssid != "-" {
            if targetSSID != ssid {
                targetSSID = ssid
                targetPassword = report.wifiPassword ?? "12345678"
                S02Logger.shared.log("解析到眼镜 Wi-Fi 热点配置: SSID=\(targetSSID), PW=\(targetPassword)", tag: "WiFiFlow")
            }
        }
        
        // 解析 RTSP 停止结果
        if report.rtspStopSequence >= 0 {
            let seq = report.rtspStopSequence
            let res = report.rtspStopResult
            
            if lastStopSequence >= 0 && ((seq - lastStopSequence) & 0x3fffffff) >= 0x20000000 {
                return // 旧时序包过滤
            }
            lastStopSequence = seq
            
            if phase == .stopping {
                if res == 1 {
                    pendingStopSequence = seq
                } else if res == 2 { // 2 = 停止成功确认
                    S02Logger.shared.log("收到设备 RTSP 停止成功确认 (seq=\(seq))", tag: "WiFiFlow")
                    stopConfirmed = true
                } else if res == 3 {
                    show("设备停止 RTSP 失败", isError: true)
                }
            }
        }
    }
    
    private func show(_ text: String, isError: Bool) {
        self.statusText = text
        self.isError = isError
    }
    
    /// 查询多媒体外设是否被占用 (互斥检查)
    public func isBusyForMedia() -> Bool {
        return phase == .streaming || phase == .stopping || phase == .waitRtsp || isStopPending
    }
}
