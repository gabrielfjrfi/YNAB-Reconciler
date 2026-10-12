import Foundation

public struct SendSelection: Equatable, Sendable {
    public let rowID: String
    public let categoryID: String?
    public let payee: String

    public init(rowID: String, categoryID: String?, payee: String) {
        self.rowID = rowID
        self.categoryID = categoryID
        self.payee = payee
    }
}

public struct YNABCreateTransaction: Codable, Equatable, Sendable {
    public let accountID: String
    public let date: LocalDate
    public let amount: Int
    public let payeeName: String
    public let categoryID: String
    public let memo: String
    public let cleared: String
    public let approved: Bool

    public init(
        accountID: String,
        date: LocalDate,
        amount: Int,
        payeeName: String,
        categoryID: String,
        memo: String = "Pushed by YNAB Reconciler iOS",
        cleared: String,
        approved: Bool = true
    ) {
        self.accountID = accountID
        self.date = date
        self.amount = amount
        self.payeeName = payeeName
        self.categoryID = categoryID
        self.memo = memo
        self.cleared = cleared
        self.approved = approved
    }

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case date
        case amount
        case payeeName = "payee_name"
        case categoryID = "category_id"
        case memo
        case cleared
        case approved
    }
}

public struct YNABCreateRequest: Codable, Equatable, Sendable {
    public let transactions: [YNABCreateTransaction]

    public init(transactions: [YNABCreateTransaction]) {
        self.transactions = transactions
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct PreparedSend: Equatable, Sendable {
    public let request: YNABCreateRequest
    public let sourceIDs: [[String]]
    public let rejections: [SendRejection]
    public let skippedLoggedRowIDs: [String]

    public init(
        request: YNABCreateRequest,
        sourceIDs: [[String]],
        rejections: [SendRejection],
        skippedLoggedRowIDs: [String]
    ) {
        self.request = request
        self.sourceIDs = sourceIDs
        self.rejections = rejections
        self.skippedLoggedRowIDs = skippedLoggedRowIDs
    }
}

public struct SendRejection: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case missingCategory
        case emptyPayee
        case unknownRow
        case unassignedShare
    }

    public let rowID: String
    public let reason: Reason

    public init(rowID: String, reason: Reason) {
        self.rowID = rowID
        self.reason = reason
    }
}

public struct YNABPayloadBuilder: Sendable {
    public init() {}

    public func build(
        reconciliation: Reconciliation,
        upTransactions: [UpTransaction],
        selections: [SendSelection],
        accountID: String,
        heldStatus: String,
        pushedIDs: Set<String>
    ) -> PreparedSend {
        let upByID = Dictionary(uniqueKeysWithValues: upTransactions.map { ($0.id, $0) })
        let addsByID = Dictionary(uniqueKeysWithValues: reconciliation.adds.map { ($0.upID, $0) })
        let sharesByID = Dictionary(uniqueKeysWithValues: reconciliation.shareBlocks.map { ($0.depositID, $0) })

        var transactions: [YNABCreateTransaction] = []
        var sourceIDs: [[String]] = []
        var rejections: [SendRejection] = []
        var skippedLoggedRowIDs: [String] = []

        for selection in selections {
            let categoryID = selection.categoryID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let categoryID, !categoryID.isEmpty else {
                rejections.append(.init(rowID: selection.rowID, reason: .missingCategory))
                continue
            }

            let trimmedPayee = selection.payee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPayee.isEmpty else {
                rejections.append(.init(rowID: selection.rowID, reason: .emptyPayee))
                continue
            }
            let payee = String(trimmedPayee.prefix(200))

            if let add = addsByID[selection.rowID],
               let transaction = upByID[add.upID] {
                guard !pushedIDs.contains(add.upID) else {
                    skippedLoggedRowIDs.append(selection.rowID)
                    continue
                }
                transactions.append(
                    YNABCreateTransaction(
                        accountID: accountID,
                        date: add.date,
                        amount: add.cents * 10,
                        payeeName: payee,
                        categoryID: categoryID,
                        cleared: add.cleared
                    )
                )
                sourceIDs.append([transaction.id])
                continue
            }

            if let block = sharesByID[selection.rowID] {
                guard let purchaseID = block.chosenPurchaseID,
                      let purchase = upByID[purchaseID],
                      let repayment = upByID[block.depositID] else {
                    rejections.append(.init(rowID: selection.rowID, reason: .unassignedShare))
                    continue
                }
                let ids = [purchase.id, repayment.id]
                guard ids.allSatisfy({ !pushedIDs.contains($0) }) else {
                    skippedLoggedRowIDs.append(selection.rowID)
                    continue
                }
                let shareCents = purchase.money.cents + repayment.money.cents
                transactions.append(
                    YNABCreateTransaction(
                        accountID: accountID,
                        date: purchase.date,
                        amount: shareCents * 10,
                        payeeName: payee,
                        categoryID: categoryID,
                        cleared: purchase.status == "HELD" ? heldStatus : "cleared"
                    )
                )
                sourceIDs.append(ids)
                continue
            }

            rejections.append(.init(rowID: selection.rowID, reason: .unknownRow))
        }

        return PreparedSend(
            request: YNABCreateRequest(transactions: transactions),
            sourceIDs: sourceIDs,
            rejections: rejections,
            skippedLoggedRowIDs: skippedLoggedRowIDs
        )
    }
}
