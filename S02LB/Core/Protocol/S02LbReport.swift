import Foundation

/// S02LB 眼镜上行 JSON 状态上报解析模型
///
/// 上行帧结构: `0xBC 0xBB + len(1B) + JSON(len B)`
/// 字段规范:
/// - soc: 电池剩余电量 (0-100)
/// - charge: 充电状态 (0 未充电 / 1 充电中)
/// - size: SD 卡总容量 (GB)
/// - free: SD 卡剩余可用容量 (GB)
/// - status: 设备工作状态 (0 待机 / 1 录像中)
/// - mac: 设备 MAC 地址
/// - ble_pass: 蓝牙配对密码
/// - version: 固件版本号
/// - fan: 风扇状态 (0 关 / 1-3 档)
/// - record: 录像分段时长 (3 / 5 / N)
/// - buzzer: 蜂鸣器状态 (0 关 / 1 开)
/// - wifi: WiFi 信息 ("ssid,password")
/// - key: 物理按键状态
/// - rtsp: 推流状态与停止响应 ("status,endTime[,seq,result]")
public struct S02LbReport {
    public let raw: String
    
    public var soc: String = "-"
    public var charge: String = "-"
    public var size: String = "-"
    public var free: String = "-"
    public var status: String = "-"
    public var mac: String = "-"
    public var blePass: String = "-"
    public var version: String = "-"
    public var fan: String = "-"
    public var record: String = "-"
    public var buzzer: String = "-"
    public var wifi: String = "-"
    public var wifiOn: Int = -1        // 0=未开启, 1=已开启, -1=未知
    public var key: String = "-"
    public var rtsp: String = "-"
    
    public var rtspStopSequence: Int64 = -1
    public var rtspStopResult: Int = -1
    
    // MARK: - 便捷计算属性
    
    public var batteryLevel: Int? {
        return Int(soc)
    }
    
    public var isCharging: Bool {
        return charge == "1"
    }
    
    public var isRecording: Bool {
        return status == "1"
    }
    
    public var fanLevel: Int {
        return Int(fan) ?? 0
    }
    
    public var isBuzzerOn: Bool {
        return buzzer == "1"
    }
    
    public var wifiSSID: String? {
        let trimmed = wifi.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过滤非有效配置: "0"、"-" 或空 (未开启/未就绪时固件返回 "0")
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "0" else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let first = parts[0]
        guard !first.isEmpty, first != "0", first != "-" else { return nil }
        return first
    }
    
    public var wifiPassword: String? {
        let trimmed = wifi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "0" else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let second = parts[1]
        guard !second.isEmpty, second != "0" else { return nil }
        return second
    }
    
    /// 热点是否已处于已配置/已开启状态
    public var isWifiApActive: Bool {
        return wifiSSID != nil
    }
    
    /// 热点是否已真正开启就绪并正在发射广播 (wifi_on == 1 或 wifi 字段后缀为 1)
    public var isWifiApReady: Bool {
        if wifiOn == 1 { return true }
        let parts = wifi.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count >= 3 && parts[2].trimmingCharacters(in: .whitespaces) == "1" {
            return true
        }
        return false
    }
    
    public var isStatusReport: Bool {
        return raw.contains("\"soc\"") || raw.contains("\"size\"") || raw.contains("\"mac\"")
    }
    
    // MARK: - 初始化与容错解析
    
    public init(rawJson: String) {
        self.raw = rawJson
        
        // 1. 清洗固件 JSON 可能携带的多余尾逗号 (如 {"soc":"20",})
        var clean = rawJson.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: ",\\s*\\}", with: "}", options: .regularExpression)
        clean = clean.replacingOccurrences(of: ",\\s*\\]", with: "]", options: .regularExpression)
        
