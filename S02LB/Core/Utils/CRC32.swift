import Foundation

/// 标准 IEEE 802.3 CRC32 算法实现（用于物奇 OTA 固件块校验）
public struct CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
    
    /// 计算指定 Data 的 CRC32 校验和
    public static func checksum(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
    
    /// 计算切片数据的 CRC32
    public static func checksum(data: Data, offset: Int, length: Int) -> UInt32 {
        guard offset >= 0, length > 0, data.count >= offset + length else { return 0 }
        let sub = data.subdata(in: offset..<(offset + length))
        return checksum(data: sub)
    }
}
