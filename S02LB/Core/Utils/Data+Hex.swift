import Foundation

extension Data {
    /// 转换为十六进制大写字符串（以空格分隔，如 "BE BC 01 00"）
    public var hexString: String {
        return map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// 转换为紧凑十六进制大写字符串（如 "BEBC0100"）
    public var compactHexString: String {
        return map { String(format: "%02X", $0) }.joined()
    }
    
    /// 从十六进制字符串初始化 Data
    public init?(hexString: String) {
        let cleanHex = hexString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        
        guard cleanHex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: cleanHex.count / 2)
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let byteString = cleanHex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
    
    /// 读取大端序 UInt16
    public func readBigEndianUInt16(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }
    
    /// 读取大端序 UInt32
    public func readBigEndianUInt32(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return (UInt32(self[offset]) << 24) |
               (UInt32(self[offset + 1]) << 16) |
               (UInt32(self[offset + 2]) << 8) |
               UInt32(self[offset + 3])
    }
}
