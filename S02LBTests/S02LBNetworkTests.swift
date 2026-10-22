import XCTest
@testable import S02LB

final class S02LBNetworkTests: XCTestCase {
    
    // MARK: - RTSP 停止序列号距离算法测试
    func testRtspStopSequenceDistance() {
        let lastSeq: Int64 = 100
        let newSeq: Int64 = 105
        
        let distance = (newSeq - lastSeq) & 0x3fffffff
        XCTAssertEqual(distance, 5)
        XCTAssertLessThan(distance, 0x20000000)
        
        // 模拟环形溢出回绕
        let wrapLast: Int64 = 0x3ffffff0
        let wrapNew: Int64 = 0x00000005
        let wrapDistance = (wrapNew - wrapLast) & 0x3fffffff
        XCTAssertEqual(wrapDistance, 21)
        XCTAssertLessThan(wrapDistance, 0x20000000)
    }
    
    // MARK: - RTSP URL 解析测试
    func testRtspUrlParsing() {
        let defaultUrl = URL(string: "rtsp://192.168.43.1:554/6600")!
        XCTAssertEqual(defaultUrl.scheme, "rtsp")
        XCTAssertEqual(defaultUrl.host, "192.168.43.1")
        XCTAssertEqual(defaultUrl.port, 554)
        XCTAssertEqual(defaultUrl.path, "/6600")
        
        let customUrl = URL(string: "rtsp://192.168.1.100:8554/live")!
        XCTAssertEqual(customUrl.host, "192.168.1.100")
        XCTAssertEqual(customUrl.port, 8554)
    }
    
    // MARK: - 真实设备 Wi-Fi 硬件就绪与自动接管判定测试
    func testRealDeviceWifiApReadinessAndAdoption() {
        // 场景 1: 实机上报 wifi_on = 1 (热点已在广播)
        let jsonOn = """
        {"mac":"12:34:56:78:9a:bc","wifi":"789abc,12345678,1","wifi_on":1,"rtsp":"0,0,0,0"}
        """
        let repOn = S02LbReport(rawJson: jsonOn)
        XCTAssertEqual(repOn.wifiSSID, "789abc")
        XCTAssertEqual(repOn.wifiPassword, "12345678")
        XCTAssertEqual(repOn.wifiOn, 1)
        XCTAssertTrue(repOn.isWifiApReady, "wifi_on=1 时必须判定硬件就绪并触发自动接管")
        
        // 场景 2: 未开启状态 wifi_on = 0
        let jsonOff = """
        {"mac":"12:34:56:78:9a:bc","wifi":"789abc,12345678,0","wifi_on":0,"rtsp":"0,0,0,0"}
        """
        let repOff = S02LbReport(rawJson: jsonOff)
        XCTAssertEqual(repOff.wifiSSID, "789abc")
        XCTAssertEqual(repOff.wifiPassword, "12345678")
        XCTAssertEqual(repOff.wifiOn, 0)
        XCTAssertFalse(repOff.isWifiApReady, "wifi_on=0 时不得盲目发起连接")
    }
}
