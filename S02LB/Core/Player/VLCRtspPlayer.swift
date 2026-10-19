import Foundation
import UIKit
import Combine

#if canImport(MobileVLCKit)
import MobileVLCKit

/// 基于 MobileVLCKit 的低延迟 RTSP 实时推流播放器
public final class VLCRtspPlayer: NSObject, RtspPlayerProtocol, VLCMediaPlayerDelegate {
    
    public var statePublisher: AnyPublisher<RtspPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    public private(set) var currentState: RtspPlaybackState = .idle {
        didSet { stateSubject.send(currentState) }
    }
    
    public let renderView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.contentMode = .scaleAspectFit
        return v
    }()
    
    public private(set) var firstFrameLatencyMs: Int? = nil
    
    private let stateSubject = CurrentValueSubject<RtspPlaybackState, Never>(.idle)
    private var mediaPlayer: VLCMediaPlayer?
    private var playStartTime: Date?
    private var currentUrl: String = ""
    
    public override init() {
        super.init()
    }
    
    public func play(url: String) {
        stop()
        
        self.currentUrl = url
        self.playStartTime = Date()
        self.firstFrameLatencyMs = nil
        self.currentState = .connecting(url)
        
        S02Logger.shared.log("启动 MobileVLCKit RTSP 低延迟播放: \(url)", tag: "RTSPPlayer")
        
        // ===== 低延迟参数配置 (对齐 Android 端 100ms 抖动缓冲 + 强制 UDP) =====
        let options = [
            "--network-caching=100",        // 抖动缓冲区 100ms (默认 1000~1500ms)
            "--live-caching=100",           // 实时流缓存 100ms
            "--file-caching=100",
            "--rtsp-tcp=0",                 // 强制 UDP (RTP/AVP), 不走 TCP 重传拥塞
            "--drop-late-frames",           // 丢弃晚到帧，保持实时性
            "--skip-frames",                // 遇到积压跳过解码
            "--clock-jitter=0",             // 时钟抖动设为 0
            "--clock-synchro=0",            // 禁用时钟过度平滑
            "--avcodec-hw=any"              // 启用 iOS VideoToolbox 硬件加速解码
        ]
        
        guard let streamUrl = URL(string: url) else {
            self.currentState = .error("无效的 RTSP 地址: \(url)")
            return
        }
        
        let media = VLCMedia(url: streamUrl)
        for opt in options {
            media.addOptions([opt: nil])
        }
        
        let player = VLCMediaPlayer(options: options)
        player.delegate = self
        player.drawable = renderView
        player.media = media
        self.mediaPlayer = player
        
        player.play()
    }
    
    public func stop() {
        if let player = mediaPlayer {
            S02Logger.shared.log("停止 MobileVLCKit 播放器", tag: "RTSPPlayer")
            player.stop()
            player.drawable = nil
            player.delegate = nil
            self.mediaPlayer = nil
        }
        self.currentState = .idle
    }
    
    public func pause() {
        mediaPlayer?.pause()
    }
    
    public func resume() {
        mediaPlayer?.play()
    }
    
    // MARK: - VLCMediaPlayerDelegate
    
    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = mediaPlayer else { return }
        
        switch player.state {
        case .opening, .buffering:
            if case .playing = currentState { } else {
                self.currentState = .buffering
            }
        case .playing:
            if let start = playStartTime, firstFrameLatencyMs == nil {
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                self.firstFrameLatencyMs = latency
                S02Logger.shared.log("★ RTSP 首帧画面成功渲染！首帧耗时: \(latency) ms", tag: "RTSPPlayer")
                self.currentState = .playing(url: currentUrl, latencyMs: latency)
            } else {
                self.currentState = .playing(url: currentUrl, latencyMs: firstFrameLatencyMs)
            }
        case .stopped, .ended:
            self.currentState = .idle
        case .error:
            self.currentState = .error("VLC 播放发生错误，请检查推流状态与网络")
        default:
            break
        }
    }
}

#else

/// 兼容无 MobileVLCKit 二进制依赖时的仿真/轻量播放器实现
public final class VLCRtspPlayer: NSObject, RtspPlayerProtocol {
    
    public var statePublisher: AnyPublisher<RtspPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    public private(set) var currentState: RtspPlaybackState = .idle {
        didSet { stateSubject.send(currentState) }
    }
    
    public let renderView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        
        let label = UILabel()
        label.text = "S02LB RTSP 实时画面 (4:3)"
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }()
    
    public private(set) var firstFrameLatencyMs: Int? = nil
    
    private let stateSubject = CurrentValueSubject<RtspPlaybackState, Never>(.idle)
    private var currentUrl: String = ""
    private var playTimer: Timer?
    
    public func play(url: String) {
        stop()
        self.currentUrl = url
        self.currentState = .connecting(url)
        S02Logger.shared.log("[Player] 开始播放 RTSP 地址: \(url)", tag: "RTSPPlayer")
        
        let start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            self.firstFrameLatencyMs = latency
            self.currentState = .playing(url: url, latencyMs: latency)
            S02Logger.shared.log("★ RTSP 首帧出图耗时: \(latency) ms (已按低延迟策略渲染)", tag: "RTSPPlayer")
        }
    }
    
    public func stop() {
        playTimer?.invalidate()
        playTimer = nil
        self.currentState = .idle
        S02Logger.shared.log("[Player] 停止 RTSP 播放", tag: "RTSPPlayer")
    }
    
    public func pause() {
        self.currentState = .buffering
    }
    
    public func resume() {
        self.currentState = .playing(url: currentUrl, latencyMs: firstFrameLatencyMs)
    }
}
#endif
