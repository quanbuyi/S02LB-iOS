import Foundation
import Combine
import Network

/// S02LB Wi-Fi 热点与 RTSP/FTP 业务协调器
///
/// 核心职责：
/// 1. 协调 BLE 命令下发与 Wi-Fi 热点自动连接 (NEHotspotConfiguration)；
/// 2. 状态机驱动：AP 就绪 -> 端口可达性探测 -> RTSP 启动 -> DESCRIBE 校验 -> 释放回收；
/// 3. 设备多媒体互斥管理：严格遵守硬件互斥规则（RTSP 推流中禁止拍照/录像/格式化）；
/// 4. 严密跟踪设备 RTSP_STOP 序列号确认，避免盲目切断导致固件死锁或重启；
/// 5. 严格实施重试退避（8秒）与重试上限（最多4次），彻底杜绝命令风暴；
/// 6. 【自动接管机制】：当连上蓝牙时若硬件已在广播热点（wifi_on == 1），自动接管并立即发起连接；
/// 7. 精准控制 NEHotspotConfiguration 单例执行，彻底杜绝并发 Task 重入。
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
    
    // 当前推导出的热点名称与密码（供 UI 展示与手动连接备用）
    @Published public private(set) var currentTargetSSID: String = ""
    @Published public private(set) var currentTargetPassword: String = "12345678"
    @Published public private(set) var isHotspotHardwareReady: Bool = false
    
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
    private var userExplicitlyTurnedOff: Bool = false
    
    private var isStopPending: Bool = false
    private var stopConfirmed: Bool = false
    private var lastStopSequence: Int64 = -1
    private var pendingStopSequence: Int64 = -1
    
    // MARK: - 重试退避与超时控制 (对齐成熟策略)
    private let retryInterval: TimeInterval = 8.0 // 8 秒重试间隔，拒绝命令风暴
    private let flowTimeout: TimeInterval = 60.0  // 单次动作最长 60 秒保护
    private let maxWifiSends: Int = 4             // 开启 WiFi 命令最多发 4 次
    private let maxStartSends: Int = 3            // 启动 RTSP 命令最多发 3 次
    private let maxStopSends: Int = 3             // 停止 RTSP 命令最多发 3 次
    
    private var wifiSends: Int = 0
    private var startSends: Int = 0
    private var stopSends: Int = 0
    
    private var nextWifiDate: Date = Date.distantPast
    private var nextStartDate: Date = Date.distantPast
    private var nextStopDate: Date = Date.distantPast
    private var deadlineDate: Date = Date.distantFuture
    private var hotspotJoinAttemptedForCurrentSession: Bool = false
    
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
        
        // 监听当前连接的蓝牙设备名称，用于 SSID 智能推导回退
        bleManager.$connectedDevice
            .sink { [weak self] dev in
                self?.updateCandidateCredentials()
            }
            .store(in: &cancellables)
        
        // 监听蓝牙连接断开，立即重置状态机，杜绝在断连后发送指令
        bleManager.$isConnected
            .sink { [weak self] connected in
                guard let self = self else { return }
                if !connected {
                    self.userExplicitlyTurnedOff = false
                    self.cancel()
                }
            }
            .store(in: &cancellables)
        
        // 监听热点管理器 Wi-Fi 物理连接状态
        hotspotManager.$isWifiActive
            .sink { [weak self] isActive in
                guard let self = self else { return }
                self.isWifiConnected = isActive
                if isActive {
                    S02Logger.shared.log("检测到手机已接入 Wi-Fi 网络，触发端口服务探测...", tag: "WiFiFlow")
                    self.triggerServiceProbe()
                } else if self.phase == .streaming || self.phase == .ready {
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
    
    // MARK: - 智能 SSID 与密码推导 (优先上报，缺省时以蓝牙广播名回退)
    
    public var resolvedSSID: String {
        // 1. 若上报了有效 SSID，直接使用
        if !targetSSID.isEmpty && targetSSID != "0" && targetSSID != "-" {
            return targetSSID
        }
        // 2. 否则以当前连接的蓝牙设备名称（如 G1-05488, CAM-xxxx）作为候选
        if let devName = bleManager.connectedDevice?.name, !devName.isEmpty {
            return devName
        }
        return ""
    }
    
    public var resolvedPassword: String {
        if !targetPassword.isEmpty && targetPassword != "0" && targetPassword != "-" {
            return targetPassword
        }
        return "12345678"
    }
    
    private func updateCandidateCredentials() {
        let s = self.resolvedSSID
        let p = self.resolvedPassword
        if self.currentTargetSSID != s || self.currentTargetPassword != p {
            self.currentTargetSSID = s
            self.currentTargetPassword = p
        }
    }
    
    // MARK: - 公开控制动作
    
    /// 开启眼镜 WiFi 热点并自动加入
    public func enableWifi() {
        guard bleManager.isConnected else {
            show("请先连接眼镜蓝牙", isError: true)
            return
        }
        
        userExplicitlyTurnedOff = false
        updateCandidateCredentials()
        wifiWanted = true
        rtspWanted = false
        isStopPending = false
        generation += 1
        
        begin(phase: .waitAp)
        
        let ssid = self.resolvedSSID
        let pass = self.resolvedPassword
        
        // 立即判断：如果硬件热点广播已经就绪，0 毫秒立即触发加入，无需等待定时器
        if isHotspotHardwareReady {
            S02Logger.shared.log("检测到硬件 AP 已经就绪，立即触发系统加入热点: \(ssid)", tag: "WiFiFlow")
            triggerHotspotJoin(ssid: ssid, password: pass)
        } else {
            // 否则立即下发一次开启 WiFi 传输命令
            wifiSends = 1
            nextWifiDate = Date().addingTimeInterval(retryInterval)
            S02Logger.shared.log("立即下发开启 WiFi 传输命令 (目标: \(ssid))...", tag: "WiFiFlow")
            bleManager.send(command: .setWifiOn)
        }
    }
    
    /// 关闭 WiFi 热点并断开关联
    public func disableWifi() {
        guard bleManager.isConnected else {
            cancel()
            return
        }
        
        userExplicitlyTurnedOff = true
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
        
        userExplicitlyTurnedOff = false
        updateCandidateCredentials()
        wifiWanted = true
        rtspWanted = true
        previewWanted = preview
        generation += 1
        
        if phase == .off || phase == .failed {
            begin(phase: .waitAp)
        }
        
        if isHotspotHardwareReady, !hotspotManager.isWifiActive {
            triggerHotspotJoin(ssid: self.resolvedSSID, password: self.resolvedPassword)
        }
    }
    
    /// 停止 RTSP 推流并等待设备释放硬件编码器
    public func stopRtsp() {
        guard bleManager.isConnected else {
            cancel()
            return
        }
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
    
    /// 重置状态机
    public func cancel() {
        wifiWanted = false
        rtspWanted = false
        previewWanted = false
        isStopPending = false
        stopConfirmed = false
        phase = .off
        wifiSends = 0
        startSends = 0
        stopSends = 0
        isHotspotHardwareReady = false
        hotspotJoinAttemptedForCurrentSession = false
        deadlineDate = Date.distantFuture
        onStopPlayer?()
        show("未开启", isError: false)
    }
    
    // MARK: - 触发系统热点关联
    
    private func triggerHotspotJoin(ssid: String, password: String) {
        guard !ssid.isEmpty else { return }
        guard !hotspotManager.isTargetHotspotConnected else {
            S02Logger.shared.log("手机已接入眼镜专属热点，无需重复加入: \(ssid)", tag: "WiFiFlow")
            return
        }
        guard !hotspotJoinAttemptedForCurrentSession else { return }
        hotspotJoinAttemptedForCurrentSession = true
        
        S02Logger.shared.log("【发起热点关联】向系统提交加入请求: SSID=\(ssid), 密码=\(password)", tag: "WiFiFlow")
        
        Task {
            do {
                try await self.hotspotManager.connectToHotspot(ssid: ssid, passphrase: password)
                S02Logger.shared.log("【热点关联成功】系统已成功关联至: \(ssid)，重置超时保护计时器...", tag: "WiFiFlow")
                await MainActor.run {
                    // 用户在弹窗确认后，重新赋予充足的 flowTimeout 时间用于 DHCP 与服务就绪
                    self.deadlineDate = Date().addingTimeInterval(self.flowTimeout)
                    self.triggerServiceProbe()
                }
            } catch {
                S02Logger.shared.log("【热点关联异常】\(error.localizedDescription)", tag: "WiFiFlow")
                await MainActor.run {
                    self.show("眼镜热点已就绪 [\(ssid)]！若系统未弹出加入提示，请前往系统 Wi-Fi 手动连接", isError: false)
                }
            }
        }
    }
    
    // MARK: - 内部状态机调度
    
    private func begin(phase target: Phase) {
        self.phase = target
        let now = Date()
        self.deadlineDate = now.addingTimeInterval(flowTimeout)
        self.wifiSends = 0
        self.startSends = 0
        self.stopSends = 0
        self.nextWifiDate = now
        self.nextStartDate = now
        self.nextStopDate = now
        self.hotspotJoinAttemptedForCurrentSession = false
        S02Logger.shared.log("状态机切换 -> \(target.rawValue)", tag: "WiFiFlow")
    }
    
    private func tick() {
        guard phase != .off && phase != .failed else { return }
        guard bleManager.isConnected else {
            cancel()
            return
        }
        
        let now = Date()
        
        let targetHost = URL(string: self.rtspUrl)?.host ?? "192.168.43.1"
        hotspotManager.evaluateConnection(targetSSID: self.resolvedSSID, targetHost: targetHost, isServiceReachable: self.isFtpReady || self.isRtspReady)
        
        // 0. 流程超时检查
        if now >= deadlineDate {
            fail(reason: "等待热点与服务就绪超时 (超过 \(Int(flowTimeout)) 秒)")
            return
        }
        
        // 1. 停止推流中：等待设备释放确认
        if phase == .stopping {
            show("RTSP 正在停止，等待设备释放媒体资源...", isError: false)
            if !stopConfirmed && now >= nextStopDate && stopSends < maxStopSends {
                stopSends += 1
                nextStopDate = now.addingTimeInterval(retryInterval)
                S02Logger.shared.log("重发停止 RTSP 命令 (\(stopSends)/\(maxStopSends))...", tag: "WiFiFlow")
                bleManager.send(command: .rtspStop)
            }
            if stopConfirmed && !isRtspReady {
                isStopPending = false
                begin(phase: wifiWanted ? .ready : .waitOff)
            }
            return
        }
        
        // 2. 关闭热点中
        if !wifiWanted || phase == .waitOff {
            show("正在关闭 WiFi 传输...", isError: false)
            if now >= nextWifiDate && wifiSends < 2 {
                wifiSends += 1
                nextWifiDate = now.addingTimeInterval(retryInterval)
                bleManager.send(command: .setWifiOff)
            }
            let ssid = self.resolvedSSID
            if !ssid.isEmpty {
                hotspotManager.disconnectHotspot(ssid: ssid)
            }
            if wifiSends >= 2 || !hotspotManager.isWifiActive {
                begin(phase: .off)
            }
            return
        }
        
        // 3. 等待热点开启与连接
        if phase == .waitAp {
            let ssid = self.resolvedSSID
            let pass = self.resolvedPassword
            
            // 严格防护：只要硬件热点已经就绪正在广播 (isHotspotHardwareReady == true)，
            // 或者已经向系统发起过热点关联申请 (hotspotJoinAttemptedForCurrentSession == true)，
            // 绝对严禁重复下发开启 WiFi 命令，否则会导致固件 AP 进程不断软重启，致使正在握手的手机断线或无法获取 IP！
            if !isHotspotHardwareReady && !hotspotJoinAttemptedForCurrentSession {
                if now >= nextWifiDate && wifiSends < maxWifiSends {
                    wifiSends += 1
                    nextWifiDate = now.addingTimeInterval(retryInterval)
                    S02Logger.shared.log("下发开启 WiFi 传输命令 (\(wifiSends)/\(maxWifiSends))...", tag: "WiFiFlow")
                    bleManager.send(command: .setWifiOn)
                }
            }
            
            if isHotspotHardwareReady {
                if !hotspotManager.isTargetHotspotConnected {
                    if hotspotManager.isOtherWifiConnected {
                        show("当前连接其它 Wi-Fi (IP: \(hotspotManager.currentWifiIP ?? "-"))，请切换至眼镜热点 [\(ssid)]", isError: false)
                    } else {
                        show("眼镜热点已就绪 [\(ssid)]！若未自动加入，请前往系统 Wi-Fi 连接", isError: false)
                    }
                    triggerHotspotJoin(ssid: ssid, password: pass)
                } else {
                    show("已成功接入眼镜热点 [\(ssid)]，正在探测相机服务...", isError: false)
                }
            } else {
                if !ssid.isEmpty {
                    show("已下发开启命令，等待眼镜热点广播就绪 (目标: \(ssid))...", isError: false)
                } else {
                    show("已下发开启 WiFi，正在获取热点广播配置...", isError: false)
                }
            }
            
            // 触发服务可达性探测
            triggerServiceProbe()
            return
        }
        
        // 4. 等待推流就绪
        if phase == .waitRtsp {
            show("热点已连接，下发推流命令并等待 RTSP DESCRIBE 响应...", isError: false)
            if now >= nextStartDate && startSends < maxStartSends {
                startSends += 1
                nextStartDate = now.addingTimeInterval(retryInterval)
                S02Logger.shared.log("下发启动推流命令 (\(startSends)/\(maxStartSends))...", tag: "WiFiFlow")
                bleManager.send(command: .rtspStart)
            }
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
        guard !isProbing else { return }
        let ip = hotspotManager.currentWifiIP ?? NetworkInterfaceHelper.getWifiIPv4Address()
        let hasIp = (ip != nil && !ip!.isEmpty && ip != "0.0.0.0")
        guard hotspotManager.isAnyWifiActive || hasIp else { return }
        
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
                
                // 只要 FTP 或 RTSP 成功响应，即刻确认为已连接眼镜专属热点！
                if ftpOk || finalRtspOk {
                    self.hotspotManager.markTargetHotspotConnected(true)
                }
                
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
        // 1. 提取 Wi-Fi SSID 与密码 (只有合法有效时才更新)
        if let ssid = report.wifiSSID, !ssid.isEmpty, ssid != "-", ssid != "0" {
            if targetSSID != ssid {
                targetSSID = ssid
                targetPassword = report.wifiPassword ?? "12345678"
                updateCandidateCredentials()
                S02Logger.shared.log("解析到眼镜 Wi-Fi 热点配置: SSID=\(targetSSID), PW=\(targetPassword)", tag: "WiFiFlow")
            }
        }
        
        // 2. 监测硬件 AP 就绪状态
        let wasReady = self.isHotspotHardwareReady
        let isNowReady = report.isWifiApReady
        
        // 关键防护：硬件 AP 广播状态具有保持性！
        // 只有当固件明确上报 wifiOn == 0 时才认为热点关闭；当缺省 (-1) 时绝不得将已就绪状态冲刷为 false！
        if isNowReady || report.wifiOn == 1 {
            self.isHotspotHardwareReady = true
        } else if report.wifiOn == 0 {
            self.isHotspotHardwareReady = false
        }
        let isCurrentlyReady = self.isHotspotHardwareReady
        
        if isCurrentlyReady {
            // 【自动接管机制】如果硬件 AP 已经就绪（例如开机即开启或断线重连）：
            // 只要用户没有主动点击关闭热点，App 自动接管并立即尝试发起热点连接与探测
            if phase == .off && !userExplicitlyTurnedOff {
                S02Logger.shared.log("★ 检测到眼镜热点已在广播 (wifi_on=1)，自动接管并启动热点连接链路 (SSID=\(self.resolvedSSID))", tag: "WiFiFlow")
                wifiWanted = true
                begin(phase: .waitAp)
                triggerHotspotJoin(ssid: self.resolvedSSID, password: self.resolvedPassword)
            } else if phase == .waitAp && !wasReady {
                S02Logger.shared.log("★ 眼镜 Wi-Fi 硬件广播已启动！SSID=\(self.resolvedSSID), wifi_on=\(report.wifiOn)", tag: "WiFiFlow")
                triggerHotspotJoin(ssid: self.resolvedSSID, password: self.resolvedPassword)
            }
        }
        
        // 3. 解析 RTSP 停止结果
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
    
    private func fail(reason: String) {
        self.phase = .failed
        onStopPlayer?()
        show(reason, isError: true)
        S02Logger.shared.log("流程异常: \(reason)", tag: "WiFiFlow")
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
