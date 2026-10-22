import Foundation

/// BLE 上行数据流分包/粘包解帧器
///
/// 针对 S02LB 上行格式: `0xBC 0xBB + len(1B) + JSON(len B)`
/// 能够自动处理底层 BLE MTU 截断、分包到达以及多包粘包情况。
public final class BlePacketParser {
    
    public typealias OnReportParsed = (S02LbReport) -> Void
    public typealias OnRawFrameParsed = (Data) -> Void
    
    private var rxBuffer = Data()
    private let lock = NSLock()
    
    public var onReportParsed: OnReportParsed?
    public var onRawFrameParsed: OnRawFrameParsed?
    
    public init() {}
    
    /// 清空接收缓冲区
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        rxBuffer.removeAll()
    }
    
    /// 输入新接收到的 BLE Notify 数据包，执行流式解包
    public func append(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        rxBuffer.append(data)
        
        while rxBuffer.count > 0 {
            // 1. 寻找帧头首字节 0xBC
            guard let firstHeadIndex = rxBuffer.firstIndex(of: S02LbProtocol.reportHead0) else {
                rxBuffer.removeAll()
                break
            }
            
            // 丢弃 0xBC 之前的无效脏数据
            if firstHeadIndex > rxBuffer.startIndex {
                rxBuffer.removeSubrange(rxBuffer.startIndex..<firstHeadIndex)
            }
            
            // 2. 检查是否有足够的字节读取帧头与长度 (0xBC 0xBB + len 共 3 字节)
            if rxBuffer.count < 3 {
                break
            }
            
            // 3. 校验第二个帧头字节是否为 0xBB
            let secondByte = rxBuffer[rxBuffer.index(rxBuffer.startIndex, offsetBy: 1)]
            if secondByte != S02LbProtocol.reportHead1 {
                // 不匹配，丢弃该首字节继续向后查找
                rxBuffer.removeFirst()
                continue
            }
            
            // 4. 读取 JSON 长度
            let length = Int(rxBuffer[rxBuffer.index(rxBuffer.startIndex, offsetBy: 2)])
            let totalFrameLength = 3 + length
            
            // 5. 检查缓冲区是否已接收到完整帧
            if rxBuffer.count < totalFrameLength {
                // 数据包被 BLE MTU 分包截断，等待后续数据
                break
            }
            
            // 6. 提取完整帧与 JSON 负载
            let frameData = rxBuffer.subdata(in: rxBuffer.startIndex..<rxBuffer.index(rxBuffer.startIndex, offsetBy: totalFrameLength))
            let payloadData = rxBuffer.subdata(in: rxBuffer.index(rxBuffer.startIndex, offsetBy: 3)..<rxBuffer.index(rxBuffer.startIndex, offsetBy: totalFrameLength))
            
            // 从缓冲区移除已消费的帧
            rxBuffer.removeSubrange(rxBuffer.startIndex..<rxBuffer.index(rxBuffer.startIndex, offsetBy: totalFrameLength))
            
            onRawFrameParsed?(frameData)
            
            if let jsonString = String(data: payloadData, encoding: .utf8) {
                let report = S02LbReport(rawJson: jsonString)
                onReportParsed?(report)
            } else {
                S02Logger.shared.log("负载 UTF-8 解码失败: \(payloadData.hexString)", tag: "BlePacketParser")
            }
        }
    }
}
