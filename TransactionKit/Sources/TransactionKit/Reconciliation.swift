import Foundation

public struct ReconciliationParameters: Equatable, Sendable {
    public var tolerance: Int
    public var reimbursementWindow: Int
    public var settleWindow: Int
    public var amendToleranceCents: Int
    public var amendDays: Int
    public var scoreFloor: Int
    public var shortlistSize: Int
    public var partners: [String]
    public var heldStatus: String
    public var splitDecisions: [String: SplitDecision]

    public init(
        tolerance: Int = 7,
        reimbursementWindow: Int = 14,
        settleWindow: Int = 30,
        amendToleranceCents: Int = 100,
        amendDays: Int = 3,
        scoreFloor: Int = 25,
        shortlistSize: Int = 5,
        partners: [String] = [],
        heldStatus: String = "cleared",
        splitDecisions: [String: SplitDecision] = [:]
    ) {
        self.tolerance = tolerance
        self.reimbursementWindow = reimbursementWindow
        self.settleWindow = settleWindow
        self.amendToleranceCents = amendToleranceCents
        self.amendDays = amendDays
        self.scoreFloor = scoreFloor
        self.shortlistSize = shortlistSize
        self.partners = partners
        self.heldStatus = heldStatus
        self.splitDecisions = splitDecisions
    }
}

public enum SplitDecision: Equatable, Sendable {
    case automatic
    case purchase(id: String)
    case notASplit
}

public struct Reconciliation: Equatable, Sendable {
    public let matched: [DirectMatch]
    public let reversals: [ZeroNetPair]
    public let splitsInYNAB: [ExistingSplit]
    public let repaid: [ZeroNetPair]
    public let shareBlocks: [ShareBlock]
    public let amends: [AmountCorrection]
    public let adds: [AddAction]
    public let queries: [QueryAction]
    public let totals: ReconciliationTotals
    public let inputCounts: InputCounts
    public let warnings: [ReconciliationWarning]

    public struct InputCounts: Equatable, Sendable {
        public let up: Int
        public let ynab: Int
    }
}

public struct DirectMatch: Equatable, Sendable {
    public let upID: String
    public let ynabID: String
    public let cents: Int
    public let dayGap: Int
}

public struct ZeroNetPair: Equatable, Sendable {
    public let purchaseID: String
    public let creditID: String
    public let cents: Int
}

public struct ExistingSplit: Equatable, Sendable {
    public let ynabID: String
    public let purchaseID: String
    public let depositID: String
    public let yourShareCents: Int
}

public struct ShareCandidate: Equatable, Sendable {
    public let purchaseID: String
    public let purchaseCents: Int
    public let score: Int
    public let band: Int?
    public var jointBest: Bool
    public let yourShareCents: Int
    public let reasons: [String]
}

public struct ShareBlock: Equatable, Sendable {
    public let depositID: String
    public let depositCents: Int
    public var chosenPurchaseID: String?
    public var yourShareCents: Int?
    public var tied: Bool
    public var candidates: [ShareCandidate]
}

public struct AmountCorrection: Equatable, Sendable {
    public let ynabID: String
    public let upID: String
    public let ynabCents: Int
    public let upCents: Int
    public let deltaCents: Int
}

public struct AddAction: Equatable, Sendable {
    public let upID: String
    public let cents: Int
    public let date: LocalDate
    public let status: String
    public let cleared: String
}

public struct QueryAction: Equatable, Sendable {
    public let ynabID: String
    public let cents: Int
    public let date: LocalDate
}

public struct ReconciliationTotals: Equatable, Sendable {
    public let upTotalCents: Int
    public let ynabTotalCents: Int
    public let gapCents: Int
    public let addTotalCents: Int
    public let shareTotalCents: Int
    public let unassignedRepaymentTotalCents: Int
    public let amendTotalCents: Int
    public let queryTotalCents: Int

    public var actionTotalCents: Int {
        addTotalCents + shareTotalCents + unassignedRepaymentTotalCents
            + amendTotalCents + queryTotalCents
    }

