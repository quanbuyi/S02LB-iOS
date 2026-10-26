import Foundation
import Combine
import CoreBluetooth
import UIKit

/// S02LB 主界面 ViewModel
@MainActor
public final class MainDeviceViewModel: ObservableObject {
    
    // MARK: - 核心服务引用
    public let ble = BleManager.shared
    public let coordinator = WifiRtspCoordinator.shared
    public let hotspot = HotspotManager.shared
    
    // MARK: - UI 绑定状态
    @Published public var showFanDialog: Bool = false
    @Published public var showWifiPwDialog: Bool = false
    @Published public var wifiPasswordInput: String = "12345678"
    @Published public var customRtspUrlInput: String = "rtsp://192.168.43.1:554/6600"
    @Published public var alertTitle: String = "提示"
    @Published public var alertMessage: String? = nil
    @Published public var alertConfirmTitle: String = "确定"
    @Published public var alertConfirmAction: (() -> Void)? = nil
    @Published public var showAlert: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        // 监听底层状态
        ble.$servicesSummary
            .sink { _ in }
            .store(in: &cancellables)
            
        // 监听手动加入 Wi-Fi 弹窗提示
        hotspot.$manualConnectionPrompt
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                guard let self = self else { return }
                UIPasteboard.general.string = prompt.password
                self.showConfirmDialog(
                    title: "请连接眼镜 Wi-Fi",
                    message: "\(prompt.reason)\n\n热点名称: 【\(prompt.ssid)】\n热点密码: 【\(prompt.password)】(已自动复制到剪贴板)\n\n点击「立即前往」将在系统无线局域网中直接连接。",
                    confirmTitle: "立即前往 Wi-Fi 设置"
                ) {
                    self.hotspot.openSystemWifiSettings()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - BLE 控制
    
    public func toggleScan() {
        if ble.isScanning {
            ble.stopScan()
        } else {
            ble.startScan()
        }
    }
    
    public func connect(device: BleDeviceModel) {
        ble.connect(device: device)
    }
    
    public func disconnect() {
        coordinator.disableWifi()
        ble.disconnect()
    }
    
    public func sendCommand(_ command: S02LbProtocol.Command) {
        guard ble.isConnected else {
            notify("请先连接眼镜设备")
            return
        }
        
        // 硬件互斥检查：推流或切换期间不可下发拍照/录像/格式化
        if (command == .photo || command == .startRec || command == .sdFormat) && coordinator.isBusyForMedia() {
            notify("当前推流或热点切换正在进行，请等待媒体通道释放")
            return
        }
        
        ble.send(command: command)
    }
    
    public func syncCurrentTime() {
        guard ble.isConnected else {
            notify("请先连接眼镜设备")
            return
        }
        ble.syncCurrentTime()
    }
    
    public func setFanLevel(_ level: Int) {
        guard ble.isConnected else {
            notify("请先连接眼镜设备")
            return
        }
        ble.setFan(level: level)
    }
    
    public func submitWifiPassword() {
        guard ble.isConnected else {
            notify("请先连接眼镜设备")
            return
        }
        guard wifiPasswordInput.count >= 8 && wifiPasswordInput.count <= 16 else {
            notify("WiFi 密码必须在 8~16 位字符之间")
            return
        }
        ble.setWifiPassword(wifiPasswordInput)
    }
    
    public func copyWifiPassword() {
        let pw = coordinator.currentTargetPassword
        UIPasteboard.general.string = pw
        notify("热点密码已复制到剪贴板: \(pw)")
    }
    
    public func copyDiagnosticsSummary() {
        let summary = ble.getDiagnosticsSummary()
        UIPasteboard.general.string = summary
        notify("已复制精简诊断日志 (适合发送QQ)")
    }
    
    public func openSystemWifiSettings() {
        let pw = coordinator.currentTargetPassword
        let ssid = coordinator.currentTargetSSID
        UIPasteboard.general.string = pw
        notify("热点密码已自动复制 (\(pw))，请在系统 Wi-Fi 列表中选择【\(ssid.isEmpty ? "眼镜热点" : ssid)】连接")
        hotspot.openSystemWifiSettings()
    }
    
    // MARK: - Wi-Fi AP 与推流控制 (Phase 2)
    
    public func startWifiAp() {
        coordinator.enableWifi()
    }
    
    public func stopWifiAp() {
        coordinator.disableWifi()
    }
    
    public func startRtsp(preview: Bool = true) {
        coordinator.startRtsp(url: customRtspUrlInput, preview: preview)
    }
    
    /// 启动并预览 (对齐安卓「启动并预览」)
    public func startRtspWithPreview() {
        coordinator.startRtsp(url: customRtspUrlInput, preview: true)
    }
    
    /// 停止画面预览 (对齐安卓「停止预览」)
    public func stopPreview() {
        coordinator.stopPreview()
    }
    
    /// 仅打开 RTSP 推流命令，不启动画面 (对齐安卓「打开RTSP」)
    public func openRtspOnly() {
        coordinator.startRtsp(url: customRtspUrlInput, preview: false)
    }
    
    /// 关闭 RTSP 推流 (对齐安卓「关闭RTSP」)
    public func closeRtsp() {
        coordinator.stopRtsp()
    }
    
    public func stopRtsp() {
        coordinator.stopRtsp()
    }
    
    public func copyAllLogs() {
        UIPasteboard.general.string = ble.logMessages.joined(separator: "\n")
        notify("已复制全部日志 (\(ble.logMessages.count) 条)")
    }
    
    public func notify(_ msg: String, title: String = "提示") {
        self.alertTitle = title
        self.alertMessage = msg
        self.alertConfirmTitle = "确定"
        self.alertConfirmAction = nil
        self.showAlert = true
    }
    
    public func showConfirmDialog(title: String = "提示", message: String, confirmTitle: String = "确定", action: @escaping () -> Void) {
        self.alertTitle = title
        self.alertMessage = message
        self.alertConfirmTitle = confirmTitle
        self.alertConfirmAction = action
        self.showAlert = true
    }
}
