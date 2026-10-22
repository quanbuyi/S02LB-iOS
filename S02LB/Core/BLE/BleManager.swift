import Foundation
import CoreBluetooth
import Combine

/// S02LB 智能眼镜 BLE 核心管理类
///
/// 具备如下核心功能：
/// 1. 自动过滤扫描广播名前缀为 `CAM-`、`G1-`、`S02LB` 的眼镜设备；
/// 2. 建立低功耗蓝牙 GATT 连接并自动发现业务控制服务 `0xAE00` 与物奇 OTA 服务 `0x7033`；
/// 3. 自动使能 `0xAE02` (Notify) 上报，并缓存 `0xAE01` (Write Without Response) 下行特征；
/// 4. 接入流式分包解包器 `BlePacketParser`，完整解析 `0xBC 0xBB` 上行 JSON 状态；
/// 5. 提供面向 SwiftUI/Combine 的响应式 `@Published` 属性与面向业务解耦的 Delegate 接口；
/// 6. 支持 0x7033 物奇 OTA 固件升级无缝复用同一连接通道。
public final class BleManager: NSObject, ObservableObject {
    
    // MARK: - 单例与公开属性
    public static let shared = BleManager()
    
    public weak var delegate: BleManagerDelegate?
    public weak var otaDelegate: BleOtaDelegate?
    
    // MARK: - SwiftUI / Combine 响应式状态
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isServicesReady: Bool = false
    @Published public private(set) var discoveredDevices: [BleDeviceModel] = []
    @Published public private(set) var connectedDevice: BleDeviceModel? = nil
    @Published public private(set) var latestReport: S02LbReport? = nil
    @Published public private(set) var logMessages: [String] = []
    
    // MARK: - 自检状态信息
    @Published public private(set) var hasBizService: Bool = false
    @Published public private(set) var hasOtaService: Bool = false
    @Published public private(set) var servicesSummary: String = "(尚未发现服务)"
    
    // MARK: - 内部私有属性
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    
    private var rxCharacteristic: CBCharacteristic?    // 0xAE01 (写无响应)
    private var txCharacteristic: CBCharacteristic?    // 0xAE02 (通知)
    
    private var otaRxCharacteristic: CBCharacteristic? // 0x2001 (写无响应)
    private var otaTxCharacteristic: CBCharacteristic? // 0x2002 (通知)
    private var isOtaNotifyEnabled: Bool = false
    
    private let packetParser = BlePacketParser()
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var lastScanLogTime: [UUID: Date] = [:]
    private var lastReportKey: String = ""
    
    // MARK: - 初始化
    public override init() {
        super.init()
        // 使用独立后台队列运行 CoreBluetooth 协议栈，保障高吞吐下的 UI 流畅度
        let queue = DispatchQueue(label: "com.s02lb.ble.central", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue)
        
        setupPacketParser()
        setupLoggerBridge()
    }
    
