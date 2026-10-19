import SwiftUI
import UIKit

/// UIViewRepresentable 封装的底层 RTSP 渲染视图
public struct RtspPlayerRenderView: UIViewRepresentable {
    
    private let player: RtspPlayerProtocol
    
    public init(player: RtspPlayerProtocol = RtspPlayerManager.shared.player) {
        self.player = player
    }
    
    public func makeUIView(context: Context) -> UIView {
        return player.renderView
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        // 渲染视图由底层 Player 维护，无需重复刷新
    }
}
