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
    
    // MARK: - 动态 MAC 地址派生热点 SSID 测试 (避免固死某特定 SSID)
    func testDynamicMacSsidDerivation() {
        // 场景 A: 固件尚未开启 WiFi 仅上报 MAC 地址，自动提取 MAC 后六位
        let repA = S02LbReport(rawJson: """
        {"mac":"12:34:56:78:9a:bc","wifi":"0","wifi_on":0}
        """)
        XCTAssertEqual(repA.wifiSSID, "789abc", "必须从 MAC 地址动态派生后六位")
        
        // 场景 B: 另一台不同 MAC 的设备
        let repB = S02LbReport(rawJson: """
        {"mac":"AA:BB:CC:DD:EE:FF","wifi":"-","wifi_on":0}
        """)
        XCTAssertEqual(repB.wifiSSID, "ddeeff", "必须支持不同设备 MAC 动态派生")
        
        // 场景 C: 固件显式上报了 SSID，优先使用上报的 SSID
        let repC = S02LbReport(rawJson: """
        {"mac":"12:34:56:78:9a:bc","wifi":"CAM-998877,12345678,1","wifi_on":1}
        """)
        XCTAssertEqual(repC.wifiSSID, "CAM-998877", "显式上报时优先使用显式 SSID")
    }
    
    // MARK: - 本地网络接口子网判定测试 (区分眼镜专属热点与普通家庭/办公 Wi-Fi)
    func testNetworkInterfaceSubnetMatching() {
        let glassesCameraIP = "192.168.43.1"
        
        // 场景 1: 手机连入了眼镜热点，分配到了 192.168.43.x 的 IP
        let hotspotAssignedIP = "192.168.43.15"
        XCTAssertTrue(NetworkInterfaceHelper.isSameSubnet(ipA: hotspotAssignedIP, ipB: glassesCameraIP), "192.168.43.x 网段应判定为眼镜热点局域网")
        
        // 场景 2: 手机连接了家庭/办公 Wi-Fi (如 192.168.1.x)
        let homeWifiIP = "192.168.1.108"
        XCTAssertFalse(NetworkInterfaceHelper.isSameSubnet(ipA: homeWifiIP, ipB: glassesCameraIP), "192.168.1.x 应判定为其它 Wi-Fi，不得误判为已连接眼镜")
        
        // 场景 3: 手机连接了企业网 (如 10.0.0.x)
        let corpWifiIP = "10.0.0.55"
        XCTAssertFalse(NetworkInterfaceHelper.isSameSubnet(ipA: corpWifiIP, ipB: glassesCameraIP), "10.x 网段应判定为其它 Wi-Fi")
    }
}
