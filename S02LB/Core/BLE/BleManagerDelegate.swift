import Foundation
import CoreBluetooth

/// BLE 业务与连接代理协议
public protocol BleManagerDelegate: AnyObject {
    /// 蓝牙适配器状态更新 (如已开启、未授权、已关闭等)
    func bleManager(_ manager: BleManager, didUpdateState state: CBManagerState)
    
    /// 发现目标设备
    func bleManager(_ manager: BleManager, didDiscoverDevice device: BleDeviceModel)
    
    /// 连接状态变化 (connected=true 表示底层已连接且正在发现服务)
    func bleManager(_ manager: BleManager, didChangeConnectionState isConnected: Bool, device: BleDeviceModel?, error: Error?)
    
    /// 服务与特征就绪 (0xAE00 业务服务 + 0xAE01 RX + 0xAE02 TX Notify 就绪)
    func bleManager(_ manager: BleManager, didServicesBecomeReady hasBizService: Bool, hasOtaService: Bool)
    
    /// 接收到解帧后的上行状态上报
    func bleManager(_ manager: BleManager, didReceiveReport report: S02LbReport)
    
    /// 接收到原始数据帧 (含 0xBC 0xBB 帧头)
    func bleManager(_ manager: BleManager, didReceiveRawData data: Data)
    
    /// 发送下行帧结果回调
    func bleManager(_ manager: BleManager, didSendFrame data: Data, success: Bool)
    
    /// 统一日志输出
    func bleManager(_ manager: BleManager, didLog message: String)
}

/// 提供可选默认实现的扩展，方便调用方只实现关心的代理方法
public extension BleManagerDelegate {
    func bleManager(_ manager: BleManager, didUpdateState state: CBManagerState) {}
    func bleManager(_ manager: BleManager, didDiscoverDevice device: BleDeviceModel) {}
    func bleManager(_ manager: BleManager, didChangeConnectionState isConnected: Bool, device: BleDeviceModel?, error: Error?) {}
    func bleManager(_ manager: BleManager, didServicesBecomeReady hasBizService: Bool, hasOtaService: Bool) {}
    func bleManager(_ manager: BleManager, didReceiveReport report: S02LbReport) {}
    func bleManager(_ manager: BleManager, didReceiveRawData data: Data) {}
    func bleManager(_ manager: BleManager, didSendFrame data: Data, success: Bool) {}
    func bleManager(_ manager: BleManager, didLog message: String) {}
}

/// 物奇 0x7033 OTA 专用监听代理协议
public protocol BleOtaDelegate: AnyObject {
    /// 0x7033 服务与 0x2002 Notify 是否就绪
    func otaChannelReady(_ isReady: Bool, reason: String)
    /// 收到 0x2002 通知的原始数据
    func otaDidReceiveNotification(data: Data)
    /// 0x2001 写完成回调
    func otaDidWrite(success: Bool)
    /// 连接在升级中途断开
    func otaDidDisconnect()
}

public extension BleOtaDelegate {
    func otaChannelReady(_ isReady: Bool, reason: String) {}
    func otaDidReceiveNotification(data: Data) {}
    func otaDidWrite(success: Bool) {}
    func otaDidDisconnect() {}
}
