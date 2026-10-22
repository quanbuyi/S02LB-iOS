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
    @Published public private(set) var isWifiActive: Bool = false
    @Published public private(set) var currentSSID: String? = nil
    @Published public private(set) var isConnectingHotspot: Bool = false
    @Published public private(set) var lastError: String? = nil
    
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
            DispatchQueue.main.async {
                self.isWifiActive = isWifi
                S02Logger.shared.log("Wi-Fi 链路状态更新: \(isWifi ? "已接入 Wi-Fi" : "无 Wi-Fi 连接")", tag: "Hotspot")
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    // MARK: - 自动连接眼镜热点
    
    /// 请求加入指定的眼镜 Wi-Fi AP
    /// - Parameters:
    ///   - ssid: 眼镜热点名称 (如 "CAM-12345" 或 "G1-67890")
    ///   - passphrase: 密码 (固件默认通常为 8~16 位，如 "12345678")
    ///   - joinOnce: 是否仅单次临时连接 (默认 false 保持会话)
    public func connectToHotspot(ssid: String, passphrase: String, joinOnce: Bool = false) async throws {
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
        
        let config: NEHotspotConfiguration
        if passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid)
        } else {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        }
        config.joinOnce = joinOnce
        
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
                            S02Logger.shared.log("已关联到该热点 (\(ssid))", tag: "Hotspot")
                            self.currentSSID = ssid
                            continuation.resume()
                            return
                        }
                        
                        let msg = self.formatErrorDescription(nsErr, ssid: ssid)
                        S02Logger.shared.log("加入 Wi-Fi 失败: \(msg) (rawCode: \(nsErr.code))", tag: "Hotspot")
                        self.lastError = msg
                        continuation.resume(throwing: error)
                    } else {
                        S02Logger.shared.log("已成功提交加入 Wi-Fi 热点请求: \(ssid)", tag: "Hotspot")
                        self.currentSSID = ssid
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
                return "系统配置内部错误 (Code 8: 需付费开发者签名或TrollStore，请在系统 Wi-Fi 中手动连接【\(ssid)】)"
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
        }
    }
}
