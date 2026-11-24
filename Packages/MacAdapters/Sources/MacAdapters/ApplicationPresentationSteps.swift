/// 显示与激活是同一显式动作中不同的系统请求；前一步的Bool不代替后置状态。
@MainActor enum ApplicationPresentationSteps {
    static func perform(needsUnhide: Bool, validate: () -> Bool, unhide: () -> Bool, activate: () -> Bool) -> ApplicationDispatchResult {
        guard validate() else { return .rejected }
        let unhideAcknowledged = needsUnhide ? unhide() : false
        // 取消／实例变更必须在第二个系统请求前生效，不能重选目标。
        guard validate() else { return needsUnhide ? .partial : .rejected }
        if activate() { return .accepted }
        return unhideAcknowledged ? .partial : .rejected
    }
}
