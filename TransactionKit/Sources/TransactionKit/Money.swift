import Foundation

public struct Money: Hashable, Comparable, Sendable, Codable {
    public let cents: Int

    public init(cents: Int) {
        self.cents = cents
    }

    public init(upBaseUnits: Int) {
        cents = upBaseUnits
    }

    public var upBaseUnits: Int {
        cents
    }

    public var ynabMilliunits: Int {
        cents * 10
    }

    public static func fromYNAB(milliunits: Int, transactionID: String) -> ConversionResult {
        let quotient = milliunits / 10
        let remainder = milliunits % 10
        guard remainder != 0 else {
            return ConversionResult(money: Money(cents: quotient), warnings: [])
        }

        let magnitude = abs(remainder)
        let adjustment = magnitude >= 5 ? (milliunits < 0 ? -1 : 1) : 0
        return ConversionResult(
            money: Money(cents: quotient + adjustment),
            warnings: [.subCentYNABAmount(transactionID: transactionID, milliunits: milliunits)]
        )
    }

    public var formatted: String {
        let negative = cents < 0
        let magnitude = cents.magnitude
        let dollars = magnitude / 100
        let fractional = magnitude % 100
        let grouped = Self.groupThousands(dollars)
        return "\(negative ? "-" : "")\(grouped).\(String(format: "%02llu", fractional))"
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.cents < rhs.cents
    }

    private static func groupThousands(_ value: UInt) -> String {
        let digits = String(value)
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.append(digits[start..<end])
            end = start
        }
        return groups.reversed().joined(separator: ",")
    }
}

public struct ConversionResult: Equatable, Sendable {
    public let money: Money
    public let warnings: [ReconciliationWarning]

    public init(money: Money, warnings: [ReconciliationWarning]) {
        self.money = money
        self.warnings = warnings
    }
}

public enum ReconciliationWarning: Equatable, Sendable {
    case subCentYNABAmount(transactionID: String, milliunits: Int)
    case noPartnersConfigured
}
