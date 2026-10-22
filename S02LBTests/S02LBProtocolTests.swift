import XCTest
@testable import S02LB

final class S02LBProtocolTests: XCTestCase {
    
    // MARK: - 下行指令编码测试
    func testDownlinkEncoding() {
        // 拍照命令: 0xBE 0xBC 0x01 0x00
        let photoFrame = S02LbProtocol.encode(command: .photo)
        XCTAssertEqual(photoFrame.hexString, "BE BC 01 00")
        
        // 开始录像命令: 0xBE 0xBC 0x01 0x01
        let startRecFrame = S02LbProtocol.encode(command: .startRec)
        XCTAssertEqual(startRecFrame.hexString, "BE BC 01 01")
        
        // 停止录像命令: 0xBE 0xBC 0x01 0x02
        let stopRecFrame = S02LbProtocol.encode(command: .stopRec)
        XCTAssertEqual(stopRecFrame.hexString, "BE BC 01 02")
        
        // 设置风扇 2 档: 0xBE 0xBC 0x02 0x05 0x02
        let fanParam = S02LbProtocol.fanParam(level: 2)
        let fanFrame = S02LbProtocol.encode(command: .setFan, param: fanParam)
        XCTAssertEqual(fanFrame.hexString, "BE BC 02 05 02")
        
        // WiFi 密码设置: "12345678" -> 8 字节
        let pwParam = S02LbProtocol.wifiPasswordParam(password: "12345678")!
        let pwFrame = S02LbProtocol.encode(command: .setWifiPw, param: pwParam)
        XCTAssertEqual(pwFrame.count, 4 + 8)
        XCTAssertEqual(pwFrame[0], 0xBE)
        XCTAssertEqual(pwFrame[1], 0xBC)
        XCTAssertEqual(pwFrame[2], 9) // len = 1 (cmd) + 8 (pw)
        XCTAssertEqual(pwFrame[3], S02LbProtocol.Command.setWifiPw.rawValue)
    }
    
    // MARK: - 上行 JSON 状态解析与容错测试
    func testReportParsingStandardJson() {
        let json = """
        {"soc":"85","charge":"1","size":"64.0","free":"42.5","status":"1","mac":"AA:BB:CC:DD:EE:FF","ble_pass":"1234","version":"1.4.2","fan":"2","record":"3","buzzer":"1","wifi":"CAM_AP,88888888","key":"0","rtsp":"1,1700000000"}
        """
        let report = S02LbReport(rawJson: json)
        XCTAssertEqual(report.batteryLevel, 85)
        XCTAssertTrue(report.isCharging)
        XCTAssertEqual(report.size, "64.0")
        XCTAssertEqual(report.free, "42.5")
        XCTAssertTrue(report.isRecording)
        XCTAssertEqual(report.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(report.fanLevel, 2)
        XCTAssertTrue(report.isBuzzerOn)
        XCTAssertEqual(report.wifiSSID, "CAM_AP")
        XCTAssertEqual(report.wifiPassword, "88888888")
    }
    
    func testReportParsingFaultTolerantDanglingComma() {
        // 固件常见 Bug: 尾部带有逗号 {"soc":"90",}
        let malformedJson = """
        {"soc":"90","charge":"0","size":"32.0","free":"10.0","status":"0","version":"1.0.0",}
        """
        let report = S02LbReport(rawJson: malformedJson)
        XCTAssertEqual(report.batteryLevel, 90)
        XCTAssertFalse(report.isCharging)
        XCTAssertEqual(report.size, "32.0")
        XCTAssertEqual(report.isRecording, false)
        XCTAssertEqual(report.version, "1.0.0")
    }
    
    func testReportWifiParsingVariations() {
        // 1. 未开启/未就绪时上报 "0" (协议规范: 11 wifi 0 信息，未连接名称和密码都为0)
        let jsonOff = """
        {"soc":"80","wifi":"0"}
        """
        let repOff = S02LbReport(rawJson: jsonOff)
        XCTAssertNil(repOff.wifiSSID, "未开启时 wifi='0' 不应被解析为有效 SSID")
        XCTAssertNil(repOff.wifiPassword)
        XCTAssertFalse(repOff.isWifiApActive)
        
        // 2. 缺省或连字符 "-"
        let jsonDash = """
        {"soc":"80","wifi":"-"}
        """
        let repDash = S02LbReport(rawJson: jsonDash)
        XCTAssertNil(repDash.wifiSSID)
        XCTAssertNil(repDash.wifiPassword)
        XCTAssertFalse(repDash.isWifiApActive)
        
        // 3. 正常双字段: "CAM-05488,12345678"
        let jsonNormal = """
        {"soc":"80","wifi":"CAM-05488,12345678"}
        """
        let repNormal = S02LbReport(rawJson: jsonNormal)
        XCTAssertEqual(repNormal.wifiSSID, "CAM-05488")
        XCTAssertEqual(repNormal.wifiPassword, "12345678")
        XCTAssertTrue(repNormal.isWifiApActive)
        
        // 4. 三字段: "G1-05488,88888888,1"
        let jsonTriple = """
        {"soc":"80","wifi":"G1-05488,88888888,1"}
        """
        let repTriple = S02LbReport(rawJson: jsonTriple)
        XCTAssertEqual(repTriple.wifiSSID, "G1-05488")
        XCTAssertEqual(repTriple.wifiPassword, "88888888")
        XCTAssertTrue(repTriple.isWifiApActive)
    }
    
    // MARK: - 流式粘包与分包解包测试
    func testStreamingPacketDeframing() {
        let parser = BlePacketParser()
        var parsedReports: [S02LbReport] = []
        parser.onReportParsed = { report in
            parsedReports.append(report)
        }
        
        let json1 = "{\"soc\":\"50\",\"status\":\"0\"}"
        let json1Data = json1.data(using: .utf8)!
        var frame1 = Data([0xBC, 0xBB, UInt8(json1Data.count)])
        frame1.append(json1Data)
        
        let json2 = "{\"soc\":\"99\",\"status\":\"1\"}"
        let json2Data = json2.data(using: .utf8)!
        var frame2 = Data([0xBC, 0xBB, UInt8(json2Data.count)])
        frame2.append(json2Data)
        
        // 模拟 1: 粘包 (两帧合并在一个 BLE Notify 中送达)
        var combined = Data()
        combined.append(frame1)
        combined.append(frame2)
        
        parser.append(data: combined)
        XCTAssertEqual(parsedReports.count, 2)
        XCTAssertEqual(parsedReports[0].soc, "50")
        XCTAssertEqual(parsedReports[1].soc, "99")
        
        // 模拟 2: 分包 (一帧被拆分在两个不同的 Notify 数据包中到达)
        parsedReports.removeAll()
        parser.reset()
        
        let splitIndex = frame1.count / 2
        let slice1 = frame1.subdata(in: 0..<splitIndex)
        let slice2 = frame1.subdata(in: splitIndex..<frame1.count)
        
        parser.append(data: slice1)
        XCTAssertEqual(parsedReports.count, 0, "前半分包不应产生完整报告")
        
        parser.append(data: slice2)
        XCTAssertEqual(parsedReports.count, 1, "两包拼接后应成功解析完整报告")
        XCTAssertEqual(parsedReports[0].soc, "50")
    }
}
