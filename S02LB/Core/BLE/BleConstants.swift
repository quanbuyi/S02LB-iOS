import Foundation
import CoreBluetooth

/// S02LB 蓝牙 UUID 与服务常量
public struct BleConstants {
    // MARK: - 业务控制服务 (0xAE00)
    public static let serviceUUID = CBUUID(string: "0000ae00-0000-1000-8000-00805f9b34fb")
    /// 手机写命令给眼镜 (Write Without Response)
    public static let rxCharUUID  = CBUUID(string: "0000ae01-0000-1000-8000-00805f9b34fb")
    /// 眼镜上报 JSON 状态给手机 (Notify)
    public static let txCharUUID  = CBUUID(string: "0000ae02-0000-1000-8000-00805f9b34fb")
    
    // MARK: - 物奇 OTA 升级服务 (0x7033)
    public static let otaServiceUUID = CBUUID(string: "00007033-0000-1000-8000-00805f9b34fb")
    /// App 下发 OTA 命令与固件块 (Write Without Response)
    public static let otaRxCharUUID  = CBUUID(string: "00002001-0000-1000-8000-00805f9b34fb")
    /// 设备响应与状态通知 (Notify)
    public static let otaTxCharUUID  = CBUUID(string: "00002002-0000-1000-8000-00805f9b34fb")
    
    // MARK: - 设备广播过滤前缀
    public static let deviceNamePrefixes = ["CAM-", "G1-", "S02LB"]
}
