import Foundation
import Combine

/// S02LB 媒体文件相册与 FTP 下载 ViewModel
@MainActor
public final class FtpMediaViewModel: ObservableObject {
    
    @Published public var files: [String] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadStatusText: String = ""
    @Published public var currentDownloadingFile: String? = nil
    @Published public var savedFiles: Set<String> = []
    
    private let ftpClient = FtpClient()
    private let photoManager = PhotoLibraryManager.shared
    
    public init() {}
    
    /// 刷新眼镜文件列表
    public func refreshFileList(host: String = "192.168.43.1") {
        guard !isLoading else { return }
        
        self.isLoading = true
        self.errorMessage = nil
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.ftpClient.connect(host: host)
                let list = try await self.ftpClient.listMediaFiles()
                self.files = list
                self.isLoading = false
                S02Logger.shared.log("成功刷新文件列表，共 \(list.count) 项", tag: "FTPMedia")
            } catch {
                self.isLoading = false
                self.errorMessage = "读取文件列表失败: \(error.localizedDescription)"
                S02Logger.shared.log("刷新文件列表错误: \(error.localizedDescription)", tag: "FTPMedia")
            }
        }
    }
    
    /// 下载指定文件并自动保存至系统相册
    public func downloadAndSaveToAlbum(remotePath: String, host: String = "192.168.43.1") {
        guard !isDownloading else { return }
        
        self.isDownloading = true
        self.currentDownloadingFile = remotePath
        self.downloadProgress = 0.0
        self.downloadStatusText = "准备下载..."
        self.errorMessage = nil
        
        let filename = (remotePath as NSString).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("S02LB_Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localFile = tempDir.appendingPathComponent(filename)
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.ftpClient.connect(host: host)
                
                let downloadedURL = try await self.ftpClient.download(remotePath: remotePath, to: localFile) { [weak self] transferred, total, percent in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.downloadProgress = percent
                        if total > 0 {
                            let currMB = Double(transferred) / (1024 * 1024)
                            let totalMB = Double(total) / (1024 * 1024)
                            self.downloadStatusText = String(format: "%.1f%% (%.1f / %.1f MB)", percent * 100, currMB, totalMB)
                        } else {
                            self.downloadStatusText = "已接收 \(transferred / 1024) KB"
                        }
                    }
                }
                
                self.downloadStatusText = "正在保存到系统相册..."
                
                // 保存至系统相册
                try await self.photoManager.saveMedia(fileURL: downloadedURL)
                
                self.savedFiles.insert(remotePath)
                self.isDownloading = false
                self.currentDownloadingFile = nil
                self.downloadStatusText = "已成功保存到系统相册！"
            } catch {
                self.isDownloading = false
                self.currentDownloadingFile = nil
                self.errorMessage = "下载/保存失败: \(error.localizedDescription)"
            }
        }
    }
}
