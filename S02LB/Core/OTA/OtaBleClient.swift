import Foundation
import Combine

/// 物奇 wqota v2 OTA 升级客户端
///
/// 状态机时序流程：
/// 1. `0x02` 获取设备信息 (版本、vid/pid、电量)
/// 2. `0xE2` 询问能否升级 (携带 18 字节固件文件头，校验设备电量与兼容性)
/// 3. `0xE3` 进入升级模式 (设备擦除 Flash，可能耗时数秒)
/// 4. `0xE5` 连续分块下发固件 (根据 MTU 计算最优单包大小)
/// 5. `0xE8` 结束升级与固件完整性校验
/// 6. `0x03` 重启设备生效新固件
public final class OtaBleClient: ObservableObject {
    
    public enum State: String {
        case idle       = "空闲"
        case waitReady  = "等待服务就绪"
        case getInfo    = "读取设备信息"
        case inquiry    = "询问设备状态"
        case enter      = "进入升级模式"
        case streaming  = "传输固件数据"
        case verifying  = "校验固件"
        case rebooting  = "重启设备"
        case done       = "升级完成"
        case failed     = "升级失败"
    }
    
    // MARK: - 响应式属性
    @Published public private(set) var state: State = .idle
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var progressDetail: String = ""
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var deviceInfoText: String = ""
    
    private let bleManager: BleManager
    private var package: OtaPackage?
    
    private var sn: Int = 1
    private func nextSn() -> Int {
        sn = (sn % 255) + 1
        return sn
    }
    
    private var currentChunkOffset: UInt32 = 0
    private var chunkSize: Int = 240 // 默认单包大小，将根据 CoreBluetooth MTU 动态调整
    
    public init(bleManager: BleManager = .shared) {
        self.bleManager = bleManager
        self.bleManager.otaDelegate = self
    }
    
    /// 开始 OTA 固件升级
    public func start(with pkg: OtaPackage) {
        guard pkg.isValid else {
            self.errorMessage = "固件包校验未通过"
            self.state = .failed
            return
        }
        
        self.package = pkg
        self.state = .waitReady
        self.progress = 0.0
        self.progressDetail = "正在准备 0x7033 OTA 通道..."
        
        // 动态调整最佳分包大小 (MTU - 协议开销 17 字节)
        let maxMtu = bleManager.maximumWriteLength
        self.chunkSize = min(492, max(64, maxMtu - OtaProtocol.blockOverhead))
        
        S02Logger.shared.log("启动 OTA 升级: \(pkg.name), 大小=\(pkg.data.count) 字节, 单包=\(chunkSize) 字节", tag: "OTA")
        
        bleManager.enableOtaService()
    }
    
    /// 步骤 1: 0x02 读取设备信息
    private func requestDeviceInfo() {
        self.state = .getInfo
        self.progressDetail = "正在核对设备硬件与电量..."
        let mask: UInt32 = 0x3F // 请求版本、VID/PID、电量等全部属性
        let pkt = OtaProtocol.packet(opcode: .getDeviceInfo, data: OtaProtocol.cmdGetDeviceInfo(sn: nextSn(), mask: mask))
        bleManager.otaSend(data: pkt)
    }
    
    /// 步骤 2: 0xE2 询问能否升级
    private func sendInquiry() {
        guard let pkg = package else { return }
        self.state = .inquiry
        self.progressDetail = "正在询问设备能否升级..."
        let pkt = OtaProtocol.packet(opcode: .inquiry, data: OtaProtocol.cmdInquiry(sn: nextSn(), fileHeader18: pkg.header18))
        bleManager.otaSend(data: pkt)
    }
    
    /// 步骤 3: 0xE3 进入升级模式
    private func sendEnterUpdate() {
        self.state = .enter
        self.progressDetail = "正在进入升级模式并擦除 Flash..."
        let pkt = OtaProtocol.packet(opcode: .enterUpdate, data: OtaProtocol.cmdSnOnly(sn: nextSn()))
        bleManager.otaSend(data: pkt)
    }
    
