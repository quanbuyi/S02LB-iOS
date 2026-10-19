import Foundation
import Photos
import UIKit

/// iOS 系统相册保存管理器 (支持保存图片/视频并归类到 S02LB 专属相册)
public final class PhotoLibraryManager {
    
    public enum PhotoError: LocalizedError {
        case accessDenied
        case saveFailed(String)
        case albumCreationFailed
        
        public var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "相册写入权限被拒绝，请在系统设置中允许 S02LB 访问相册"
            case .saveFailed(let msg):
                return "保存到相册失败: \(msg)"
            case .albumCreationFailed:
                return "创建 S02LB 专属相册失败"
            }
        }
    }
    
    public static let shared = PhotoLibraryManager()
    private let albumName = "S02LB"
    
    private init() {}
    
    /// 请求相册写入权限
    public func requestAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            return true
        }
        
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
            }
        }
    }
    
    /// 保存媒体文件到系统相册并添加至 S02LB 相册
    /// - Parameter fileURL: 本地已下载好的文件 URL
    public func saveMedia(fileURL: URL) async throws {
        let authorized = await requestAuthorization()
        guard authorized else {
            throw PhotoError.accessDenied
        }
        
        let album = try await getOrCreateAlbum()
        let isVideo = isVideoFile(url: fileURL)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                // 1. 创建 Asset
                let request: PHAssetChangeRequest?
                if isVideo {
                    request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
                
                // 2. 关联至 S02LB 相册
                if let placeholder = request?.placeholderForCreatedAsset, let targetAlbum = album {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: targetAlbum)
                    albumChangeRequest?.addAssets([placeholder] as NSArray)
                }
            }, completionHandler: { success, error in
                if success {
                    S02Logger.shared.log("成功保存至相册: \(fileURL.lastPathComponent)", tag: "PhotoLibrary")
                    continuation.resume()
                } else {
                    let err = error ?? NSError(domain: "PhotoLibrary", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知错误"])
                    continuation.resume(throwing: PhotoError.saveFailed(err.localizedDescription))
                }
            })
        }
    }
    
    // MARK: - 辅助方法
    
    private func isVideoFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "es", "m4v", "avi", "mkv"].contains(ext)
    }
    
    private func getOrCreateAlbum() async throws -> PHAssetCollection? {
        // 查找已有相册
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        if let first = collection.firstObject {
            return first
        }
        
        // 创建新相册
        let box = PlaceholderBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.albumName)
                box.placeholder = request.placeholderForCreatedAssetCollection
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoError.albumCreationFailed)
                }
            })
        }
        
        if let placeholder = box.placeholder {
            let res = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
            return res.firstObject
        }
        return nil
    }
}

private final class PlaceholderBox: @unchecked Sendable {
    var placeholder: PHObjectPlaceholder?
}
