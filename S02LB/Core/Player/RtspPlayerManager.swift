import Foundation
import Combine
import UIKit

/// RTSP 播放器管理中枢 (对接 WifiRtspCoordinator 状态机)
public final class RtspPlayerManager: ObservableObject {
    
    public static let shared = RtspPlayerManager()
    
    public let player: RtspPlayerProtocol
    
    @Published public private(set) var state: RtspPlaybackState = .idle
    @Published public private(set) var latencyMs: Int? = nil
    
    private var cancellables = Set<AnyCancellable>()
    
    private init(player: RtspPlayerProtocol = VLCRtspPlayer()) {
        self.player = player
        
        // 监听播放器状态流
        player.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state = newState
                if case .playing(_, let latency) = newState {
                    self?.latencyMs = latency
                } else if case .idle = newState {
                    self?.latencyMs = nil
                }
            }
            .store(in: &cancellables)
        
        // 绑定 WifiRtspCoordinator 状态机动作
        let coordinator = WifiRtspCoordinator.shared
        coordinator.onStartPlayer = { [weak self] url in
            S02Logger.shared.log("收到协调器启动拉流信号: \(url)", tag: "PlayerManager")
            self?.player.play(url: url)
        }
        
        coordinator.onStopPlayer = { [weak self] in
            S02Logger.shared.log("收到协调器停止拉流信号", tag: "PlayerManager")
            self?.player.stop()
        }
    }
}
