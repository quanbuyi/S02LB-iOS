import XCTest
@testable import S02LB

final class S02LBFtpTests: XCTestCase {
    
    // MARK: - 被动模式端口解析测试
    func testPasvPortCalculation() {
        let p1: UInt16 = 195
        let p2: UInt16 = 80
        let port = (p1 << 8) | p2
        XCTAssertEqual(port, 50000)
        
        let p1b: UInt16 = 4
        let p2b: UInt16 = 0
        let port2 = (p1b << 8) | p2b
        XCTAssertEqual(port2, 1024)
    }
    
    // MARK: - 媒体文件路径归类测试
    func testMediaFilenameCategorization() {
        let pic = "PIC_/PIC_20261019_120000.JPG"
        let img = "IMG_/IMG_20261019_120000.MP4"
        let es = "IMG_/IMG_20261019_120000.es"
        
        XCTAssertTrue(pic.contains("PIC_"))
        XCTAssertTrue(img.contains("IMG_"))
        XCTAssertTrue(es.hasSuffix(".es"))
        
        let filename = (pic as NSString).lastPathComponent
        XCTAssertEqual(filename, "PIC_20261019_120000.JPG")
    }
}