    public var identityHolds: Bool {
        actionTotalCents == gapCents
    }
}

public struct ReconciliationProgress: Equatable, Sendable {
    public enum Pass: String, Equatable, Sendable {
        case directMatches = "Matching identical amounts"
        case reversals = "Finding reversals and refunds"
        case existingSplits = "Finding existing YNAB splits"
        case sharedCosts = "Ranking shared costs"
        case repayments = "Finding repayments"
        case corrections = "Finding amount corrections"
    }

    public let pass: Pass
    public let passNumber: Int
    public let passCount: Int
    public let completedUnits: Int
    public let totalUnits: Int

    public init(
        pass: Pass,
        passNumber: Int,
        passCount: Int,
        completedUnits: Int,
        totalUnits: Int
    ) {
        self.pass = pass
        self.passNumber = passNumber
        self.passCount = passCount
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }

    public var percentComplete: Int {
        let completedPasses = max(0, passNumber - 1)
        let withinPass = totalUnits > 0
            ? min(100, max(0, completedUnits * 100 / totalUnits))
            : 100
        return min(100, (completedPasses * 100 + withinPass) / max(passCount, 1))
    }
}

public struct Reconciler: Sendable {
    public init() {}

    public func reconcile(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        parameters: ReconciliationParameters
    ) -> Reconciliation {
        try! reconcile(
            up: up,
            ynab: ynab,
            parameters: parameters,
            checkCancellation: {}
        )
    }

    public func reconcileCancellable(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        parameters: ReconciliationParameters,
        progress: @escaping @Sendable (ReconciliationProgress) -> Void = { _ in }
    ) throws -> Reconciliation {
        try reconcile(
            up: up,
            ynab: ynab,
            parameters: parameters,
            checkCancellation: { try Task.checkCancellation() },
            progress: progress
        )
    }

