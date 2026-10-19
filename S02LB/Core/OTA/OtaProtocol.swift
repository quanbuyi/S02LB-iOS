import Foundation

/// 物奇 wqota v2 OTA 协议常量与编解码器
///
/// 协议规范：
/// - GATT 服务: 0x7033 / RX 0x2001 (写无响应) / TX 0x2002 (Notify)
/// - 帧结构: `70 07 6E + flags(1B) + opcode(1B) + len(2B 大端) + data + 33`
/// - 总开销: len + 8 字节，必须单次 GATT 写传输完整帧
/// - 多字节整型均采用网络大端字节序 (Big-Endian)
/// - 固件文件头部由 18 字节元数据组成 (vid, pid, version, fileLen, crc32 等)
public final class OtaProtocol {
    
    // MARK: - 帧标识与常量
    public static let prefix: [UInt8] = [0x70, 0x07, 0x6E]
    public static let suffix: UInt8   = 0x33
    public static let flagsCmd: UInt8 = 0xC0 // is_cmd=1, need_rsp=1, source=0
    
    public static let headerLen: Int  = 18   // sizeof(ota_file_header_t) = 18
    public static let blockOverhead: Int = 17 // 帧固定 8 字节开销 + 块命令参数 9 字节
    
    // MARK: - 操作码 (Opcode)
    public enum Opcode: UInt8 {
        case getDeviceInfo    = 0x02
        case reboot           = 0x03
        case getFileOffset    = 0xE1
        case inquiry          = 0xE2
        case enterUpdate      = 0xE3
        case exitUpdate       = 0xE4
        case firmwareBlock    = 0xE5
        case getRefreshStatus = 0xE6
        case getSyncState     = 0xE8
    }
    
    // MARK: - 响应状态码
    public static func statusName(_ status: Int) -> String {
        switch status {
        case 0:  return "成功"
        case 1:  return "失败"
        case 2:  return "未知命令"
        case 3:  return "忙"
        case 4:  return "无响应"
        case 5:  return "CRC 错误"
        case 6:  return "整包 CRC 错误"
        case 7:  return "参数错误"
        case 8:  return "响应数据超长"
        case 9:  return "不支持"
        case 10: return "部分操作失败"
        case 11: return "不可达"
        default: return "未知错误 (\(status))"
        }
    }
    
    // MARK: - 0xE2 询问能否升级结果码
    public static let resultOk: Int             = 0x03
    public static let resultLowBattery: Int     = 0x01
    public static let resultFwInfoError: Int    = 0x02
    public static let resultNoSpace: Int        = 0x04
    public static let resultTwsDisconnect: Int  = 0x10
    public static let resultCaseClosed: Int     = 0x11
    
    public static func resultName(_ result: Int) -> String {
        switch result {
        case resultOk:            return "可以升级"
        case resultLowBattery:    return "电量不足 (<20%)"
        case resultFwInfoError:   return "固件信息不匹配 (vid/pid 与设备不一致)"
        case resultNoSpace:       return "设备 OTA 存储空间不足"
        case resultTwsDisconnect: return "TWS 未连接"
        case resultCaseClosed:    return "充电盒已合盖"
        default:                  return "未知状态 (\(result))"
        }
    }
    
    // MARK: - 解析后的一帧模型
    public struct Frame {
        public let isCmd: Bool
        public let opcode: UInt8
        public let sn: Int
        public let data: Data
        
        public var status: Int {
            guard !data.isEmpty else { return -1 }
            return Int(data[0])
        }
    }
    
    // MARK: - 帧编解码
    
    /// 构造下行命令帧
    public static func packet(opcode: Opcode, data: Data? = nil) -> Data {
        let len = data?.count ?? 0
        var p = Data(capacity: 8 + len)
        p.append(contentsOf: prefix)
        p.append(flagsCmd)
        p.append(opcode.rawValue)
        p.append(UInt8((len >> 8) & 0xFF))
        p.append(UInt8(len & 0xFF))
        if let d = data, !d.isEmpty {
            p.append(d)
        }
        p.append(suffix)
        return p
    }
    
    /// 解析上行原始数据帧
    public static func parse(raw: Data) -> Frame? {
        guard raw.count >= 8 else { return nil }
        
        // 校验前缀 70 07 6E 与后缀 33
        guard raw[0] == prefix[0], raw[1] == prefix[1], raw[2] == prefix[2],
              raw[raw.count - 1] == suffix else {
            return nil
        }
        
        let len = (Int(raw[5]) << 8) | Int(raw[6])
        guard len == raw.count - 8 else { return nil }
        
        let flags = raw[3]
        let isCmd = (flags & 0x80) != 0
        let opcode = raw[4]
        let payload = raw.subdata(in: 7..<(7 + len))
        
        let sn: Int
        if isCmd {
            sn = len >= 1 ? Int(payload[0]) : -1
        } else {
            sn = len >= 2 ? Int(payload[1]) : -1
        }
        
        return Frame(isCmd: isCmd, opcode: opcode, sn: sn, data: payload)
    }
    
    // MARK: - 命令负载组装
    
    /// 0x02 读取设备信息: sn + mask(4B 大端)
    public static func cmdGetDeviceInfo(sn: Int, mask: UInt32) -> Data {
        var d = Data(capacity: 5)
        d.append(UInt8(sn & 0xFF))
        d.append(UInt8((mask >> 24) & 0xFF))
        d.append(UInt8((mask >> 16) & 0xFF))
        d.append(UInt8((mask >> 8) & 0xFF))
        d.append(UInt8(mask & 0xFF))
        return d
    }
    
    /// 仅包含 sn 的通用命令 (0xE1 / 0xE3 / 0xE4 / 0xE6 / 0xE8)
    public static func cmdSnOnly(sn: Int) -> Data {
        return Data([UInt8(sn & 0xFF)])
    }
    
    /// 0xE2 询问升级: sn + 18 字节文件头
    public static func cmdInquiry(sn: Int, fileHeader18: Data) -> Data {
        var d = Data(capacity: 1 + headerLen)
        d.append(UInt8(sn & 0xFF))
        d.append(fileHeader18.prefix(headerLen))
        return d
    }
    
    /// 0xE5 下发固件数据块: sn(1B) + appOffset(4B 大端) + 数据(nB) + crc32(4B 大端)
    public static func cmdFirmwareBlock(sn: Int, appOffset: UInt32, chunkData: Data) -> Data {
        var d = Data(capacity: 1 + 4 + chunkData.count + 4)
        d.append(UInt8(sn & 0xFF))
        
        // 4 字节 appOffset 大端
        d.append(UInt8((appOffset >> 24) & 0xFF))
        d.append(UInt8((appOffset >> 16) & 0xFF))
        d.append(UInt8((appOffset >> 8) & 0xFF))
        d.append(UInt8(appOffset & 0xFF))
        
        // 固件数据
        d.append(chunkData)
        
        // 4 字节 CRC32 校验和
        let crc = CRC32.checksum(data: chunkData)
        d.append(UInt8((crc >> 24) & 0xFF))
        d.append(UInt8((crc >> 16) & 0xFF))
        d.append(UInt8((crc >> 8) & 0xFF))
        d.append(UInt8(crc & 0xFF))
        
        return d
    }
    
    /// 0x03 设备重启命令: sn(1B) + type(1B, 0=重启)
    public static func cmdReboot(sn: Int, type: UInt8 = 0) -> Data {
        return Data([UInt8(sn & 0xFF), type])
    }
}
