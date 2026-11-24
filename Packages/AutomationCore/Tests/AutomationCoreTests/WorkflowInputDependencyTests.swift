import Foundation
import Testing
@testable import AutomationCore

struct WorkflowInputDependencyTests {
    private let command = UUID(), ai = UUID()
    private func needs(_ steps: [WorkflowStep], consuming: Bool = false) throws -> Bool {
        let plan = try WorkflowCompiler.compile(.init(name: "Synthetic dependency", steps: steps), availableCommandIDs: [command], availableAIActionIDs: [ai])
        return plan.requiresInitialInput(commandsUsingInput: consuming ? [command] : [])
    }
    @Test func transformsTrackFinalOutputWithoutPromptingForDeadIntermediateText() throws {
        #expect(try needs([.init(operation: .transform(.trim)), .init(operation: .transform(.uppercase), input: .previousOutput)]))
        #expect(try needs([.init(operation: .transform(.trim)), .init(operation: .transform(.uppercase), input: .literal("Synthetic fixed"))]) == false)
        #expect(try needs([.init(operation: .savedCommand(command)), .init(operation: .transform(.uppercase), input: .previousOutput)]) == false)
    }
    @Test func aiConsumptionNeedsInputEvenWhenLaterOutputOverwritesIt() throws {
        #expect(try needs([.init(operation: .aiAction(ai)), .init(operation: .transform(.trim), input: .literal("Synthetic fixed"))]))
        #expect(try needs([.init(operation: .transform(.trim)), .init(operation: .aiAction(ai), input: .previousOutput)]))
        #expect(try needs([.init(operation: .savedCommand(command)), .init(operation: .aiAction(ai), input: .previousOutput)]) == false)
        #expect(try needs([.init(operation: .aiAction(ai), input: .literal("Synthetic fixed"))]) == false)
    }
    @Test func commandsOnlyConsumeInputWhenTheSavedArgvUsesTheWholePlaceholder() throws {
        #expect(try needs([.init(operation: .savedCommand(command))]) == false)
        #expect(try needs([.init(operation: .savedCommand(command))], consuming: true))
        #expect(try needs([.init(operation: .savedCommand(command), input: .literal("Synthetic fixed"))], consuming: true) == false)
        #expect(try needs([.init(operation: .transform(.trim)), .init(operation: .savedCommand(command), input: .previousOutput)], consuming: true))
    }
    @Test func manualInputIsNotAskedTwiceButCannotReplaceAnExplicitInitialBinding() throws {
        #expect(try needs([.init(operation: .manualInput), .init(operation: .aiAction(ai), input: .previousOutput)]) == false)
        #expect(try needs([.init(operation: .transform(.trim)), .init(operation: .manualInput, input: .previousOutput), .init(operation: .transform(.uppercase), input: .previousOutput)]) == false)
        #expect(try needs([.init(operation: .manualInput), .init(operation: .aiAction(ai), input: .workflowInput)]))
    }
}
