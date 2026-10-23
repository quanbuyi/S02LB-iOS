import Foundation
import NetworkExtension
import Network
import Combine
import UIKit

/// 眼镜 Wi-Fi AP 热点连接管理器 (基于 NetworkExtension / NEHotspotConfiguration)
///
/// 具备能力：
/// 1. 根据 BLE 上报的 SSID/密码，自动加入眼镜 Wi-Fi AP；
/// 2. 监听本地网络与 Wi-Fi 链路状态 (NWPathMonitor)；
/// 3. 支持注销/离开眼镜热点并恢复原有系统网络。
public final class HotspotManager: ObservableObject {
    
    public static let shared = HotspotManager()
    
    // MARK: - 响应式属性
    
    /// 手机当前是否已接入任意 Wi-Fi (包括家庭/办公室路由器)
    @Published public private(set) var isAnyWifiActive: Bool = false
    
    /// 手机当前在 en0 网卡获取到的 Wi-Fi IPv4 地址 (如 192.168.43.15 或 192.168.1.108)
    @Published public private(set) var currentWifiIP: String? = nil
    
    /// 手机当前是否已真正连入眼镜专属热点 (经 192.168.43.x 子网校验、SSID比对或服务探测确认)
    @Published public private(set) var isTargetHotspotConnected: Bool = false
    
    /// 手机当前是否连接了非眼镜热点的其它 Wi-Fi (如家庭/办公网络)
    @Published public private(set) var isOtherWifiConnected: Bool = false
    
    /// 兼容旧属性：仅在真正连入眼镜专属热点时为 true
    @Published public private(set) var isWifiActive: Bool = false
    
    @Published public private(set) var currentSSID: String? = nil
    @Published public private(set) var isConnectingHotspot: Bool = false
    @Published public private(set) var lastError: String? = nil
    
    /// 当由于系统限制 (如 Code 8 个人证书限制) 需要用户前往系统 Wi-Fi 设置手动连接时触发
    @Published public var manualConnectionPrompt: (ssid: String, password: String, reason: String)? = nil
    
    private var currentConnectingSSID: String? = nil
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let monitorQueue = DispatchQueue(label: "com.s02lb.hotspot.monitor")
    
    private init() {
        startNetworkPathMonitor()
    }
    
    deinit {
        pathMonitor.cancel()
    }
    
    // MARK: - 启动网络链路监听
    private func startNetworkPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let isWifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            let ip = NetworkInterfaceHelper.getWifiIPv4Address()
            