    private func setupLoggerBridge() {
        S02Logger.shared.onLogAppended = { [weak self] formatted in
            guard AppConfig.enableInteractionLog else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logMessages.append(formatted)
                if self.logMessages.count > 300 {
                    self.logMessages.removeFirst(50)
                }
                self.delegate?.bleManager(self, didLog: formatted)
            }
        }
    }
    
    private func setupPacketParser() {
        packetParser.onReportParsed = { [weak self] report in
            guard let self = self else { return }
            // 过滤重复心跳，仅在状态变更或关键事件发生时记录日志，防止长日志超出聊天框
            let currentKey = "\(report.soc)_\(report.isCharging)_\(report.wifi)_\(report.wifiOn)_\(report.rtsp)_\(report.fan)_\(report.isRecording)"
            if currentKey != self.lastReportKey {
                self.lastReportKey = currentKey
                self.log("收到设备状态更新: 电量=\(report.soc)% 充电=\(report.charge) 热点=\(report.wifiSSID ?? "-")(wifi_on=\(report.wifiOn)) RTSP=\(report.rtsp)")
            }
            DispatchQueue.main.async {
                self.latestReport = report
                self.delegate?.bleManager(self, didReceiveReport: report)
            }
        }
        
        packetParser.onRawFrameParsed = { [weak self] rawData in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.bleManager(self, didReceiveRawData: rawData)
            }
        }
    }
    
    // MARK: - 统一日志记录与精简摘要
    private func log(_ message: String, tag: String = "BleManager") {
        S02Logger.shared.log(message, tag: tag)
    }
    
    /// 清空所有交互日志
    public func clearLogs() {
        DispatchQueue.main.async {
            self.logMessages.removeAll()
        }
    }
    
    /// 获取精简诊断摘要 (过滤重复心跳与冗余Hex，仅保留关键动作与错误，适合复制至 QQ/微信等聊天窗口)
    public func getDiagnosticsSummary() -> String {
        let keywords = ["★", "连接", "断开", "就绪", "下发", "WiFiFlow", "Hotspot", "失败", "错误", "异常", "状态更新"]
        let keyEvents = logMessages.filter { msg in
            keywords.contains { kw in msg.contains(kw) }
        }
        
        let recent = Array(keyEvents.suffix(20))
        var summary = "=== S02LB 运行诊断摘要 (共 \(recent.count) 条关键记录) ===\n"
        if let rep = latestReport {
            summary += "当前状态: 电量 \(rep.soc)%, 充电: \(rep.charge), 热点: \(rep.wifiSSID ?? "-") (wifi_on: \(rep.wifiOn)), RTSP: \(rep.rtsp)\n"
        }
        summary += "----------------------------------------\n"
        summary += recent.joined(separator: "\n")
        summary += "\n========================================"
        return summary
    }
    
    // MARK: - 扫描控制
    
    /// 开始扫描 S02LB 眼镜设备 (默认 12 秒超时自动停止)
    public func startScan(timeout: TimeInterval = 12.0) {
        guard centralManager.state == .poweredOn else {
            log("蓝牙未就绪，当前状态: \(centralManager.state.rawValue)")
            return
        }
        
        stopScan()
        
        DispatchQueue.main.async {
            self.isScanning = true
            self.discoveredDevices.removeAll()
        }
        
        log("开始扫描 BLE 设备 (过滤前缀: \(BleConstants.deviceNamePrefixes.joined(separator: ", ")))...")
        
        // 注意：iOS CoreBluetooth 广播过滤若指定 ServiceUUID，若设备未将 0xAE00 放入广播包（AdvData）中会导致扫不到。
        // 与安卓端一致：扫描所有 BLE 设备，在 didDiscover 回调中按广播名/本地名前缀精准过滤。
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        
        scanTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.log("扫描已达到 \(timeout)s 超时，自动停止")
            self.stopScan()
        }
        scanTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    }
    
    /// 停止扫描
    public func stopScan() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        
        if isScanning {
            centralManager.stopScan()
            DispatchQueue.main.async {
                self.isScanning = false
            }
            log("已停止扫描")
        }
    }
    
    // MARK: - 连接与断开
    
    /// 连接指定设备
    public func connect(device: BleDeviceModel) {
        connect(peripheral: device.peripheral)
    }
    
    /// 连接指定的 CBPeripheral
    public func connect(peripheral: CBPeripheral) {
        stopScan()
        
        if let current = targetPeripheral, current.state == .connected || current.state == .connecting {
            disconnect()
        }
        
        self.targetPeripheral = peripheral
        peripheral.delegate = self
        
        let devName = peripheral.name ?? "未知"
        log("正在连接: \(devName) [\(peripheral.identifier.uuidString)] ...")
        
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }
    
    /// 断开当前连接
    public func disconnect() {
        if let peripheral = targetPeripheral {
            log("主动断开连接: \(peripheral.name ?? "")")
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    // MARK: - 发送控制命令
    
    /// 发送下行命令帧 (0xAE01 写无响应)
    /// - Parameter frame: 编码后的协议帧 (0xBE 0xBC + len + cmd + param)
    /// - Returns: 是否提交到底层发送队列
    @discardableResult
    public func send(frame: Data) -> Bool {
        guard let peripheral = targetPeripheral,
              peripheral.state == .connected,
              let rx = rxCharacteristic else {
            log("发送失败: 设备未连接或 0xAE01 特征未就绪")
            return false
        }
        
        peripheral.writeValue(frame, for: rx, type: .withoutResponse)
        log("下发数据: \(frame.hexString)")
        
        DispatchQueue.main.async {
            self.delegate?.bleManager(self, didSendFrame: frame, success: true)
        }
        return true
    }
    
    /// 发送指定枚举命令
    @discardableResult
    public func send(command: S02LbProtocol.Command, param: Data? = nil) -> Bool {
        let frame = S02LbProtocol.encode(command: command, param: param)
        return send(frame: frame)
    }
    
    /// 便捷下发时间同步指令 (自动取 iOS 设备当前时间)
    @discardableResult
    public func syncCurrentTime() -> Bool {
        let param = S02LbProtocol.timeParams(date: Date())
        log("下发时间同步: \(param.hexString)")
        return send(command: .setTime, param: param)
    }
    
    /// 便捷下发风扇档位指令 (0=关, 1-3=档位)
    @discardableResult
    public func setFan(level: Int) -> Bool {
        let param = S02LbProtocol.fanParam(level: level)
        log("设置风扇档位: \(level)")
        return send(command: .setFan, param: param)
    }
    
    /// 便捷下发 WiFi 密码 (8~16 字节)
    @discardableResult
    public func setWifiPassword(_ pw: String) -> Bool {
        guard let param = S02LbProtocol.wifiPasswordParam(password: pw) else {
            log("设置 WiFi 密码失败: 长度必须在 8~16 字节之间")
            return false
        }
        log("设置 WiFi 密码: \(pw)")
        return send(command: .setWifiPw, param: param)
    }
    
    // MARK: - 物奇 OTA (0x7033) 通道支持
    
    /// 启用 0x7033 OTA 服务与 0x2002 通知 (复用同一 GATT 连接)
    public func enableOtaService() {
        guard let peripheral = targetPeripheral, peripheral.state == .connected else {
            otaDelegate?.otaChannelReady(false, reason: "设备未连接")
            return
        }
        
        if isOtaNotifyEnabled {
            otaDelegate?.otaChannelReady(true, reason: "0x7033 OTA 服务已就绪")
            return
        }
        
        guard let otaTx = otaTxCharacteristic else {
            log("[OTA] 未找到 0x2002 通知特征")
            otaDelegate?.otaChannelReady(false, reason: "未找到 0x2002 特征")
            return
        }
        
        log("[OTA] 使能 0x2002 通知订阅...")
        peripheral.setNotifyValue(true, for: otaTx)
    }
    
    /// 发送一帧 OTA 数据 (0x2001 写无响应)
    @discardableResult
    public func otaSend(data: Data) -> Bool {
        guard let peripheral = targetPeripheral,
              peripheral.state == .connected,
              let rx = otaRxCharacteristic else {
            return false
        }
        peripheral.writeValue(data, for: rx, type: .withoutResponse)
        return true
    }
    
    /// 获取当前连接单包写无响应的最大有效载荷 (MTU - 3)
    public var maximumWriteLength: Int {
        guard let peripheral = targetPeripheral else { return 20 }
        return peripheral.maximumWriteValueLength(for: .withoutResponse)
    }
    
    // MARK: - 重置内部连接资源
    private func resetConnectionState() {
        packetParser.reset()
        rxCharacteristic = nil
        txCharacteristic = nil
        otaRxCharacteristic = nil
        otaTxCharacteristic = nil
        isOtaNotifyEnabled = false
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.isServicesReady = false
            self.hasBizService = false
            self.hasOtaService = false
            self.servicesSummary = "(尚未发现服务)"
            self.connectedDevice = nil
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BleManager: CBCentralManagerDelegate {
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("蓝牙适配器状态更新: \(central.state.rawValue)")
        DispatchQueue.main.async {
            self.bluetoothState = central.state
            self.delegate?.bleManager(self, didUpdateState: central.state)
        }
        
        if central.state != .poweredOn {
            stopScan()
            resetConnectionState()
        }
    }
    
    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        
        // 优先提取广播名（本地名称可能存在于 AdvData 或 ScanResponse）
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let deviceName = localName ?? peripheral.name
        
        guard let name = deviceName, !name.isEmpty else { return }
        
        // 校验设备名是否以指定前缀开头 (CAM-, G1-, S02LB)
        let isTargetDevice = BleConstants.deviceNamePrefixes.contains { prefix in
            name.hasPrefix(prefix)
        }
        guard isTargetDevice else { return }
        
        let device = BleDeviceModel(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        
        DispatchQueue.main.async {
            if let index = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[index].rssi = RSSI.intValue
                self.discoveredDevices[index].name = name
                self.discoveredDevices[index].lastSeen = Date()
            } else {
                self.discoveredDevices.append(device)
            }
            self.delegate?.bleManager(self, didDiscoverDevice: device)
        }
        
        // 日志节流: 针对同一设备 2s 内只打印一次，避免高频刷屏
        let now = Date()
        if let lastLog = lastScanLogTime[peripheral.identifier], now.timeIntervalSince(lastLog) < 2.0 {
            return
        }
        lastScanLogTime[peripheral.identifier] = now
        log("★ 发现目标设备: \(name) [\(peripheral.identifier.uuidString)] RSSI=\(RSSI)")
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("GATT 底层已连接: \(peripheral.name ?? "")，开始发现服务...")
        
        DispatchQueue.main.async {
            self.isConnected = true
            let dev = BleDeviceModel(peripheral: peripheral, name: peripheral.name, rssi: 0)
            self.connectedDevice = dev
            self.delegate?.bleManager(self, didChangeConnectionState: true, device: dev, error: nil)
        }
        
        // 发现 0xAE00 控制服务和 0x7033 物奇 OTA 服务
        peripheral.discoverServices([BleConstants.serviceUUID, BleConstants.otaServiceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        resetConnectionState()
        DispatchQueue.main.async {
            self.delegate?.bleManager(self, didChangeConnectionState: false, device: nil, error: error)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("连接已断开: \(error?.localizedDescription ?? "正常断开")")
        resetConnectionState()
        DispatchQueue.main.async {
            self.delegate?.bleManager(self, didChangeConnectionState: false, device: nil, error: error)
            self.otaDelegate?.otaDidDisconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BleManager: CBPeripheralDelegate {
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("发现服务异常: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services, !services.isEmpty else {
            log("未发现任何服务")
            return
        }
        
        var foundBiz = false
        var foundOta = false
        
        for service in services {
            if service.uuid == BleConstants.serviceUUID {
                foundBiz = true
                peripheral.discoverCharacteristics([BleConstants.rxCharUUID, BleConstants.txCharUUID], for: service)
            } else if service.uuid == BleConstants.otaServiceUUID {
                foundOta = true
                peripheral.discoverCharacteristics([BleConstants.otaRxCharUUID, BleConstants.otaTxCharUUID], for: service)
            }
        }
        
        // 容错兜底：部分物奇固件可能使用自定义 128-bit 别名，若未直接匹配，遍历所有服务特征
        if !foundBiz {
            log("未直接匹配到 0xAE00 服务，尝试遍历所有服务特征...")
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
        
        let biz = foundBiz
        let ota = foundOta
        DispatchQueue.main.async {
            self.hasBizService = biz
            self.hasOtaService = ota
            self.servicesSummary = "业务通道 0xAE00: \(biz ? "✓ 就绪" : "✗ 缺失") | OTA 通道 0x7033: \(ota ? "✓ 就绪" : "✗ 缺失")"
            self.log("[自检] \(self.servicesSummary)")
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("发现特征异常 [\(service.uuid.uuidString)]: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            if char.uuid == BleConstants.rxCharUUID {
                self.rxCharacteristic = char
                log("匹配到控制下行特征 RX (0xAE01, WriteWithoutResponse)")
            } else if char.uuid == BleConstants.txCharUUID {
                self.txCharacteristic = char
                log("匹配到控制上行特征 TX (0xAE02, Notify)，开始使能通知订阅...")
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == BleConstants.otaRxCharUUID {
                self.otaRxCharacteristic = char
                log("匹配到 OTA 下行特征 RX (0x2001)")
            } else if char.uuid == BleConstants.otaTxCharUUID {
                self.otaTxCharacteristic = char
                log("匹配到 OTA 上行特征 TX (0x2002)")
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("使能通知失败 [\(characteristic.uuid.uuidString)]: \(error.localizedDescription)")
            if characteristic.uuid == BleConstants.otaTxCharUUID {
                otaDelegate?.otaChannelReady(false, reason: "0x2002 使能通知失败: \(error.localizedDescription)")
            }
            return
        }
        
        if characteristic.uuid == BleConstants.txCharUUID {
            log("0xAE02 业务通知已成功开启！链路就绪，可以开始收发控制命令")
            DispatchQueue.main.async {
                self.isServicesReady = true
                self.delegate?.bleManager(self, didServicesBecomeReady: self.hasBizService, hasOtaService: self.hasOtaService)
                
                // 连接就绪后，对齐安卓逻辑：自动下发一次当前时间同步
                self.syncCurrentTime()
            }
        } else if characteristic.uuid == BleConstants.otaTxCharUUID {
            self.isOtaNotifyEnabled = true
            let maxMtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            log("[OTA] 0x2002 通知已使能，当前有效写入长度: \(maxMtu)")
            DispatchQueue.main.async {
                self.otaDelegate?.otaChannelReady(true, reason: "0x7033 服务就绪, MaxPayload=\(maxMtu)")
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("读取/接收特征值错误 [\(characteristic.uuid.uuidString)]: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value, !data.isEmpty else { return }
        
        if characteristic.uuid == BleConstants.txCharUUID {
            // 避免心跳大包 Hex 刷屏导致 QQ 聊天记录被冲爆，只在短包(<=30B 控制回包)时打印 Hex
            if data.count <= 30 {
                log("收到通知 [\(data.count)B]: \(data.hexString)")
            }
            // 输入流式粘包解包器
            packetParser.append(data: data)
        } else if characteristic.uuid == BleConstants.otaTxCharUUID {
            // 转发给 OTA 专用回调
            otaDelegate?.otaDidReceiveNotification(data: data)
        }
    }
    
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // 当底层发送缓冲区准备就绪，通知 OTA 发送队列（用于 OTA 高吞吐发包）
        otaDelegate?.otaDidWrite(success: true)
    }
}
