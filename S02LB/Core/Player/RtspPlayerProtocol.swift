import Foundation
import UIKit
import Combine

/// RTSP 播放器运行状态
public enum RtspPlaybackState: Equatable {
    case idle
    case connecting(String)
    case playing(url: String, latencyMs: Int?)
    case buffering
    case error(String)
    
    public var description: String {
        switch self {
        case .idle:
            return "空闲"
        case .connecting(let url):
            return "正在连接: \(url)"
        case .playing(_, let latency):
            if let lat = latency {
                return "播放中 (首帧 \(lat)ms)"
            }
            return "播放中"
        case .buffering:
            return "缓冲中..."
        case .error(let msg):
            return "播放错误: \(msg)"
        }
    }
}

/// RTSP 播放器抽象协议 (支持 MobileVLCKit / FFmpeg / 自研解码器多后端替换)
public protocol RtspPlayerProtocol: AnyObject {
    /// 播放状态监听
    var statePublisher: AnyPublisher<RtspPlaybackState, Never> { get }
    /// 当前播放状态
    var currentState: RtspPlaybackState { get }
    /// 渲染视图
    var renderView: UIView { get }
    /// 首帧渲染耗时 (毫秒)
    var firstFrameLatencyMs: Int? { get }
    
    /// 开始播放
    func play(url: String)
    /// 停止播放并释放渲染缓冲区
    func stop()
    /// 暂停播放
    func pause()
    /// 恢复播放
    func resume()
}
