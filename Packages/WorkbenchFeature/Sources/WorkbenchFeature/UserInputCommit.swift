import Foundation
import KeyDockUI

extension WorkbenchModel {
    public var canCommitCurrentInput: Bool { !isShuttingDown && inputCommitAllowed() }
    /// 只用于交互式输入入口。计划与已冻结工作流不依赖无关窗口的输入法状态。
    @discardableResult public func performUserInputAction(_ action: () -> Void) -> Bool {
        guard canCommitCurrentInput else { return false }
        action(); return true
    }
}
