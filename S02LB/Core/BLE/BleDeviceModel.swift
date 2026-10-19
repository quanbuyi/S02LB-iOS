import Foundation
import CoreBluetooth

/// 扫描发现的 BLE 设备模型
public struct BleDeviceModel: Identifiable, Equatable, Hashable {
    public var id: UUID { peripheral.identifier }
    public let peripheral: CBPeripheral
    public var name: String
    public var rssi: Int
    public var lastSeen: Date
    
    public init(peripheral: CBPeripheral, name: String?, rssi: Int) {
        self.peripheral = peripheral
        self.name = name ?? peripheral.name ?? "未知设备"
        self.rssi = rssi
        self.lastSeen = Date()
    }
    
    public static func == (lhs: BleDeviceModel, rhs: BleDeviceModel) -> Bool {
        return lhs.peripheral.identifier == rhs.peripheral.identifier
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(peripheral.identifier)
    }
}