    private func reconcile(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        parameters: ReconciliationParameters,
        checkCancellation: () throws -> Void,
        progress: @escaping @Sendable (ReconciliationProgress) -> Void = { _ in }
    ) throws -> Reconciliation {
        let filteredYNAB = ynab.filter { !$0.deleted }
        var warnings: [ReconciliationWarning] = []
        for transaction in filteredYNAB {
            warnings.append(contentsOf: transaction.moneyConversion.warnings)
        }
        if parameters.partners.isEmpty {
            warnings.append(.noPartnersConfigured)
        }

        let direct = try matchDirect(
            up: up,
            ynab: filteredYNAB,
            tolerance: parameters.tolerance,
            checkCancellation: checkCancellation,
            progress: passProgress(.directMatches, number: 1, reporter: progress)
        )
        let reversals = try matchZeroNet(
            up: direct.remainingUp,
            window: parameters.reimbursementWindow,
            requireSameMerchant: true,
            checkCancellation: checkCancellation,
            progress: passProgress(.reversals, number: 2, reporter: progress)
        )
        let existing = try matchExistingSplits(
            up: reversals.remaining,
            ynab: direct.remainingYNAB,
            tolerance: parameters.tolerance,
            reimbursementWindow: parameters.reimbursementWindow,
            checkCancellation: checkCancellation,
            progress: passProgress(.existingSplits, number: 3, reporter: progress)
        )
        let shortlisted = try buildShareBlocks(
            up: existing.remainingUp,
            parameters: parameters,
            checkCancellation: checkCancellation,
            progress: passProgress(.sharedCosts, number: 4, reporter: progress)
        )
        let availableForRepayment = existing.remainingUp.filter { !shortlisted.claimedIDs.contains($0.id) }
        let repaid = try matchZeroNet(
            up: availableForRepayment,
            window: parameters.reimbursementWindow,
            requireSameMerchant: false,
            checkCancellation: checkCancellation,
            progress: passProgress(.repayments, number: 5, reporter: progress)
        )
        let amended = try matchCorrections(
            up: repaid.remaining,
            ynab: existing.remainingYNAB,
            days: parameters.amendDays,
            centsTolerance: parameters.amendToleranceCents,
            checkCancellation: checkCancellation,
            progress: passProgress(.corrections, number: 6, reporter: progress)
        )

        let blockDepositIDs = Set(shortlisted.blocks.map(\.depositID))
        let adds = amended.remainingUp
            .filter { !blockDepositIDs.contains($0.id) }
            .map {
                AddAction(
                    upID: $0.id,
                    cents: $0.money.cents,
                    date: $0.date,
                    status: $0.status,
                    cleared: $0.status == "HELD" ? parameters.heldStatus : "cleared"
                )
            }
            .sorted { $0.upID < $1.upID }
        let queries = amended.remainingYNAB
            .map { QueryAction(ynabID: $0.id, cents: $0.money.cents, date: $0.date) }
            .sorted { $0.ynabID < $1.ynabID }

        let upTotal = up.reduce(0) { $0 + $1.money.cents }
        let ynabTotal = filteredYNAB.reduce(0) { $0 + $1.money.cents }
        let shareTotal = shortlisted.blocks.reduce(0) { total, block in
            total + (block.yourShareCents ?? 0)
        }
        let unassignedTotal = shortlisted.blocks.reduce(0) { total, block in
            total + (block.chosenPurchaseID == nil ? block.depositCents : 0)
        }
        let totals = ReconciliationTotals(
            upTotalCents: upTotal,
            ynabTotalCents: ynabTotal,
            gapCents: upTotal - ynabTotal,
            addTotalCents: adds.reduce(0) { $0 + $1.cents },
            shareTotalCents: shareTotal,
            unassignedRepaymentTotalCents: unassignedTotal,
            amendTotalCents: amended.matches.reduce(0) { $0 + $1.deltaCents },
            queryTotalCents: queries.reduce(0) { $0 - $1.cents }
        )

        return Reconciliation(
            matched: direct.matches.sorted { $0.upID < $1.upID },
            reversals: reversals.matches.sorted { $0.purchaseID < $1.purchaseID },
            splitsInYNAB: existing.matches.sorted { $0.ynabID < $1.ynabID },
            repaid: repaid.matches.sorted { $0.purchaseID < $1.purchaseID },
            shareBlocks: shortlisted.blocks.sorted { $0.depositID < $1.depositID },
            amends: amended.matches.sorted { $0.upID < $1.upID },
            adds: adds,
            queries: queries,
            totals: totals,
            inputCounts: .init(up: up.count, ynab: filteredYNAB.count),
            warnings: warnings
        )
    }

    private func passProgress(
        _ pass: ReconciliationProgress.Pass,
        number: Int,
        reporter: @escaping @Sendable (ReconciliationProgress) -> Void
    ) -> @Sendable (Int, Int) -> Void {
        { completed, total in
            reporter(ReconciliationProgress(
                pass: pass,
                passNumber: number,
                passCount: 6,
                completedUnits: completed,
                totalUnits: total
            ))
        }
    }
}

private extension Reconciler {
    struct DirectResult {
        let matches: [DirectMatch]
        let remainingUp: [UpTransaction]
        let remainingYNAB: [YNABTransaction]
    }

    struct DirectCandidate {
        let gap: Int
        let up: UpTransaction
        let ynab: YNABTransaction
    }