            DispatchQueue.main.async {
                self.isAnyWifiActive = isWifi
                self.currentWifiIP = ip
                
                // 初步子网探测：若当前已接入 Wi-Fi 且 IP 位于 192.168.43.x，判定为已在眼镜热点
                let isSubnetMatch = NetworkInterfaceHelper.isSameSubnet(ipA: ip, ipB: "192.168.43.1")
                let targetConnected = isWifi && isSubnetMatch
                
                self.isTargetHotspotConnected = targetConnected
                self.isWifiActive = targetConnected
                self.isOtherWifiConnected = isWifi && !targetConnected
                
                if isWifi {
                    if targetConnected {
                        S02Logger.shared.log("Wi-Fi 链路状态更新: 已接入眼镜热点 (IP: \(ip ?? "-"))", tag: "Hotspot")
                    } else {
                        S02Logger.shared.log("Wi-Fi 链路状态更新: 当前连接其它 Wi-Fi (IP: \(ip ?? "-"))，未接入眼镜热点", tag: "Hotspot")
                    }
                } else {
                    S02Logger.shared.log("Wi-Fi 链路状态更新: 无 Wi-Fi 连接", tag: "Hotspot")
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    // MARK: - 评估与更新连接状态 (严格基于 IP 与服务探活，杜绝 SSID 盲目误判)
    
    /// 根据当前 IP 与探测状态，严格区分是接入了眼镜专属热点还是连接了其它 Wi-Fi
    public func evaluateConnection(targetSSID: String, targetHost: String, isServiceReachable: Bool) {
        let ip = NetworkInterfaceHelper.getWifiIPv4Address()
        let isSubnetMatch = NetworkInterfaceHelper.isSameSubnet(ipA: ip, ipB: targetHost)
        
        // 核心铁律：只有手机处于 Wi-Fi 状态且 (IP 处于 192.168.43.x 或 FTP/RTSP 服务可达) 时，才算接入眼镜热点！
        // 绝对不得仅凭客户端记录的 SSID 变量做判定，杜绝连接家庭/办公 Wi-Fi 时误判！
        let targetConnected = self.isAnyWifiActive && (isServiceReachable || isSubnetMatch)
        
        DispatchQueue.main.async {
            self.currentWifiIP = ip
            self.isTargetHotspotConnected = targetConnected
            self.isWifiActive = targetConnected
            self.isOtherWifiConnected = self.isAnyWifiActive && !targetConnected
        }
    }
    
    /// 当服务探测器确认连通时主动标记
    public func markTargetHotspotConnected(_ connected: Bool) {
        DispatchQueue.main.async {
            self.isTargetHotspotConnected = connected
            self.isWifiActive = connected
            self.isOtherWifiConnected = self.isAnyWifiActive && !connected
        }
    }
    
    // MARK: - 自动连接眼镜热点
    
    /// 请求加入指定的眼镜 Wi-Fi AP
    /// - Parameters:
    ///   - ssid: 眼镜热点名称 (如 "CAM-12345" 或 "G1-67890")
    ///   - passphrase: 密码 (固件默认通常为 8~16 位，如 "12345678")
    ///   - joinOnce: 是否仅单次临时连接 (默认 false 保持会话)
    public func connectToHotspot(ssid: String, passphrase: String, joinOnce: Bool = true) async throws {
        guard !ssid.isEmpty else {
            throw NSError(domain: "HotspotManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "SSID 不能为空"])
        }
        
        // 防重复重入：若正在连接同名热点，直接等待或跳过
        if isConnectingHotspot, currentConnectingSSID == ssid {
            S02Logger.shared.log("热点关联已在进行中，跳过重复请求: \(ssid)", tag: "Hotspot")
            return
        }
        
        await MainActor.run {
            self.isConnectingHotspot = true
            self.currentConnectingSSID = ssid
            self.lastError = nil
        }
        
        S02Logger.shared.log("请求通过 NEHotspotConfiguration 加入热点: \(ssid)", tag: "Hotspot")
        
        // 先清理该热点可能存在的旧残留配置，避免系统 helper 抛出 Code 8 内部错误
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        try? await Task.sleep(nanoseconds: 80_000_000)
        
        let config: NEHotspotConfiguration
        if passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid)
        } else {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        }
        // 设置为 true 避免写入持久化 Keychain 导致系统配置冲突与 Code 8
        config.joinOnce = true
        
        return try await withCheckedThrowingContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isConnectingHotspot = false
                    self.currentConnectingSSID = nil
                    if let error = error {
                        let nsErr = error as NSError
                        // NEHotspotConfigurationError.alreadyAssociated (code 13) 表示已经连接在当前热点
                        if nsErr.domain == NEHotspotConfigurationErrorDomain && nsErr.code == 13 {
                            S02Logger.shared.log("系统反馈已关联到该热点配置 (\(ssid))，正在校验 IP 子网...", tag: "Hotspot")
                            self.currentSSID = ssid
                            let ip = NetworkInterfaceHelper.getWifiIPv4Address()
                            let isSubnetMatch = NetworkInterfaceHelper.isSameSubnet(ipA: ip, ipB: "192.168.43.1")
                            let connected = self.isAnyWifiActive && isSubnetMatch
                            self.isTargetHotspotConnected = connected
                            self.isWifiActive = connected
                            self.isOtherWifiConnected = self.isAnyWifiActive && !connected
                            continuation.resume()
                            return
                        }
                        
                        let msg = self.formatErrorDescription(nsErr, ssid: ssid)
                        S02Logger.shared.log("加入 Wi-Fi 失败: \(msg) (rawCode: \(nsErr.code))", tag: "Hotspot")
                        self.lastError = msg
                        
                        // 针对 Code 8 (个人证书签名无权限静默加入) 或 Code 7 (未搜到广播)，主动触发弹窗提示用户前往系统设置
                        if nsErr.domain == NEHotspotConfigurationErrorDomain && (nsErr.code == 8 || nsErr.code == 7) {
                            self.manualConnectionPrompt = (
                                ssid: ssid,
                                password: passphrase,
                                reason: nsErr.code == 8 
                                    ? "iOS 系统限制个人证书静默加入热点，需前往系统设置手动连接。" 
                                    : "尚未扫描到热点广播，请在系统无线局域网列表中确认。"
                            )
                        }
                        
                        continuation.resume(throwing: error)
                    } else {
                        S02Logger.shared.log("已成功向系统提交加入 Wi-Fi 热点请求: \(ssid)，等待 DHCP 完成...", tag: "Hotspot")
                        self.currentSSID = ssid
                        let ip = NetworkInterfaceHelper.getWifiIPv4Address()
                        let isSubnetMatch = NetworkInterfaceHelper.isSameSubnet(ipA: ip, ipB: "192.168.43.1")
                        let connected = self.isAnyWifiActive && isSubnetMatch
                        self.isTargetHotspotConnected = connected
                        self.isWifiActive = connected
                        self.isOtherWifiConnected = self.isAnyWifiActive && !connected
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func formatErrorDescription(_ nsErr: NSError, ssid: String = "") -> String {
        if nsErr.domain == NEHotspotConfigurationErrorDomain {
            switch nsErr.code {
            case 1:
                return "用户取消了加入热点"
            case 7:
                return "未扫描到热点广播 [\(ssid)]，眼镜硬件可能正在启动中"
            case 8:
                return "系统配置受限 (Code 8: iOS 限制个人证书静默加入，请点击界面按钮在系统 Wi-Fi 中连接【\(ssid)】)"
            case 13:
                return "已关联到该热点"
            case 14:
                return "申请加入超时，请确认眼镜热点是否在广播"
            default:
                return "系统加入失败: \(nsErr.localizedDescription) (code: \(nsErr.code))"
            }
        }
        return nsErr.localizedDescription
    }
    
    /// 跳转到 iOS 系统 Wi-Fi 设置列表
    @MainActor
    public func openSystemWifiSettings() {
        if let url = URL(string: "App-Prefs:root=WIFI"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
    
    /// 断开/移除指定的眼镜热点配置
    public func disconnectHotspot(ssid: String) {
        guard !ssid.isEmpty else { return }
        S02Logger.shared.log("移除热点配置: \(ssid)", tag: "Hotspot")
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        DispatchQueue.main.async {
            if self.currentSSID == ssid {
                self.currentSSID = nil
            }
            self.isTargetHotspotConnected = false
            self.isWifiActive = false
        }
    }
}
