/// 在已验证目标身份后执行；闭包只封装当前系统调用，不引入重试或后台生命周期。
@MainActor enum WindowActivationSteps {
    static func perform(
        activateApplication: () -> Bool,
        raiseWindow: () -> Bool,
        setFocusedWindow: () -> Bool,
        isTargetFocused: () -> Bool
    ) throws {
        guard activateApplication() else { throw DesktopError.windowActivationFailed }
        guard raiseWindow() else { throw DesktopError.windowActivationFailed }
        // 一些应用不支持写FocusedWindow；成功raise后可以读回确认，避免误拒绝。
        if !setFocusedWindow(), !isTargetFocused() { throw DesktopError.windowActivationFailed }
    }
}
