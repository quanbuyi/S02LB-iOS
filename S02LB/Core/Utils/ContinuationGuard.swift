import Foundation

/// 线程安全的异步 Continuation 单次执行守卫
///
/// 用于在网络回调与超时多分支竞争时，严格保证 checkedContinuation.resume 仅被调用一次，
/// 同时满足 Swift 严格并发模型中对捕获变量的 Sendable 约束。
public final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false
    
    public init() {}
    
    /// 仅在首次调用时执行 action，后续调用静默忽略
    @discardableResult
    public func runOnce(_ action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return false }
        isResumed = true
        action()
        return true
    }
}