        var parsedSuccessfully = false
        if let data = clean.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            
            self.soc     = S02LbReport.extractValue(from: obj, key: "soc")
            self.charge  = S02LbReport.extractValue(from: obj, key: "charge")
            self.size    = S02LbReport.extractValue(from: obj, key: "size")
            self.free    = S02LbReport.extractValue(from: obj, key: "free")
            self.status  = S02LbReport.extractValue(from: obj, key: "status")
            self.mac     = S02LbReport.extractValue(from: obj, key: "mac")
            self.blePass = S02LbReport.extractValue(from: obj, key: "ble_pass")
            self.version = S02LbReport.extractValue(from: obj, key: "version")
            self.fan     = S02LbReport.extractValue(from: obj, key: "fan")
            self.record  = S02LbReport.extractValue(from: obj, key: "record")
            self.buzzer  = S02LbReport.extractValue(from: obj, key: "buzzer")
            self.wifi    = S02LbReport.extractValue(from: obj, key: "wifi")
            if let wo = obj["wifi_on"] as? Int {
                self.wifiOn = wo
            } else if let woStr = obj["wifi_on"] as? String, let wo = Int(woStr) {
                self.wifiOn = wo
            }
            self.key     = S02LbReport.extractValue(from: obj, key: "key")
            self.rtsp    = S02LbReport.extractValue(from: obj, key: "rtsp")
            parsedSuccessfully = true
        }
        
        // 2. 如果标准 JSON 解析失败，使用正则兜底提取字段
        if !parsedSuccessfully {
            self.soc     = S02LbReport.regexExtract(from: rawJson, key: "soc")
            self.charge  = S02LbReport.regexExtract(from: rawJson, key: "charge")
            self.size    = S02LbReport.regexExtract(from: rawJson, key: "size")
            self.free    = S02LbReport.regexExtract(from: rawJson, key: "free")
            self.status  = S02LbReport.regexExtract(from: rawJson, key: "status")
            self.mac     = S02LbReport.regexExtract(from: rawJson, key: "mac")
            self.blePass = S02LbReport.regexExtract(from: rawJson, key: "ble_pass")
            self.version = S02LbReport.regexExtract(from: rawJson, key: "version")
            self.fan     = S02LbReport.regexExtract(from: rawJson, key: "fan")
            self.record  = S02LbReport.regexExtract(from: rawJson, key: "record")
            self.buzzer  = S02LbReport.regexExtract(from: rawJson, key: "buzzer")
            self.wifi    = S02LbReport.regexExtract(from: rawJson, key: "wifi")
            let woStr    = S02LbReport.regexExtract(from: rawJson, key: "wifi_on")
            self.wifiOn  = Int(woStr) ?? -1
            self.key     = S02LbReport.regexExtract(from: rawJson, key: "key")
            self.rtsp    = S02LbReport.regexExtract(from: rawJson, key: "rtsp")
        }
        
        // 3. 解析 RTSP 停止响应序列号与结果
        let (seq, res) = S02LbReport.parseRtspStop(value: self.rtsp)
        self.rtspStopSequence = seq
        self.rtspStopResult = res
        
        // UI 显示只保留 status 与 endTime
        let rtspParts = self.rtsp.split(separator: ",", omittingEmptySubsequences: false)
        if rtspParts.count >= 2 {
            self.rtsp = "\(rtspParts[0]),\(rtspParts[1])"
        }
    }
    
    // MARK: - 辅助解析函数
    
    private static func extractValue(from dict: [String: Any], key: String) -> String {
        if let val = dict[key] {
            return "\(val)"
        }
        return "-"
    }
    
    private static func regexExtract(from json: String, key: String) -> String {
        let pattern = "\"\(key)\"\\s*:\\s*(?:\"(.*?)\"|([\\w\\.-]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "-" }
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        if let match = regex.firstMatch(in: json, options: [], range: range) {
            if let r1 = Range(match.range(at: 1), in: json) {
                return String(json[r1])
            }
            if let r2 = Range(match.range(at: 2), in: json) {
                return String(json[r2])
            }
        }
        return "-"
    }
    
    /// 解析 rtsp 字段后缀中的序列号与状态 (格式: status,endTime,seq,result)
    public static func parseRtspStop(value: String) -> (sequence: Int64, result: Int) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 4 {
            if let seq = Int64(parts[2]),
               let res = Int(parts[3]),
               seq >= 0 && seq <= 0x3fffffff,
               res >= 0 && res <= 3 {
                return (seq, res)
            }
        }
        return (-1, -1)
    }
}
