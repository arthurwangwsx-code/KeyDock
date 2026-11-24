import Foundation
import Testing
@testable import CommandCore

@Suite struct UnitConversionTests {
    private func expectValue(_ query: String, _ expected: Double, tolerance: Double = 1e-10) throws {
        let actual = try UnitConversion.convert(query).value
        #expect(abs(actual - expected) <= tolerance * max(1, abs(expected)))
    }

    @Test func metricLengthsAndSignedValues() throws {
        try expectValue("1 km to m", 1_000)
        try expectValue("125 cm to m", 1.25)
        try expectValue("-12 in to cm", -30.48)
        try expectValue("1e3 mm to m", 1)
    }
    @Test func internationalLengthsUseExactDefinitions() throws {
        try expectValue("1 mi to km", 1.609344)
        try expectValue("10 km to mi", 6.2137119223733395)
        try expectValue("12 in to ft", 1)
        try expectValue("1 yd to m", 0.9144)
    }
    @Test func avoirdupoisMassAndMetricTonne() throws {
        try expectValue("1 lb to g", 453.59237)
        try expectValue("16 oz to lb", 1)
        try expectValue("1 t to kg", 1_000)
        try expectValue("1 kg to mg", 1_000_000)
    }
    @Test func fahrenheitUsesAnOffsetInsteadOfAScaleOnly() throws {
        try expectValue("32 f to c", 0)
        try expectValue("212 F to °C", 100)
        try expectValue("-40 °F to C", -40)
        try expectValue("0 c to f", 32)
    }
    @Test func kelvinAndAbsoluteZeroBoundaries() throws {
        try expectValue("273.15 K to c", 0)
        try expectValue("0 k to C", -273.15)
        try expectValue("-273.15 c to K", 0)
        try expectValue("-459.67 f to K", 0)
        for query in ["-0.0001 K to c", "-273.1501 c to k", "-459.6701 f to c", "-1 K to K"] {
            #expect(throws: UnitConversionError.belowAbsoluteZero) { try UnitConversion.convert(query) }
        }
    }
    @Test func decimalBytesDoNotUseBinaryPrefixes() throws {
        try expectValue("1 MB to B", 1_000_000)
        try expectValue("1 GB to MB", 1_000)
        try expectValue("1 TB to GB", 1_000)
        try expectValue("1 KB to KiB", 0.9765625)
        #expect(try UnitConversion.convert("1 KB to B").sourceUnit == "kB")
    }
    @Test func binaryBytesAndDecimalBinaryDifferences() throws {
        try expectValue("1 GiB to MiB", 1_024)
        try expectValue("1 TiB to GiB", 1_024)
        try expectValue("1 MiB to MB", 1.048576)
        try expectValue("1 MB to MiB", 0.95367431640625)
    }
    @Test func numericGrammarAcceptsOnlyOneLiteral() throws {
        try expectValue("\t .5\t m to cm \t", 50)
        try expectValue("+1.5 kg to g", 1_500)
        for query in ["1+2 m to km", "(3) m to km", "NaN m to km", "Infinity m to km", "1e+ m to km", "0x10 m to km", "1,5 m to km"] {
            #expect(throws: UnitConversionError.invalidNumber) { try UnitConversion.convert(query) }
        }
    }
    @Test func syntaxRejectsExtraTokensAndScriptsWithoutEvaluation() {
        for query in ["10km to mi", "1 m in cm", "1 m TO cm", "1 m to cm extra", "1\nm to cm", "$(touch /tmp/never) m to cm", "1 m to cm; echo no"] {
            #expect(throws: UnitConversionError.invalidSyntax) { try UnitConversion.convert(query) }
        }
        #expect(throws: UnitConversionError.invalidNumber) { try UnitConversion.convert("$(whoami) m to cm") }
    }
    @Test func unknownAmbiguousAndIncompatibleUnitsAreExplicitErrors() {
        for unit in ["Mb", "mb", "mib", "ton", "meters", "℃"] {
            #expect(throws: UnitConversionError.unsupportedUnit(unit)) { try UnitConversion.convert("1 \(unit) to B") }
        }
        #expect(throws: UnitConversionError.unsupportedUnit("ms")) { try UnitConversion.convert("1 m to ms") }
        for query in ["1 m to kg", "1 g to B", "1 K to mi"] {
            #expect(throws: UnitConversionError.incompatibleUnits) { try UnitConversion.convert(query) }
        }
    }
    @Test func byteBudgetIsEnforcedBeforeTokenization() throws {
        #expect(throws: UnitConversionError.emptyInput) { try UnitConversion.convert(" \t ") }
        let query = "1 m to cm"
        let padded = String(repeating: " ", count: UnitConversion.maximumInputBytes - query.utf8.count) + query
        try expectValue(padded, 100)
        #expect(throws: UnitConversionError.inputTooLong) { try UnitConversion.convert(padded + " ") }
        #expect(throws: UnitConversionError.inputTooLong) { try UnitConversion.convert(String(repeating: "你", count: 86)) }
    }
    @Test func rangeChecksRejectInfinityAndSilentUnderflowButAvoidIntermediateOverflow() throws {
        for query in ["1e309 m to m", "1e-999 m to m"] {
            #expect(throws: UnitConversionError.numberOutOfRange) { try UnitConversion.convert(query) }
        }
        for query in ["1e308 km to mm", "5e-324 mm to km", "1e308 c to f"] {
            #expect(throws: UnitConversionError.resultOutOfRange) { try UnitConversion.convert(query) }
        }
        #expect(try UnitConversion.convert("1e308 km to km").value == 1e308)
        let largeTemperature = try UnitConversion.convert("1e308 f to c").value
        #expect(largeTemperature.isFinite && largeTemperature > 5e307)
        let zero = try UnitConversion.convert("-0 kg to g").value
        #expect(zero == 0 && zero.sign == .plus)
    }
}
