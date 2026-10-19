import Foundation
import os.log

/// S02LB 统一日志管理工具
public final class S02Logger {
    public static let shared = S02Logger()
    
    /// 是否在控制台打印日志
    public var isEnabled: Bool = true
    
    /// UI 日志监听器
    public var onLogAppended: ((String) -> Void)?
    
    private let lock = NSLock()
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
    
    private init() {}
    
    public func log(_ message: String, tag: String = "S02LB") {
        guard isEnabled else { return }
        lock.lock()
        let timeStr = dateFormatter.string(from: Date())
        lock.unlock()
        let formatted = "[\(timeStr)] [\(tag)] \(message)"
        
        print(formatted)
        
        DispatchQueue.main.async {
            self.onLogAppended?(formatted)
        }
    }
}
