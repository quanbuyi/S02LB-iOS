import Foundation
import Combine
import CoreBluetooth

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
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        // 监听底层状态
        ble.$servicesSummary
            .sink { _ in }
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
    
    public func stopRtsp() {
        coordinator.stopRtsp()
    }
    
    private func notify(_ msg: String) {
        self.alertMessage = msg
        self.showAlert = true
    }
}