    func matchDirect(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        tolerance: Int,
        checkCancellation: () throws -> Void,
        progress: (Int, Int) -> Void
    ) throws -> DirectResult {
        let ynabByAmount = Dictionary(grouping: ynab, by: { $0.money.cents })
        var candidates: [DirectCandidate] = []
        progress(0, up.count)
        for (bankIndex, bank) in up.enumerated() {
            try checkCancellation()
            for (budgetIndex, budget) in (ynabByAmount[bank.money.cents] ?? []).enumerated() {
                if budgetIndex.isMultiple(of: 256) { try checkCancellation() }
                let gap = abs(bank.date.days(to: budget.date))
                if gap <= tolerance {
                    candidates.append(.init(gap: gap, up: bank, ynab: budget))
                }
            }
            reportProgress(bankIndex + 1, total: up.count, progress: progress)
        }
        candidates.sort {
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            if $0.up.date != $1.up.date { return $0.up.date < $1.up.date }
            return $0.up.id < $1.up.id
        }

        var usedUp: Set<String> = []
        var usedYNAB: Set<String> = []
        var matches: [DirectMatch] = []
        for candidate in candidates {
            guard !usedUp.contains(candidate.up.id), !usedYNAB.contains(candidate.ynab.id) else { continue }
            usedUp.insert(candidate.up.id)
            usedYNAB.insert(candidate.ynab.id)
            matches.append(.init(
                upID: candidate.up.id,
                ynabID: candidate.ynab.id,
                cents: candidate.up.money.cents,
                dayGap: candidate.gap
            ))
        }
        return DirectResult(
            matches: matches,
            remainingUp: up.filter { !usedUp.contains($0.id) },
            remainingYNAB: ynab.filter { !usedYNAB.contains($0.id) }
        )
    }

    struct ZeroNetResult {
        let matches: [ZeroNetPair]
        let remaining: [UpTransaction]
    }

    struct ZeroNetCandidate {
        let gap: Int
        let purchase: UpTransaction
        let credit: UpTransaction
    }

    func matchZeroNet(
        up: [UpTransaction],
        window: Int,
        requireSameMerchant: Bool,
        checkCancellation: () throws -> Void,
        progress: (Int, Int) -> Void
    ) throws -> ZeroNetResult {
        let purchases = up.filter { $0.money.cents < 0 }
        let credits = up.filter { $0.money.cents > 0 }
        let creditsByAmount = Dictionary(grouping: credits, by: { $0.money.cents })
        var candidates: [ZeroNetCandidate] = []
        progress(0, purchases.count)
        for (purchaseIndex, purchase) in purchases.enumerated() {
            try checkCancellation()
            for (creditIndex, credit) in (creditsByAmount[-purchase.money.cents] ?? []).enumerated() {
                if creditIndex.isMultiple(of: 256) { try checkCancellation() }
                let gap = abs(purchase.date.days(to: credit.date))
                guard gap <= window else { continue }
                if requireSameMerchant,
                   purchase.description.caseInsensitiveCompare(credit.description) != .orderedSame {
                    continue
                }
                if purchase.categoryID != nil, credit.categoryID != nil,
                   !sameCategory(purchase, credit) {
                    continue
                }
                candidates.append(.init(gap: gap, purchase: purchase, credit: credit))
            }
            reportProgress(purchaseIndex + 1, total: purchases.count, progress: progress)
        }
        candidates.sort {
            if $0.gap != $1.gap { return $0.gap < $1.gap }
            if $0.purchase.id != $1.purchase.id { return $0.purchase.id < $1.purchase.id }
            return $0.credit.id < $1.credit.id
        }
        var used: Set<String> = []
        var matches: [ZeroNetPair] = []
        for candidate in candidates {
            guard !used.contains(candidate.purchase.id), !used.contains(candidate.credit.id) else { continue }
            used.insert(candidate.purchase.id)
            used.insert(candidate.credit.id)
            matches.append(.init(
                purchaseID: candidate.purchase.id,
                creditID: candidate.credit.id,
                cents: candidate.purchase.money.cents
            ))
        }
        return .init(matches: matches, remaining: up.filter { !used.contains($0.id) })
    }

    struct ExistingResult {
        let matches: [ExistingSplit]
        let remainingUp: [UpTransaction]
        let remainingYNAB: [YNABTransaction]
    }

    struct ExistingCandidate {
        let dateGap: Int
        let doubledEvenness: Int
        let ynab: YNABTransaction
        let purchase: UpTransaction
        let deposit: UpTransaction
    }

