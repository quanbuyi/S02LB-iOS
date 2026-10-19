import Foundation

/// 物奇 OTA 固件包解析与校验模型 (OTA.bin)
///
/// 文件结构：
/// - [0..1] vid (大端)
/// - [2..3] pid (大端)
/// - [4..5] version (大端)
/// - [6..9] len (大端, 负载长度 = 文件总长度 - 18)
/// - [10..13] reserved (0)
/// - [14..17] crc32 (大端, 第 18 字节起的负载 CRC32)
/// - [18..] 负载 (pack_desc_t 结构的固件压缩数据)
public final class OtaPackage {
    public let name: String
    public let data: Data
    public let vid: UInt16
    public let pid: UInt16
    public let version: UInt16
    public let payloadLen: UInt32
    public let headerCrc: UInt32
    public let actualCrc: UInt32
    
    public init(name: String, data: Data) throws {
        guard data.count > OtaProtocol.headerLen else {
            throw NSError(domain: "OtaPackage", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "固件包太小 (\(data.count) 字节)，非有效 OTA 包"
            ])
        }
        
        // 拦截 zip / wpk 整机烧录包 (以 PK 开头)
        if data[0] == 0x50 && data[1] == 0x4B {
            throw NSError(domain: "OtaPackage", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "所选为整机烧录 zip/wpk 文件，请先通过 gen_ota_pkg 生成 OTA.bin 固件包"
            ])
        }
        
        self.name = name
        self.data = data
        self.vid = (UInt16(data[0]) << 8) | UInt16(data[1])
        self.pid = (UInt16(data[2]) << 8) | UInt16(data[3])
        self.version = (UInt16(data[4]) << 8) | UInt16(data[5])
        
        self.payloadLen = (UInt32(data[6]) << 24) |
                          (UInt32(data[7]) << 16) |
                          (UInt32(data[8]) << 8)  |
                          UInt32(data[9])
        
        self.headerCrc = (UInt32(data[14]) << 24) |
                         (UInt32(data[15]) << 16) |
                         (UInt32(data[16]) << 8)  |
                         UInt32(data[17])
        
        let payload = data.subdata(in: OtaProtocol.headerLen..<data.count)
        self.actualCrc = CRC32.checksum(data: payload)
    }
    
    /// 从本地文件 URL 加载 OTA 固件
    public static func load(from url: URL) throws -> OtaPackage {
        let fileData = try Data(contentsOf: url)
        return try OtaPackage(name: url.lastPathComponent, data: fileData)
    }
    
    /// 获取前 18 字节文件头
    public var header18: Data {
        return data.prefix(OtaProtocol.headerLen)
    }
    
    /// 检查头部长度与实际文件大小是否自洽
    public var isLengthConsistent: Bool {
        return payloadLen == UInt32(data.count - OtaProtocol.headerLen)
    }
    
    /// 校验 CRC32 是否匹配
    public var isCrcValid: Bool {
        return headerCrc == actualCrc
    }
    
    /// 固件综合有效性校验
    public var isValid: Bool {
        return isLengthConsistent && isCrcValid
    }
}
