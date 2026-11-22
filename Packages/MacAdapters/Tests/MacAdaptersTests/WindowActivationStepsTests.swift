import Testing
@testable import MacAdapters

/// 仅验证执行顺序和系统返回值；不访问真实应用、AX权限或桌面。
@Suite @MainActor struct WindowActivationStepsTests {
    @Test func activationRejectionStopsBeforeRaisingOrChangingFocus() throws {
        var steps: [String] = []
        do {
            try WindowActivationSteps.perform(
                activateApplication: { steps.append("activate"); return false },
                raiseWindow: { steps.append("raise"); return true },
                setFocusedWindow: { steps.append("setFocus"); return true },
                isTargetFocused: { steps.append("readFocus"); return true }
            )
            Issue.record("Rejected activation must be reported")
        } catch DesktopError.windowActivationFailed {}
        #expect(steps == ["activate"])
    }

    @Test func raiseFailureStopsBeforeFocusMutation() throws {
        var steps: [String] = []
        do {
            try WindowActivationSteps.perform(
                activateApplication: { steps.append("activate"); return true },
                raiseWindow: { steps.append("raise"); return false },
                setFocusedWindow: { steps.append("setFocus"); return true },
                isTargetFocused: { steps.append("readFocus"); return true }
            )
            Issue.record("Failed raise must be reported")
        } catch DesktopError.windowActivationFailed {}
        #expect(steps == ["activate", "raise"])
    }

    @Test func unsupportedFocusSetterAcceptsTheAlreadyFocusedTarget() throws {
        var steps: [String] = []
        try WindowActivationSteps.perform(
            activateApplication: { steps.append("activate"); return true },
            raiseWindow: { steps.append("raise"); return true },
            setFocusedWindow: { steps.append("setFocus"); return false },
            isTargetFocused: { steps.append("readFocus"); return true }
        )
        #expect(steps == ["activate", "raise", "setFocus", "readFocus"])
    }

    @Test func unsupportedSetterWithoutTheTargetFocusFails() throws {
        var steps: [String] = []
        do {
            try WindowActivationSteps.perform(
                activateApplication: { steps.append("activate"); return true },
                raiseWindow: { steps.append("raise"); return true },
                setFocusedWindow: { steps.append("setFocus"); return false },
                isTargetFocused: { steps.append("readFocus"); return false }
            )
            Issue.record("An unfocused target must not be reported as switched")
        } catch DesktopError.windowActivationFailed {}
        #expect(steps == ["activate", "raise", "setFocus", "readFocus"])
    }
}