    func matchExistingSplits(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        tolerance: Int,
        reimbursementWindow: Int,
        checkCancellation: () throws -> Void,
        progress: (Int, Int) -> Void
    ) throws -> ExistingResult {
        let purchases = up.filter { $0.money.cents < 0 }
        let deposits = up.filter { $0.money.cents > 0 }
        let purchasesByDay = Dictionary(grouping: purchases, by: { $0.date.dayOrdinal })
        let depositsByAmountAndDay = Dictionary(grouping: deposits, by: { $0.money.cents }).mapValues {
            Dictionary(grouping: $0, by: { $0.date.dayOrdinal })
        }
        var candidates: [ExistingCandidate] = []
        let negativeYNAB = ynab.filter { $0.money.cents < 0 }
        progress(0, negativeYNAB.count)
        for (budgetIndex, budget) in negativeYNAB.enumerated() {
            try checkCancellation()
            let budgetDay = budget.date.dayOrdinal
            for purchaseDay in (budgetDay - tolerance)...(budgetDay + tolerance) {
                for purchase in purchasesByDay[purchaseDay] ?? [] where purchase.money.cents < budget.money.cents {
                    try checkCancellation()
                    let dateGap = abs(purchaseDay - budgetDay)
                    let requiredDeposit = budget.money.cents - purchase.money.cents
                    guard let depositsByDay = depositsByAmountAndDay[requiredDeposit] else { continue }
                    for depositDay in (purchaseDay - reimbursementWindow)...(purchaseDay + reimbursementWindow) {
                        for deposit in depositsByDay[depositDay] ?? [] {
                            let evenness = abs(2 * deposit.money.cents - abs(purchase.money.cents))
                            candidates.append(.init(
                                dateGap: dateGap,
                                doubledEvenness: evenness,
                                ynab: budget,
                                purchase: purchase,
                                deposit: deposit
                            ))
                        }
                    }
                }
            }
            reportProgress(budgetIndex + 1, total: negativeYNAB.count, progress: progress)
        }
        candidates.sort {
            if $0.dateGap != $1.dateGap { return $0.dateGap < $1.dateGap }
            if $0.doubledEvenness != $1.doubledEvenness { return $0.doubledEvenness < $1.doubledEvenness }
            if $0.ynab.id != $1.ynab.id { return $0.ynab.id < $1.ynab.id }
            if $0.purchase.id != $1.purchase.id { return $0.purchase.id < $1.purchase.id }
            return $0.deposit.id < $1.deposit.id
        }
        var usedUp: Set<String> = []
        var usedYNAB: Set<String> = []
        var matches: [ExistingSplit] = []
        for candidate in candidates {
            guard !usedYNAB.contains(candidate.ynab.id),
                  !usedUp.contains(candidate.purchase.id),
                  !usedUp.contains(candidate.deposit.id) else { continue }
            usedYNAB.insert(candidate.ynab.id)
            usedUp.insert(candidate.purchase.id)
            usedUp.insert(candidate.deposit.id)
            matches.append(.init(
                ynabID: candidate.ynab.id,
                purchaseID: candidate.purchase.id,
                depositID: candidate.deposit.id,
                yourShareCents: candidate.ynab.money.cents
            ))
        }
        return .init(
            matches: matches,
            remainingUp: up.filter { !usedUp.contains($0.id) },
            remainingYNAB: ynab.filter { !usedYNAB.contains($0.id) }
        )
    }

    struct ShortlistResult {
        var blocks: [ShareBlock]
        let claimedIDs: Set<String>
    }

    struct RatedCandidate {
        let purchase: UpTransaction
        let score: Int
        let band: Int?
        let share: Int
        let reasons: [String]
    }

    struct WorkingBlock {
        let deposit: UpTransaction
        var candidates: [RatedCandidate]
        var contenderIndexes: [Int]
        var chosenIndex: Int?
        var tied: Bool
    }

