import Foundation

/// S02LB 应用全局宏与功能开关配置
///
/// 核心说明：
/// 1. 调试阶段默认开启交互日志显示与收集；
/// 2. 后续发布/出货时，只需将 `enableInteractionLog` 改为 `false`，或在 project.yml 中移除 `-DENABLE_INTERACTION_LOG` 宏；
/// 3. 当该宏关闭时：
///    - 界面底部的「交互日志」区域完全不渲染；
///    - BleManager 停止向内存追加 `logMessages`，避免高吞吐下的内存累积与 UI 重绘。
public enum AppConfig {
    
    // MARK: - 交互日志宏控制
    
    #if ENABLE_INTERACTION_LOG
    /// 编译宏开启时，默认启用日志
    public static let enableInteractionLog: Bool = true
    #else
    /// 编译宏未开启时，默认关闭日志
    public static let enableInteractionLog: Bool = false
    #endif
}
