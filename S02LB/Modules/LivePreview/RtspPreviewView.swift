import SwiftUI

/// S02LB 4:3 比例低延迟 RTSP 实时画面预览控件
public struct RtspPreviewView: View {
    @ObservedObject private var playerManager = RtspPlayerManager.shared
    @ObservedObject private var coordinator = WifiRtspCoordinator.shared
    @State private var isFullscreen: Bool = false
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("▸ 实时视频预览 (4:3 低延迟)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let latency = playerManager.latencyMs {
                    Text("首帧: \(latency)ms")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
            }
            
            // 4:3 比例视频容器 (1440x1080 真实比例)
            ZStack {
                Color.black
                
                // 底层视频渲染层
                RtspPlayerRenderView()
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                
                // 状态覆盖层
                statusOverlay
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .cornerRadius(10)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    // MARK: - 状态图层覆盖
    @ViewBuilder
    private var statusOverlay: some View {
        switch playerManager.state {
        case .idle:
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
                Text("未启动视频预览")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("点击上方「启动推流」拉取眼镜实时画面")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
            }
            
        case .connecting, .buffering:
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                Text("正在拉取低延迟 RTSP 视频流...")
                    .font(.caption)
                    .foregroundColor(.white)
                Text("UDP 传输 / 100ms 抖动缓存")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding()
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
            
        case .playing:
            VStack {
                HStack {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("LIVE 1440x1080")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    
                    Spacer()
                    
                    Button(action: {
                        isFullscreen.toggle()
                    }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(8)
                
                Spacer()
            }
            
        case .error(let msg):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("重新连接") {
                    coordinator.startRtsp(preview: true)
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .background(Color.black.opacity(0.7))
            .cornerRadius(8)
        }
    }
}