    func buildShareBlocks(
        up: [UpTransaction],
        parameters: ReconciliationParameters,
        checkCancellation: () throws -> Void,
        progress: (Int, Int) -> Void
    ) throws -> ShortlistResult {
        let purchases = up.filter { $0.money.cents < 0 }
        let deposits = up.filter {
            $0.money.cents > 0
                && isPartner($0, partners: parameters.partners)
                && $0.transactionType != "Refund"
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.money.cents > $1.money.cents
        }
        var working: [WorkingBlock] = []
        progress(0, deposits.count)
        for (depositIndex, deposit) in deposits.enumerated() {
            defer {
                reportProgress(depositIndex + 1, total: deposits.count, progress: progress)
            }
            try checkCancellation()
            if parameters.splitDecisions[deposit.id] == .notASplit {
                continue
            }
            var candidates: [RatedCandidate] = []
            for (purchaseIndex, purchase) in purchases.enumerated() {
                if purchaseIndex.isMultiple(of: 256) { try checkCancellation() }
                let offset = purchase.date.days(to: deposit.date)
                guard offset >= -2, offset <= parameters.settleWindow else { continue }
                guard purchase.description.caseInsensitiveCompare(deposit.description) != .orderedSame else { continue }
                guard purchase.money.cents + deposit.money.cents < 0 else { continue }
                guard let score = SplitScorer.score(
                    purchase: purchase,
                    deposit: deposit,
                    settleWindow: parameters.settleWindow
                ), score.score >= parameters.scoreFloor else { continue }
                candidates.append(.init(
                    purchase: purchase,
                    score: score.score,
                    band: score.band,
                    share: score.yourShareCents,
                    reasons: score.reasons
                ))
            }
            candidates.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.purchase.date != $1.purchase.date { return $0.purchase.date < $1.purchase.date }
                return $0.purchase.id < $1.purchase.id
            }
            candidates = Array(candidates.prefix(parameters.shortlistSize))
            guard !candidates.isEmpty else { continue }
            let bestBand = candidates.compactMap(\.band).min()
            let contenders = bestBand.map { band in
                candidates.indices.filter { candidates[$0].band == band }
            } ?? []
            working.append(.init(
                deposit: deposit,
                candidates: candidates,
                contenderIndexes: contenders,
                chosenIndex: nil,
                tied: contenders.count > 1
            ))
        }

        var takenPurchases: Set<String> = []

        // Explicit user choices outrank automatic evidence claims. The UI only
        // offers candidates from the shortlist, so an unavailable id remains
        // unselected instead of inventing a pairing.
        let explicit = working.indices.compactMap { blockIndex -> (Int, Int)? in
            guard case .purchase(let purchaseID) = parameters.splitDecisions[working[blockIndex].deposit.id],
                  let candidateIndex = working[blockIndex].candidates.firstIndex(where: { $0.purchase.id == purchaseID }) else {
                return nil
            }
            return (blockIndex, candidateIndex)
        }.sorted { working[$0.0].deposit.id < working[$1.0].deposit.id }
        for (blockIndex, candidateIndex) in explicit {
            let purchaseID = working[blockIndex].candidates[candidateIndex].purchase.id
            guard takenPurchases.insert(purchaseID).inserted else { continue }
            working[blockIndex].chosenIndex = candidateIndex
        }

        let eligible = working.indices.filter {
            parameters.splitDecisions[working[$0].deposit.id] == nil
                || parameters.splitDecisions[working[$0].deposit.id] == .automatic
        }.filter { working[$0].contenderIndexes.count == 1 }.sorted {
            let lhs = working[$0].candidates[working[$0].contenderIndexes[0]]
            let rhs = working[$1].candidates[working[$1].contenderIndexes[0]]
            if lhs.band != rhs.band { return lhs.band! < rhs.band! }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return working[$0].deposit.id < working[$1].deposit.id
        }
        for blockIndex in eligible {
            let candidateIndex = working[blockIndex].contenderIndexes[0]
            let purchaseID = working[blockIndex].candidates[candidateIndex].purchase.id
            guard !takenPurchases.contains(purchaseID) else { continue }
            working[blockIndex].chosenIndex = candidateIndex
            takenPurchases.insert(purchaseID)
        }

