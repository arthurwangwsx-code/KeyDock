import Foundation

public enum UnitConversionError: Error, Sendable, Equatable {
    case emptyInput, inputTooLong, invalidSyntax, invalidNumber, numberOutOfRange
    case unsupportedUnit(String), incompatibleUnits, belowAbsoluteZero, resultOutOfRange
}

public struct UnitConversionResult: Sendable, Equatable {
    public let sourceValue: Double
    public let sourceUnit: String
    public let targetUnit: String
    public let value: Double
}

/// 只解释有限单位词表与单个数字；不求值表达式、函数、脚本或远程内容。
public enum UnitConversion {
    public static let maximumInputBytes = 256

    /// 语法为“数字 空格 单位 空格 to 空格 单位”；空格也可使用Tab。
    public static func convert(_ input: String) throws -> UnitConversionResult {
        guard input.utf8.prefix(maximumInputBytes + 1).count <= maximumInputBytes else {
            throw UnitConversionError.inputTooLong
        }
        guard !input.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) else {
            throw UnitConversionError.invalidSyntax
        }
        let parts = input.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !parts.isEmpty else { throw UnitConversionError.emptyInput }
        guard parts.count == 4, parts[2] == "to" else { throw UnitConversionError.invalidSyntax }
        let value = try number(parts[0])
        let source = try unit(String(parts[1])), target = try unit(String(parts[3]))
        guard source.dimension == target.dimension else { throw UnitConversionError.incompatibleUnits }
        let converted: Double
        if source.dimension == .temperature {
            converted = try temperature(value, from: source.symbol, to: target.symbol)
        } else {
            // 先计算比例，避免同单位或同量级转换产生本可避免的中间溢出。
            converted = value * (source.scale / target.scale)
            guard converted != 0 || value == 0 else { throw UnitConversionError.resultOutOfRange }
        }
        guard converted.isFinite else { throw UnitConversionError.resultOutOfRange }
        return UnitConversionResult(sourceValue: value, sourceUnit: source.symbol,
            targetUnit: target.symbol, value: converted == 0 ? 0 : converted)
    }

    private enum Dimension: Sendable, Equatable { case length, mass, temperature, data }
    private struct Unit: Sendable {
        let symbol: String
        let dimension: Dimension
        let scale: Double
        init(_ symbol: String, _ dimension: Dimension, _ scale: Double) {
            self.symbol = symbol; self.dimension = dimension; self.scale = scale
        }
    }
    // 长度采用国际英尺/英里；t为公吨，lb/oz为常衡质量，不采用美制测量英尺。
    private static let units: [String: Unit] = [
        "mm": Unit("mm", .length, 0.001), "cm": Unit("cm", .length, 0.01),
        "m": Unit("m", .length, 1), "km": Unit("km", .length, 1_000),
        "in": Unit("in", .length, 0.0254), "ft": Unit("ft", .length, 0.3048),
        "yd": Unit("yd", .length, 0.9144), "mi": Unit("mi", .length, 1_609.344),
        "mg": Unit("mg", .mass, 0.000001), "g": Unit("g", .mass, 0.001),
        "kg": Unit("kg", .mass, 1), "t": Unit("t", .mass, 1_000),
        "oz": Unit("oz", .mass, 0.028349523125), "lb": Unit("lb", .mass, 0.45359237),
        "c": Unit("°C", .temperature, 1), "°c": Unit("°C", .temperature, 1),
        "f": Unit("°F", .temperature, 1), "°f": Unit("°F", .temperature, 1),
        "k": Unit("K", .temperature, 1),
        "B": Unit("B", .data, 1), "kB": Unit("kB", .data, 1_000), "KB": Unit("kB", .data, 1_000),
        "MB": Unit("MB", .data, 1_000_000), "GB": Unit("GB", .data, 1_000_000_000),
        "TB": Unit("TB", .data, 1_000_000_000_000), "KiB": Unit("KiB", .data, 1_024),
        "MiB": Unit("MiB", .data, 1_048_576), "GiB": Unit("GiB", .data, 1_073_741_824),
        "TiB": Unit("TiB", .data, 1_099_511_627_776)
    ]

    private static func unit(_ text: String) throws -> Unit {
        let lower = text.lowercased()
        // 仅温度符号忽略大小写，绝不把Mb或mb猜测为MB。
        let key = ["c", "°c", "f", "°f", "k"].contains(lower) ? lower : text
        guard let unit = units[key] else { throw UnitConversionError.unsupportedUnit(text) }
        return unit
    }

    private static func temperature(_ value: Double, from source: String, to target: String) throws -> Double {
        let minimum: Double = source == "K" ? 0 : (source == "°C" ? -273.15 : -459.67)
        guard value >= minimum else { throw UnitConversionError.belowAbsoluteZero }
        if source == target { return value }
        // 直接使用各对公式，避免绝对零度附近的往返抵消误差。
        if source == "°F" { return target == "K" ? (value + 459.67) / 1.8 : (value - 32) / 1.8 }
        if source == "K" { return target == "°F" ? value * 1.8 - 459.67 : value - 273.15 }
        return target == "K" ? value + 273.15 : value * 1.8 + 32
    }

    private static func number(_ text: Substring) throws -> Double {
        let bytes = Array(text.utf8)
        var index = 0, digits = 0, nonzero = false
        func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
        while index < bytes.count && isDigit(bytes[index]) {
            nonzero = nonzero || bytes[index] != 48; digits += 1; index += 1
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            while index < bytes.count && isDigit(bytes[index]) {
                nonzero = nonzero || bytes[index] != 48; digits += 1; index += 1
            }
        }
        guard digits > 0 else { throw UnitConversionError.invalidNumber }
        if index < bytes.count && (bytes[index] == 69 || bytes[index] == 101) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            let exponentStart = index
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw UnitConversionError.invalidNumber }
        }
        guard index == bytes.count else { throw UnitConversionError.invalidNumber }
        guard let value = Double(String(text)), value.isFinite, value != 0 || !nonzero else {
            throw UnitConversionError.numberOutOfRange
        }
        return value
    }
}
