import Foundation

public struct UtilityExpressionLimits: Sendable, Equatable {
    public let maxLength: Int
    public let maxDepth: Int
    public let maxOperations: Int
    public init(maxLength: Int = 256, maxDepth: Int = 16, maxOperations: Int = 128) {
        self.maxLength = maxLength; self.maxDepth = maxDepth; self.maxOperations = maxOperations
    }
}
public enum UtilityExpressionError: Error, Sendable, Equatable {
    case emptyInput, tooLong, invalidLimits, invalidCharacter, invalidNumber, unexpectedToken
    case missingOperand, unbalancedParentheses, divisionByZero, nonFiniteResult, depthLimit, operationLimit
}
/// 有界四则表达式；只解析数字和算符，不调用NSExpression、shell或运行时函数查找。
public enum UtilityExpression {
    public static func evaluate(_ expression: String, limits: UtilityExpressionLimits = .init()) throws -> Double {
        guard (1...4_096).contains(limits.maxLength), (1...64).contains(limits.maxDepth),
              (1...4_096).contains(limits.maxOperations) else { throw UtilityExpressionError.invalidLimits }
        guard expression.utf8.count <= limits.maxLength else { throw UtilityExpressionError.tooLong }
        let normalized = expression.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        var parser = Parser(bytes: Array(normalized.utf8), limits: limits)
        parser.skipWhitespace()
        guard !parser.atEnd else { throw UtilityExpressionError.emptyInput }
        let value = try parser.expression(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw UtilityExpressionError.unexpectedToken }
        guard value.isFinite else { throw UtilityExpressionError.nonFiniteResult }
        return value == 0 ? 0 : value
    }
    private struct Parser {
        let bytes: [UInt8]
        let limits: UtilityExpressionLimits
        var index = 0
        var operations = 0
        var atEnd: Bool { index >= bytes.count }
        mutating func skipWhitespace() {
            while !atEnd && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard !atEnd && bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func countOperation() throws {
            operations += 1
            guard operations <= limits.maxOperations else { throw UtilityExpressionError.operationLimit }
        }
        mutating func expression(depth: Int) throws -> Double {
            var result = try product(depth: depth)
            while true {
                if consume(43) { try countOperation(); result += try product(depth: depth) }
                else if consume(45) { try countOperation(); result -= try product(depth: depth) }
                else { break }
                guard result.isFinite else { throw UtilityExpressionError.nonFiniteResult }
            }
            return result
        }
        mutating func product(depth: Int) throws -> Double {
            var result = try unary(depth: depth)
            while true {
                if consume(42) { try countOperation(); result *= try unary(depth: depth) }
                else if consume(47) {
                    try countOperation()
                    let divisor = try unary(depth: depth)
                    guard divisor != 0 else { throw UtilityExpressionError.divisionByZero }
                    result /= divisor
                } else { break }
                guard result.isFinite else { throw UtilityExpressionError.nonFiniteResult }
            }
            return result
        }
        mutating func unary(depth: Int) throws -> Double {
            guard depth <= limits.maxDepth else { throw UtilityExpressionError.depthLimit }
            if consume(43) { try countOperation(); return try unary(depth: depth + 1) }
            if consume(45) { try countOperation(); return -(try unary(depth: depth + 1)) }
            return try primary(depth: depth)
        }
        mutating func primary(depth: Int) throws -> Double {
            skipWhitespace()
            guard !atEnd else { throw UtilityExpressionError.missingOperand }
            if consume(40) {
                let value = try expression(depth: depth + 1)
                guard consume(41) else { throw UtilityExpressionError.unbalancedParentheses }
                return value
            }
            return try number()
        }
        mutating func number() throws -> Double {
            skipWhitespace()
            let start = index
            var digits = 0
            while !atEnd && Self.digit(bytes[index]) { index += 1; digits += 1 }
            if !atEnd && bytes[index] == 46 {
                index += 1
                while !atEnd && Self.digit(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { throw UtilityExpressionError.invalidCharacter }
            if !atEnd && [69, 101].contains(bytes[index]) {
                index += 1
                if !atEnd && [43, 45].contains(bytes[index]) { index += 1 }
                let exponentStart = index
                while !atEnd && Self.digit(bytes[index]) { index += 1 }
                guard exponentStart < index else { throw UtilityExpressionError.invalidNumber }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw UtilityExpressionError.invalidNumber }
            guard value.isFinite else { throw UtilityExpressionError.nonFiniteResult }
            return value
        }
        static func digit(_ value: UInt8) -> Bool { (48...57).contains(value) }
    }
}