        var claimed = takenPurchases
        var blocks: [ShareBlock] = []
        for block in working {
            let chosen = block.chosenIndex.map { block.candidates[$0] }
            // Every listed repayment belongs to this pass, including tied or
            // otherwise unresolved blocks. Its purchase remains available
            // until selected, but pass 5 must not consume the repayment again.
            claimed.insert(block.deposit.id)
            let rendered = block.candidates.indices.map { index in
                let candidate = block.candidates[index]
                return ShareCandidate(
                    purchaseID: candidate.purchase.id,
                    purchaseCents: candidate.purchase.money.cents,
                    score: candidate.score,
                    band: candidate.band,
                    jointBest: block.tied && block.contenderIndexes.contains(index),
                    yourShareCents: candidate.share,
                    reasons: candidate.reasons
                )
            }
            blocks.append(.init(
                depositID: block.deposit.id,
                depositCents: block.deposit.money.cents,
                chosenPurchaseID: chosen?.purchase.id,
                yourShareCents: chosen.map { -$0.share },
                tied: block.tied,
                candidates: rendered
            ))
        }
        return .init(blocks: blocks, claimedIDs: claimed)
    }

    struct CorrectionResult {
        let matches: [AmountCorrection]
        let remainingUp: [UpTransaction]
        let remainingYNAB: [YNABTransaction]
    }

    struct CorrectionCandidate {
        let magnitude: Int
        let dateGap: Int
        let ynab: YNABTransaction
        let up: UpTransaction
    }

    func matchCorrections(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        days: Int,
        centsTolerance: Int,
        checkCancellation: () throws -> Void,
        progress: (Int, Int) -> Void
    ) throws -> CorrectionResult {
        let upByAmount = Dictionary(grouping: up, by: { $0.money.cents })
        var candidates: [CorrectionCandidate] = []
        progress(0, ynab.count)
        for (budgetIndex, budget) in ynab.enumerated() {
            try checkCancellation()
            let lower = budget.money.cents - centsTolerance
            let upper = budget.money.cents + centsTolerance
            for amount in lower...upper where amount != budget.money.cents {
                if (amount - lower).isMultiple(of: 128) { try checkCancellation() }
                for bank in upByAmount[amount] ?? [] {
                    guard (budget.money.cents < 0) == (bank.money.cents < 0) else { continue }
                let difference = abs(bank.money.cents - budget.money.cents)
                let gap = abs(bank.date.days(to: budget.date))
                guard difference > 0, difference <= centsTolerance, gap <= days else { continue }
                candidates.append(.init(magnitude: difference, dateGap: gap, ynab: budget, up: bank))
                }
            }
            reportProgress(budgetIndex + 1, total: ynab.count, progress: progress)
        }
        candidates.sort {
            if $0.magnitude != $1.magnitude { return $0.magnitude < $1.magnitude }
            if $0.dateGap != $1.dateGap { return $0.dateGap < $1.dateGap }
            if $0.ynab.id != $1.ynab.id { return $0.ynab.id < $1.ynab.id }
            return $0.up.id < $1.up.id
        }
        var usedUp: Set<String> = []
        var usedYNAB: Set<String> = []
        var matches: [AmountCorrection] = []
        for candidate in candidates {
            guard !usedUp.contains(candidate.up.id), !usedYNAB.contains(candidate.ynab.id) else { continue }
            usedUp.insert(candidate.up.id)
            usedYNAB.insert(candidate.ynab.id)
            matches.append(.init(
                ynabID: candidate.ynab.id,
                upID: candidate.up.id,
                ynabCents: candidate.ynab.money.cents,
                upCents: candidate.up.money.cents,
                deltaCents: candidate.up.money.cents - candidate.ynab.money.cents
            ))
        }
        return .init(
            matches: matches,
            remainingUp: up.filter { !usedUp.contains($0.id) },
            remainingYNAB: ynab.filter { !usedYNAB.contains($0.id) }
        )
    }

    func sameCategory(_ lhs: UpTransaction, _ rhs: UpTransaction) -> Bool {
        lhs.categoryID != nil
            && lhs.categoryID == rhs.categoryID
            && lhs.parentCategoryID == rhs.parentCategoryID
    }

    func isPartner(_ transaction: UpTransaction, partners: [String]) -> Bool {
        guard !partners.isEmpty else { return true }
        return partners
            .filter { !$0.isEmpty }
            .contains { transaction.description.localizedCaseInsensitiveContains($0) }
    }

    func reportProgress(_ completed: Int, total: Int, progress: (Int, Int) -> Void) {
        let reportingInterval = max(1, total / 100)
        if completed == total || completed == 1 || completed.isMultiple(of: reportingInterval) {
            progress(completed, total)
        }
    }
}

