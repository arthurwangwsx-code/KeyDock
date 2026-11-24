import Foundation
import Testing
@testable import CommandCore

@Suite struct UtilityExpressionTests {
    @Test func precedenceParenthesesUnaryAndScientificNumbers() throws {
        #expect(try UtilityExpression.evaluate(" 2 + 3 * (4 - 1) ") == 11)
        #expect(try UtilityExpression.evaluate("-(-2) + +.5 * 4") == 4)
        #expect(try UtilityExpression.evaluate("1e3 / 2 + 1.25e-2") == 500.0125)
        #expect(try UtilityExpression.evaluate("8 / 4 / 2") == 1)
        #expect(try UtilityExpression.evaluate("10 - 2 - 3") == 5)
    }
    @Test func finiteOnlyAndDivisionByNegativeZero() {
        #expect(throws: UtilityExpressionError.divisionByZero) { try UtilityExpression.evaluate("1 / -0") }
        #expect(throws: UtilityExpressionError.nonFiniteResult) { try UtilityExpression.evaluate("1e308 * 10") }
        #expect(throws: UtilityExpressionError.nonFiniteResult) { try UtilityExpression.evaluate("1e999") }
    }
    @Test func syntaxCannotReachFunctionsIdentifiersOrShell() {
        for expression in ["sqrt(4)", "$(echo secret)", "1; 2", "NaN", "Infinity", "@count", "2(3)", "1 2", "1e+", "1 +", "(1+2", "1+2)"] {
            #expect(throws: (any Error).self) { try UtilityExpression.evaluate(expression) }
        }
    }
    @Test func lengthDepthAndOperationBudgetsAreSeparate() {
        #expect(throws: UtilityExpressionError.tooLong) { try UtilityExpression.evaluate(String(repeating: "1", count: 257)) }
        #expect(throws: UtilityExpressionError.depthLimit) { try UtilityExpression.evaluate("((((1))))", limits: .init(maxDepth: 3)) }
        #expect(throws: UtilityExpressionError.depthLimit) { try UtilityExpression.evaluate("----1", limits: .init(maxDepth: 3)) }
        #expect(throws: UtilityExpressionError.operationLimit) { try UtilityExpression.evaluate("1+2+3", limits: .init(maxOperations: 1)) }
        #expect(throws: UtilityExpressionError.invalidLimits) { try UtilityExpression.evaluate("1", limits: .init(maxDepth: 0)) }
    }
    @Test func blankAndMalformedNumbersFailWithoutCoercion() {
        #expect(throws: UtilityExpressionError.emptyInput) { try UtilityExpression.evaluate(" \n\t") }
        #expect(throws: UtilityExpressionError.invalidNumber) { try UtilityExpression.evaluate("1e-") }
        #expect(throws: UtilityExpressionError.unexpectedToken) { try UtilityExpression.evaluate("1..2") }
    }
}
@Suite struct SnippetDefinitionTests {
    @Test func unicodeAndLiteralCodeRoundTripWithoutExpansion() throws {
        let text = "你好\n\t$(never-run) {{literal}}"
        let snippet = try SnippetDefinition(name: "  合成片段  ", text: text)
        let restored = try JSONDecoder().decode(SnippetDefinition.self, from: JSONEncoder().encode(snippet))
        #expect(restored == snippet && restored.name == "合成片段" && restored.text == text)
    }
    @Test func invalidAndOversizedDefinitionsAreRejected() {
        #expect(throws: SnippetValidationError.emptyName) { try SnippetDefinition(name: " \n ", text: "Synthetic") }
        #expect(throws: SnippetValidationError.invalidName) { try SnippetDefinition(name: "One\nTwo", text: "Synthetic") }
        #expect(throws: SnippetValidationError.textTooLong) { try SnippetDefinition(name: "Synthetic", text: String(repeating: "你", count: 21_846)) }
        #expect(throws: SnippetValidationError.invalidText) { try SnippetDefinition(name: "Synthetic", text: "One\0Two") }
    }
    @Test func decodingCannotBypassValidation() throws {
        let object: [String: String] = ["id": UUID().uuidString, "name": "Synthetic", "text": ""]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SnippetValidationError.emptyText) { try JSONDecoder().decode(SnippetDefinition.self, from: data) }
    }
}
