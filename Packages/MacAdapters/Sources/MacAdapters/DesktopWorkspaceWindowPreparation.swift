import Foundation
import CommandCore

/// 应用身份和无标题窗口必须先由调用方核验；本层只消费已冻结对象。
public struct DesktopWorkspaceWindowRequest: Sendable {
    public let entryID: UUID
    public let target: DesktopWindowTarget
    public let layout: WindowLayout
    public let display: DesktopWorkspaceDisplayPolicy
    public init(entryID: UUID, target: DesktopWindowTarget, layout: WindowLayout, display: DesktopWorkspaceDisplayPolicy) {
        self.entryID = entryID; self.target = target; self.layout = layout; self.display = display
    }
}

public struct PreparedDesktopWorkspaceWindow: Sendable {
    public let entryID: UUID
    public let plan: PreparedWindowLayout
}

extension WindowLayoutController {
    /// 所有prepare与统一复核均成功才返回；任一目标失败时绝不在此层布局。
    public func prepareWorkspaceWindows(_ requests: [DesktopWorkspaceWindowRequest], displays: WindowDisplaySnapshot,
                                        invocationDisplayID: String?) async throws -> [PreparedDesktopWorkspaceWindow] {
        guard (1...SavedDesktopWorkspace.maximumEntries).contains(requests.count),
              Set(requests.map(\.entryID)).count == requests.count,
              requests.allSatisfy({ DesktopWorkspaceEntry.allowedLayouts.contains($0.layout) }) else { throw WindowLayoutError.unsupported }
        for (index, request) in requests.enumerated() {
            guard !requests.prefix(index).contains(where: {
                ($0.target.identity.pid == request.target.identity.pid && $0.target.identity.launchDate == request.target.identity.launchDate)
                    || CFEqual($0.target.reference.element, request.target.reference.element)
            }) else { throw WindowLayoutError.changed }
        }
        var result: [PreparedDesktopWorkspaceWindow] = []
        for request in requests {
            try Task.checkCancellation()
            let destination: String?
            switch request.display {
            case .windowDisplay: destination = nil
            case .mainDisplay:
                guard let primary = displays.primaryDisplayID else { throw WindowLayoutError.unavailable }; destination = primary
            case .invocationDisplay:
                guard let invocationDisplayID else { throw WindowLayoutError.unavailable }; destination = invocationDisplayID
            }
            let plan = try await prepare(request.layout, target: request.target, displays: displays, destinationDisplayID: destination)
            result.append(.init(entryID: request.entryID, plan: plan))
        }
        for prepared in result { try Task.checkCancellation(); try await revalidate(prepared.plan) }
        return result
    }
}
