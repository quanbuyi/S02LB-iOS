import XCTest
@testable import S02LB

final class S02LBPlayerTests: XCTestCase {
    
    func testPlayerLifecycle() {
        let player = VLCRtspPlayer()
        XCTAssertEqual(player.currentState, .idle)
        
        let testUrl = "rtsp://192.168.43.1:554/6600"
        player.play(url: testUrl)
        
        // 初始切到连接中
        if case .connecting(let url) = player.currentState {
            XCTAssertEqual(url, testUrl)
        } else {
            XCTFail("播放器初始状态应为 connecting")
        }
        
        // 停止播放
        player.stop()
        XCTAssertEqual(player.currentState, .idle)
    }
    
    func testPlaybackStateDescriptions() {
        XCTAssertEqual(RtspPlaybackState.idle.description, "空闲")
        XCTAssertEqual(RtspPlaybackState.connecting("rtsp://test").description, "正在连接: rtsp://test")
        XCTAssertEqual(RtspPlaybackState.playing(url: "rtsp://test", latencyMs: 250).description, "播放中 (首帧 250ms)")
        XCTAssertEqual(RtspPlaybackState.buffering.description, "缓冲中...")
        XCTAssertEqual(RtspPlaybackState.error("网络超时").description, "播放错误: 网络超时")
    }
    
    func testNativeRtspPlayerInitAndRenderView() {
        let nativePlayer = NativeRtspPlayer()
        XCTAssertEqual(nativePlayer.currentState, .idle)
        XCTAssertNotNil(nativePlayer.renderView)
        XCTAssertTrue(nativePlayer.renderView is SampleBufferVideoView)
        
        let testUrl = "192.168.43.1:554/6600"
        nativePlayer.play(url: testUrl)
        
        // 验证自动补全 rtsp://
        if case .connecting(let url) = nativePlayer.currentState {
            XCTAssertEqual(url, "rtsp://192.168.43.1:554/6600")
        } else {
            XCTFail("NativeRtspPlayer 应处于 connecting 状态")
        }
        
        nativePlayer.stop()
        XCTAssertEqual(nativePlayer.currentState, .idle)
    }
}