    /// 步骤 4: 0xE5 传输固件数据块
    private func sendNextBlock() {
        guard let pkg = package, state == .streaming else { return }
        
        let total = UInt32(pkg.data.count)
        if currentChunkOffset >= total {
            // 所有数据块已发完，进入校验
            finishUpdate()
            return
        }
        
        let remaining = Int(total - currentChunkOffset)
        let len = min(remaining, chunkSize)
        let chunk = pkg.data.subdata(in: Int(currentChunkOffset)..<Int(currentChunkOffset) + len)
        
        let pkt = OtaProtocol.packet(opcode: .firmwareBlock, data: OtaProtocol.cmdFirmwareBlock(sn: sn, appOffset: currentChunkOffset, chunkData: chunk))
        bleManager.otaSend(data: pkt)
        
        currentChunkOffset += UInt32(len)
        let percent = Double(currentChunkOffset) / Double(total)
        let offsetKb = currentChunkOffset / 1024
        let totalKb = total / 1024
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progress = percent
            self.progressDetail = String(format: "已传输 %.1f%% (%d / %d KB)", percent * 100, offsetKb, totalKb)
        }
    }
    
    /// 步骤 5: 0xE8 结束升级与设备校验
    private func finishUpdate() {
        self.state = .verifying
        self.progressDetail = "传输完成，正在校验固件完整性..."
        let pkt = OtaProtocol.packet(opcode: .getSyncState, data: OtaProtocol.cmdSnOnly(sn: nextSn()))
        bleManager.otaSend(data: pkt)
    }
    
    /// 步骤 6: 0x03 重启设备
    private func rebootDevice() {
        self.state = .rebooting
        self.progressDetail = "固件校验通过，正在重启设备生效..."
        let pkt = OtaProtocol.packet(opcode: .reboot, data: OtaProtocol.cmdReboot(sn: nextSn(), type: 0))
        bleManager.otaSend(data: pkt)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.state = .done
            self.progress = 1.0
            self.progressDetail = "升级成功！设备已重启"
        }
    }
}

// MARK: - BleOtaDelegate
extension OtaBleClient: BleOtaDelegate {
    
    public func otaChannelReady(_ isReady: Bool, reason: String) {
        guard isReady else {
            self.state = .failed
            self.errorMessage = reason
            return
        }
        
        if state == .waitReady {
            requestDeviceInfo()
        }
    }
    
    public func otaDidReceiveNotification(data: Data) {
        guard let frame = OtaProtocol.parse(raw: data) else { return }
        
        guard let opcode = OtaProtocol.Opcode(rawValue: frame.opcode) else { return }
        
        switch opcode {
        case .getDeviceInfo:
            S02Logger.shared.log("收到设备信息响应", tag: "OTA")
            sendInquiry()
            
        case .inquiry:
            let result = frame.data.count >= 2 ? Int(frame.data[1]) : -1
            if result == OtaProtocol.resultOk {
                S02Logger.shared.log("设备允许升级，准备进入升级模式", tag: "OTA")
                sendEnterUpdate()
            } else {
                let err = OtaProtocol.resultName(result)
                self.state = .failed
                self.errorMessage = "设备拒绝升级: \(err)"
            }
            
        case .enterUpdate:
            if frame.status == 0 {
                S02Logger.shared.log("成功进入升级模式，开始推送固件数据流", tag: "OTA")
                self.state = .streaming
                self.currentChunkOffset = UInt32(OtaProtocol.headerLen) // 首包从 18 字节后开始
                sendNextBlock()
            } else {
                self.state = .failed
                self.errorMessage = "进入升级模式失败 status=\(frame.status)"
            }
            
        case .firmwareBlock:
            // 收到分段确认或请求下一个窗口
            if state == .streaming {
                sendNextBlock()
            }
            
        case .getSyncState:
            if frame.status == 0 {
                S02Logger.shared.log("设备校验通过，下发重启指令", tag: "OTA")
                rebootDevice()
            } else {
                self.state = .failed
                self.errorMessage = "设备校验固件失败 status=\(frame.status)"
            }
            
        default:
            break
        }
    }
    
    public func otaDidWrite(success: Bool) {
        if state == .streaming {
            sendNextBlock()
        }
    }
    
    public func otaDidDisconnect() {
        if state != .rebooting && state != .done && state != .idle {
            self.state = .failed
            self.errorMessage = "升级途中蓝牙连接断开"
        }
    }
}
