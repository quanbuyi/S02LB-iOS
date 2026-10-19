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
}
