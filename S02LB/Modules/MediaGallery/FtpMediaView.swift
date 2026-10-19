import SwiftUI

/// S02LB 眼镜媒体相册与 FTP 下载面板
public struct FtpMediaView: View {
    @StateObject private var viewModel = FtpMediaViewModel()
    @ObservedObject private var coordinator = WifiRtspCoordinator.shared
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("▸ 眼镜媒体相册 (FTP 传输)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    let host = URL(string: coordinator.rtspUrl)?.host ?? "192.168.43.1"
                    viewModel.refreshFileList(host: host)
                }) {
                    HStack(spacing: 4) {
                        if viewModel.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        Text("刷新列表")
                            .font(.caption)
                    }
                }
                .disabled(!coordinator.isFtpReady || viewModel.isLoading || viewModel.isDownloading)
            }
            
            // 下载进度卡片
            if viewModel.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(viewModel.currentDownloadingFile ?? "正在下载")
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                        Text(viewModel.downloadStatusText)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    ProgressView(value: viewModel.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                }
                .padding(10)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(8)
            }
            
            // 错误提示
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            
            // 文件列表容器
            if viewModel.files.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                        Text(coordinator.isFtpReady ? "未检索到媒体文件，点击「刷新列表」" : "请先开启 WiFi 并连接眼镜热点以访问文件")
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
            } else {
                VStack(spacing: 6) {
                    ForEach(viewModel.files, id: \.self) { file in
                        mediaRow(file: file)
                    }
                }
            }
        }
    }
    
    private func mediaRow(file: String) -> some View {
        let isVideo = file.contains("IMG_") || file.hasSuffix(".mp4") || file.hasSuffix(".es")
        let isSaved = viewModel.savedFiles.contains(file)
        let isCurrent = viewModel.currentDownloadingFile == file
        
        return HStack(spacing: 10) {
            Image(systemName: isVideo ? "video.circle.fill" : "photo.circle.fill")
                .foregroundColor(isVideo ? .orange : .blue)
                .font(.system(size: 20))
            
            Text(file)
                .font(.footnote)
                .lineLimit(1)
            
            Spacer()
            
            if isSaved {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("已存相册")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            } else if isCurrent {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.7)
            } else {
                Button("下载至相册") {
                    let host = URL(string: coordinator.rtspUrl)?.host ?? "192.168.43.1"
                    viewModel.downloadAndSaveToAlbum(remotePath: file, host: host)
                }
                .font(.caption2)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(viewModel.isDownloading || !coordinator.isFtpReady)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(6)
    }
}
