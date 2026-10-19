import Foundation

/// S02LB 眼镜 BLE 协议常量与下行帧编码器
///
/// 帧格式规范：
/// 下行帧（手机 -> 眼镜）: `0xBE 0xBC + len(1B) + cmd(1B) + param[len-1]` (len 最大 16，len = 1 + param.count)
/// 上行帧（眼镜 -> 手机）: `0xBC 0xBB + len(1B) + JSON(len B)` (总长 <= 255)
public final class S02LbProtocol {
    
    // MARK: - 帧头常量
    public static let frameHead0: UInt8 = 0xBE
    public static let frameHead1: UInt8 = 0xBC
    
    public static let reportHead0: UInt8 = 0xBC
    public static let reportHead1: UInt8 = 0xBB
    
    // MARK: - 命令字定义
    public enum Command: UInt8, CaseIterable {
        case photo          = 0x00 // 拍照
        case startRec       = 0x01 // 开始录像
        case stopRec        = 0x02 // 停止录像
        case powerOff       = 0x03 // 关机
        case setTime        = 0x04 // 设置时间 (6字节: 年后两位/月/日/时/分/秒)
        case setFan         = 0x05 // 设置风扇档位 (1字节: 0关/1-3档)
        case setRec3Min     = 0x07 // 录像分段3分钟
        case setRec5Min     = 0x08 // 录像分段5分钟
        case setRecAlways   = 0x09 // 录像不分段(一直录像)
        case setBuzzOn      = 0x0A // 开启蜂鸣器
        case setBuzzOff     = 0x0B // 关闭蜂鸣器
        case setWifiPw      = 0x0C // 设置WiFi密码 (8~16字节 UTF-8)
        case setWifiOn      = 0x0D // 开启WiFi传输
        case setWifiOff     = 0x0E // 关闭WiFi传输
        case setBtPw        = 0x0F // 蓝牙配对密码
        case sdFormat       = 0x10 // 格式化SD卡
        case rtspStart      = 0x21 // 启动RTSP推流
        case rtspStop       = 0x22 // 停止RTSP推流
        case ledTest        = 0x88 // LED测试
        
        public var name: String {
            switch self {
            case .photo:        return "PHOTO 拍照"
            case .startRec:     return "START_REC 开始录像"
            case .stopRec:      return "STOP_REC 停止录像"
            case .powerOff:     return "PWR_OFF 关机"
            case .setTime:      return "SET_TIME 设置时间"
            case .setFan:       return "SET_FAN 设置风扇"
            case .setRec3Min:   return "SET_REC_3MIN 录像3分钟"
            case .setRec5Min:   return "SET_REC_5MIN 录像5分钟"
            case .setRecAlways: return "SET_REC_ALWAYS 一直录像"
            case .setBuzzOn:    return "SET_BUZZ_ON 蜂鸣器开"
            case .setBuzzOff:   return "SET_BUZZ_OFF 蜂鸣器关"
            case .setWifiPw:    return "SET_WIFI_PW 设置WiFi密码"
            case .setWifiOn:    return "SET_WIFI_ON WiFi传输开"
            case .setWifiOff:   return "SET_WIFI_OFF WiFi传输关"
            case .setBtPw:      return "SET_BT_PW 蓝牙配对密码"
            case .sdFormat:     return "SD_FMT 格式化SD卡"
            case .rtspStart:    return "RTSP_START 启动推流"
            case .rtspStop:     return "RTSP_STOP 停止推流"
            case .ledTest:      return "LED_TEST LED测试"
            }
        }
    }
    
    // MARK: - 编码方法
    
    /// 构造下行控制帧: `0xBE 0xBC + len + cmd + param`
    /// - Parameters:
    ///   - cmd: 命令字 (UInt8)
    ///   - param: 参数数据 (Data?)
    /// - Returns: 编码后的完整下行帧
    public static func encode(cmd: UInt8, param: Data? = nil) -> Data {
        let plen = param?.count ?? 0
        var frame = Data(capacity: 4 + plen)
        frame.append(frameHead0)
        frame.append(frameHead1)
        frame.append(UInt8(plen + 1)) // len 字段包含 cmd 字节
        frame.append(cmd)
        if let p = param, !p.isEmpty {
            frame.append(p)
        }
        return frame
    }
    
    /// 构造下行控制帧 (使用枚举)
    public static func encode(command: Command, param: Data? = nil) -> Data {
        return encode(cmd: command.rawValue, param: param)
    }
    
    // MARK: - 参数构造辅助函数
    
    /// 构造当前手机时间同步参数 (6 字节: 年(后两位) / 月 / 日 / 时 / 分 / 秒)
    public static func timeParams(date: Date = Date()) -> Data {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt8((comps.year ?? 2026) % 100)
        let month = UInt8(comps.month ?? 1)
        let day = UInt8(comps.day ?? 1)
        let hour = UInt8(comps.hour ?? 0)
        let minute = UInt8(comps.minute ?? 0)
        let second = UInt8(comps.second ?? 0)
        return Data([year, month, day, hour, minute, second])
    }
    
    /// 构造风扇档位参数 (1 字节: 0=关, 1=一档, 2=二档, 3=三档)
    public static func fanParam(level: Int) -> Data {
        let clamped = max(0, min(3, level))
        return Data([UInt8(clamped)])
    }
    
    /// 构造 WiFi 密码设置参数 (8~16 字节 ASCII/UTF-8)
    public static func wifiPasswordParam(password: String) -> Data? {
        guard let data = password.data(using: .utf8), data.count >= 8, data.count <= 16 else {
            return nil
        }
        return data
    }
    
    /// 获取命令名称字符串
    public static func cmdName(for cmd: UInt8) -> String {
        return Command(rawValue: cmd)?.name ?? String(format: "CMD 0x%02X", cmd)
    }
}
