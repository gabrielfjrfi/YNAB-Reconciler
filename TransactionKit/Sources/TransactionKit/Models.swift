import Foundation

public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...12).contains(month), (1...31).contains(day) else {
            throw DateError.invalidDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            throw DateError.invalidDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(isoDate: String) throws {
        let parts = isoDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw DateError.invalidDate
        }
        try self.init(year: year, month: month, day: day)
    }

    public init(upCreatedAt: String) throws {
        guard upCreatedAt.count >= 10 else {
            throw DateError.invalidTimestamp
        }
        try self.init(isoDate: String(upCreatedAt.prefix(10)))
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func days(to other: LocalDate) -> Int {
        other.dayOrdinal - dayOrdinal
    }

    /// A Gregorian day number used for fast date-window comparisons. The
    /// epoch is intentionally unspecified because only differences matter.
    var dayOrdinal: Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(isoDate: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public enum DateError: Error {
        case invalidDate
        case invalidTimestamp
    }
}

public struct UpResponse: Decodable, Sendable {
    public let data: [UpTransaction]
}

public struct UpTransaction: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let description: String
    public let rawText: String?
    public let transactionType: String?
    public let createdAt: String
    public let date: LocalDate
    public let money: Money
    public let categoryID: String?
    public let parentCategoryID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case attributes
        case relationships
    }

    private struct Attributes: Decodable {
        let status: String
        let description: String?
        let rawText: String?
        let transactionType: String?
        let createdAt: String
        let amount: Amount
    }

    private struct Amount: Decodable {
        let valueInBaseUnits: Int
    }

    private struct Relationships: Decodable {
        let category: Relationship?
        let parentCategory: Relationship?
    }

    private struct Relationship: Decodable {
        let data: ResourceIdentifier?
    }

    private struct ResourceIdentifier: Decodable {
        let id: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let attributes = try container.decode(Attributes.self, forKey: .attributes)
        let relationships = try container.decodeIfPresent(Relationships.self, forKey: .relationships)
        status = attributes.status
        description = attributes.description ?? ""
        rawText = attributes.rawText
        transactionType = attributes.transactionType
        createdAt = attributes.createdAt
        date = try LocalDate(upCreatedAt: attributes.createdAt)
        money = Money(upBaseUnits: attributes.amount.valueInBaseUnits)
        categoryID = relationships?.category?.data?.id
        parentCategoryID = relationships?.parentCategory?.data?.id
    }
}

public struct YNABResponse: Decodable, Sendable {
    public let data: DataContainer

    public struct DataContainer: Decodable, Sendable {
        public let transactions: [YNABTransaction]
    }

    public func normalizedTransactions() -> NormalizationResult<YNABTransaction> {
        var values: [YNABTransaction] = []
        var warnings: [ReconciliationWarning] = []
        for transaction in data.transactions where !transaction.deleted {
            values.append(transaction)
            warnings.append(contentsOf: transaction.moneyConversion.warnings)
        }
        return NormalizationResult(values: values, warnings: warnings)
    }
}

public struct YNABTransaction: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let date: LocalDate
    public let milliunits: Int
    public let payeeName: String
    public let categoryID: String?
    public let categoryName: String?
    public let cleared: String
    public let deleted: Bool
    public let transferAccountID: String?
    public let subtransactions: [Subtransaction]

    public var moneyConversion: ConversionResult {
        Money.fromYNAB(milliunits: milliunits, transactionID: id)
    }

    public var money: Money {
        moneyConversion.money
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, amount, cleared, deleted, subtransactions
        case payeeName = "payee_name"
        case categoryID = "category_id"
        case categoryName = "category_name"
        case transferAccountID = "transfer_account_id"
    }

    public struct Subtransaction: Decodable, Equatable, Sendable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        date = try container.decode(LocalDate.self, forKey: .date)
        milliunits = try container.decode(Int.self, forKey: .amount)
        payeeName = try container.decodeIfPresent(String.self, forKey: .payeeName) ?? ""
        categoryID = try container.decodeIfPresent(String.self, forKey: .categoryID)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        cleared = try container.decodeIfPresent(String.self, forKey: .cleared) ?? ""
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        transferAccountID = try container.decodeIfPresent(String.self, forKey: .transferAccountID)
        subtransactions = try container.decodeIfPresent([Subtransaction].self, forKey: .subtransactions) ?? []
    }
}

public struct NormalizationResult<Value>: Sendable where Value: Sendable {
    public let values: [Value]
    public let warnings: [ReconciliationWarning]

    public init(values: [Value], warnings: [ReconciliationWarning]) {
        self.values = values
        self.warnings = warnings
    }
}