public enum SplitScorer {
    public struct Score: Equatable, Sendable {
        public let score: Int
        public let band: Int?
        public let yourShareCents: Int
        public let reasons: [String]
    }

    public static func score(
        purchase: UpTransaction,
        deposit: UpTransaction,
        settleWindow: Int
    ) -> Score? {
        let total = abs(purchase.money.cents)
        let theirs = deposit.money.cents
        let yours = total - theirs
        guard yours > 0 else { return nil }
        let sameCategory = purchase.categoryID != nil
            && purchase.categoryID == deposit.categoryID
            && purchase.parentCategoryID == deposit.parentCategoryID
        let sameCategoryID = purchase.categoryID != nil && purchase.categoryID == deposit.categoryID
        let offset = purchase.date.days(to: deposit.date)
        let nonnegativeOffset = max(offset, 0)

        if abs(total - 2 * theirs) <= 1 {
            var reasons = ["exactly half"]
            var points = 90 + proximityPoints(maximum: 4, offset: nonnegativeOffset, window: settleWindow)
            if sameCategory {
                points += 6
                reasons.append("same category")
            }
            return Score(
                score: min(points, 100),
                band: sameCategory ? 0 : 1,
                yourShareCents: yours,
                reasons: reasons
            )
        }

        var points = 0
        var reasons: [String] = []
        if sameCategory {
            points += 40
            reasons.append("same category")
        } else if sameCategoryID {
            points += 26
            reasons.append("same category, different parent")
        }

        var exactFraction = false
        if abs(total - 3 * theirs) <= 1 {
            points += 22
            reasons.append("exactly a third")
            exactFraction = true
        } else if abs(total - 4 * theirs) <= 1 {
            points += 12
            reasons.append("exactly a quarter")
            exactFraction = true
        } else if abs(2 * total - 3 * theirs) <= 1 {
            points += 12
            reasons.append("exactly two thirds")
            exactFraction = true
        }

        let roundShare = yours % 100 == 0
        if roundShare {
            points += 10
            reasons.append("leaves a round \(Money(cents: yours).formatted)")
        }
        if theirs % 100 == 0 {
            points += 5
            reasons.append("round repayment")
        }
        points += proximityPoints(maximum: 8, offset: nonnegativeOffset, window: settleWindow)
        if theirs * 10 > total * 8 || theirs * 10 < total {
            points -= 12
            reasons.append("lopsided share")
        }

        let band: Int?
        if sameCategory && exactFraction {
            band = 2
        } else if sameCategory && roundShare {
            band = 3
        } else {
            band = nil
        }
        return Score(
            score: min(85, max(0, points)),
            band: band,
            yourShareCents: yours,
            reasons: reasons
        )
    }

    private static func proximityPoints(maximum: Int, offset: Int, window: Int) -> Int {
        guard window > 0 else { return 0 }
        let remaining = max(0, window - offset)
        return roundedQuotient(maximum * remaining, by: window)
    }

    private static func roundedQuotient(_ numerator: Int, by denominator: Int) -> Int {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let doubled = remainder * 2
        if doubled < denominator { return quotient }
        if doubled > denominator { return quotient + 1 }
        return quotient.isMultiple(of: 2) ? quotient : quotient + 1
    }
}
