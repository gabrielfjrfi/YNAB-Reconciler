import Foundation
import Networking
import TransactionKit

/// Runs the real reconciliation engine and prints what it decided for every
/// transaction, so a wrong classification can be spotted and reported.
///
/// Live mode (needs tokens in the environment — see scripts/report.sh):
///     reconcile-report [--since YYYY-MM-DD] [--out DIR]
///
/// Offline mode (re-runs on data saved by an earlier live run; no network):
///     reconcile-report --up-json DIR/up.json --ynab-json DIR/ynab.json [--out DIR]
@main
struct ReconcileReport {
    static func main() async {
        do {
            try await run()
        } catch {
            fail("Failed: \(error)")
        }
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let outRoot = URL(fileURLWithPath: argument("--out") ?? "reports", isDirectory: true)
        let stamp = timestamp()
        let outDir = outRoot.appending(path: stamp, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let partners = (env["SPLIT_PARTNERS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let up: [UpTransaction]
        let ynab: [YNABTransaction]
        let source: String
        var since: LocalDate?

        if let upPath = argument("--up-json"), let ynabPath = argument("--ynab-json") {
            let upData = try Data(contentsOf: URL(fileURLWithPath: upPath))
            let ynabData = try Data(contentsOf: URL(fileURLWithPath: ynabPath))
            var seen: Set<String> = []
            up = try JSONDecoder().decode(UpResponse.self, from: upData).data
                .filter { seen.insert($0.id).inserted }
            ynab = try JSONDecoder().decode(YNABResponse.self, from: ynabData)
                .normalizedTransactions().values
            source = "saved files \(upPath) and \(ynabPath)"
        } else {
            let start = try startDate(env: env)
            since = start
            let upToken = required("UP_TOKEN", env)
            let ynabToken = required("YNAB_TOKEN", env)
            let planID = required("YNAB_PLAN_ID", env)
            let accountID = required("YNAB_ACCOUNT_ID", env)
            let upAccountID = env["UP_ACCOUNT_ID"].flatMap { $0.isEmpty ? nil : $0 }

            let cache = InMemoryResponseCache()
            let http = RetryingHTTPClient()
            let upClient = UpClient(token: upToken, httpClient: http, cache: cache)
            let ynabClient = YNABClient(token: ynabToken, httpClient: http, cache: cache)
            log("Fetching Up and YNAB since \(start)…")
            async let fetchedUp = upClient.fetchTransactions(
                since: start,
                timeZone: .current,
                accountID: upAccountID,
                progress: nil
            )
            async let fetchedYNAB = ynabClient.fetchTransactions(
                planID: planID,
                accountID: accountID,
                since: start
            )
            do { up = try await fetchedUp } catch { failFetch("Up", token: upToken, error) }
            do { ynab = try await fetchedYNAB } catch { failFetch("YNAB", token: ynabToken, error) }

            // Keep the raw responses so later runs can replay the exact same
            // data offline after the engine changes.
            if let raw = try await cache.load(for: .upTransactions(accountID: upAccountID)) {
                try mergeUpPages(raw).write(to: outDir.appending(path: "up.json"))
            }
            if let raw = try await cache.load(for: .ynabTransactions(planID: planID, accountID: accountID)) {
                try raw.write(to: outDir.appending(path: "ynab.json"))
            }
            source = "live Up and YNAB data"
        }

        let parameters = ReconciliationParameters(
            tolerance: intValue("TOLERANCE", env, 7),
            reimbursementWindow: intValue("REIMBURSEMENT_WINDOW", env, 14),
            settleWindow: intValue("SETTLE_WINDOW", env, 30),
            amendToleranceCents: intValue("AMEND_TOLERANCE_CENTS", env, 100),
            amendDays: intValue("AMEND_DAYS", env, 3),
            scoreFloor: intValue("SCORE_FLOOR", env, 25),
            shortlistSize: intValue("SHORTLIST_SIZE", env, 5),
            partners: partners,
            heldStatus: env["HELD_STATUS"] ?? "cleared"
        )
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: parameters)
        let report = Report(up: up, ynab: ynab, result: result)
            .render(source: source, since: since, partners: partners)

        let reportURL = outDir.appending(path: "report.txt")
        try Data(report.utf8).write(to: reportURL)
        print(report)
        log("Report saved to \(reportURL.path)")
    }

    // MARK: Helpers

    /// Turns a bare network error into one that names the service at fault,
    /// with a token hint that never reveals the token itself.
    static func failFetch(_ service: String, token: String, _ error: Error) -> Never {
        switch error {
        case NetworkError.invalidToken:
            // Up tokens share a fixed "up:yeah:" prefix, so showing it is safe;
            // nothing of a YNAB token is shown beyond its length.
            let shape = service == "Up"
                ? "is \(token.count) characters long and starts with \"\(token.prefix(7))…\" (Up tokens start with \"up:yeah:\")"
                : "is \(token.count) characters long (YNAB tokens are 43)"
            fail("""
            \(service) rejected the token (HTTP 401/403).
              The token read from your keychain \(shape).
              If you revoked it, store the new one with:
                security add-generic-password -U -s ynab-reconciler -a \(service.lowercased())-token -w
            """)
        case NetworkError.wrongPlanOrAccount:
            fail("\(service) could not find the plan or account. Check YNAB_PLAN_ID and YNAB_ACCOUNT_ID in .env.")
        default:
            fail("\(service) request failed: \(error)")
        }
    }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func required(_ key: String, _ env: [String: String]) -> String {
        guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            fail("\(key) is not set. Run through scripts/report.sh, which reads it for you.")
        }
        return value
    }

    static func intValue(_ key: String, _ env: [String: String], _ fallback: Int) -> Int {
        env[key].flatMap { Int($0) } ?? fallback
    }

    static func startDate(env: [String: String]) throws -> LocalDate {
        if let text = argument("--since") ?? env["SINCE"], !text.isEmpty {
            return try LocalDate(isoDate: text)
        }
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return try LocalDate(year: parts.year!, month: parts.month!, day: 1)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    /// The Up client caches every page it fetched; flatten them into one
    /// `{"data": [...]}` document in the same shape as the fixtures.
    static func mergeUpPages(_ raw: Data) throws -> Data {
        struct CachedPages: Decodable { let pages: [Data] }
        let pages = try JSONDecoder().decode(CachedPages.self, from: raw).pages
        var all: [Any] = []
        for page in pages {
            if let object = try JSONSerialization.jsonObject(with: page) as? [String: Any],
               let data = object["data"] as? [Any] {
                all.append(contentsOf: data)
            }
        }
        return try JSONSerialization.data(
            withJSONObject: ["data": all],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }
}

struct Report {
    let upByID: [String: UpTransaction]
    let ynabByID: [String: YNABTransaction]
    let result: Reconciliation

    init(up: [UpTransaction], ynab: [YNABTransaction], result: Reconciliation) {
        upByID = Dictionary(up.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ynabByID = Dictionary(ynab.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.result = result
    }

    func render(source: String, since: LocalDate?, partners: [String]) -> String {
        var out: [String] = []
        let totals = result.totals
        out.append("YNAB RECONCILER — ENGINE REPORT")
        out.append("Source: \(source)")
        if let since { out.append("Since: \(since)") }
        out.append("Partners: \(partners.isEmpty ? "(none — every inflow counts as a repayment)" : partners.joined(separator: ", "))")
        out.append("Transactions: \(result.inputCounts.up) Up, \(result.inputCounts.ynab) YNAB")
        out.append("Up total \(money(totals.upTotalCents)) · YNAB total \(money(totals.ynabTotalCents)) · gap \(money(totals.gapCents))")
        out.append("Balance identity: \(totals.identityHolds ? "holds" : "BROKEN — actions sum to \(money(totals.actionTotalCents))")")
        for warning in result.warnings {
            out.append("Warning: \(describe(warning))")
        }
        out.append("")
        out.append("Lines read: date · amount · Up description or YNAB payee · [PENDING] · Up type or YNAB category · short id")
        out.append("Refer to a line by its short id when saying what is wrong.")

        section(&out, "ENTER IN YNAB", result.adds.count, "In Up, nothing in YNAB behind it.")
        for add in result.adds {
            out.append("  " + upLine(add.upID))
        }

        section(&out, "ENTER YOUR HALF", result.shareBlocks.count, "A partner repayment and the bill it most likely belongs to.")
        for block in result.shareBlocks {
            out.append("  Repayment " + upLine(block.depositID))
            if let chosen = block.chosenPurchaseID, let share = block.yourShareCents {
                out.append("    → paired with \(short(chosen)), your share \(money(share))")
            } else if block.tied {
                out.append("    → nothing selected: joint best candidates (=)")
            } else {
                out.append("    → nothing selected: no candidate has strong enough evidence")
            }
            for candidate in block.candidates {
                let mark = candidate.purchaseID == block.chosenPurchaseID ? "*" : (candidate.jointBest ? "=" : " ")
                let band = candidate.band.map { "band \($0)" } ?? "no band"
                out.append("     \(mark) score \(pad(String(candidate.score), 3, right: true)) · \(band) · your share \(money(candidate.yourShareCents))")
                out.append("         " + upLine(candidate.purchaseID))
                out.append("         reasons: \(candidate.reasons.isEmpty ? "—" : candidate.reasons.joined(separator: ", "))")
            }
        }

        section(&out, "CORRECT THE AMOUNT", result.amends.count, "Same transaction, different amount in YNAB.")
        for amend in result.amends {
            out.append("  Up   " + upLine(amend.upID))
            out.append("  YNAB " + ynabLine(amend.ynabID))
            out.append("       difference \(money(amend.deltaCents))")
        }

        section(&out, "CHECK THESE YOURSELF", result.queries.count, "In YNAB, nothing in Up behind it.")
        for query in result.queries {
            out.append("  " + ynabLine(query.ynabID))
        }

        out.append("")
        out.append("=== RECONCILED — no action needed ===")

        section(&out, "Full repayments (pass 5)", result.repaid.count, "Purchase cancelled by an equal credit from someone else.")
        for pair in result.repaid {
            out.append("  Purchase " + upLine(pair.purchaseID))
            out.append("  Credit   " + upLine(pair.creditID))
            out.append("")
        }

        section(&out, "Merchant reversals (pass 2)", result.reversals.count, "Purchase refunded by the same merchant.")
        for pair in result.reversals {
            out.append("  Purchase " + upLine(pair.purchaseID))
            out.append("  Refund   " + upLine(pair.creditID))
            out.append("")
        }

        section(&out, "Shared costs already in YNAB (pass 3)", result.splitsInYNAB.count, "Bill + repayment in Up = your share in YNAB.")
        for split in result.splitsInYNAB {
            out.append("  YNAB      " + ynabLine(split.ynabID))
            out.append("  Bill      " + upLine(split.purchaseID))
            out.append("  Repayment " + upLine(split.depositID))
            out.append("")
        }

        section(&out, "Direct matches (pass 1)", result.matched.count, "Same amount on both sides.")
        let sortedMatches = result.matched.sorted { lhs, rhs in
            let lhsDate = upByID[lhs.upID]?.date
            let rhsDate = upByID[rhs.upID]?.date
            if let lhsDate, let rhsDate, lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.upID < rhs.upID
        }
        for match in sortedMatches {
            out.append("  " + upLine(match.upID) + "   ⇄ " + ynabCompact(match.ynabID) + (match.dayGap > 0 ? "  (\(match.dayGap)d apart)" : ""))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    private func section(_ out: inout [String], _ title: String, _ count: Int, _ explanation: String) {
        out.append("")
        out.append("--- \(title) (\(count)) — \(explanation)")
    }

    private func upLine(_ id: String) -> String {
        guard let t = upByID[id] else { return "unknown Up transaction \(short(id))" }
        var line = "\(t.date)  \(pad(money(t.money.cents), 10, right: true))  \(t.description)"
        if t.status == "HELD" { line += "  [PENDING]" }
        if let type = t.transactionType { line += "  · \(type)" }
        return line + "  (\(short(id)))"
    }

    private func ynabLine(_ id: String) -> String {
        guard let t = ynabByID[id] else { return "unknown YNAB transaction \(short(id))" }
        let payee = t.payeeName.isEmpty ? "(no payee)" : t.payeeName
        return "\(t.date)  \(pad(money(t.money.cents), 10, right: true))  \(payee)  · \(t.categoryName ?? "uncategorised") · \(t.cleared)  (\(short(id)))"
    }

    private func ynabCompact(_ id: String) -> String {
        guard let t = ynabByID[id] else { return short(id) }
        return "YNAB \(t.date) \(t.payeeName.isEmpty ? "(no payee)" : t.payeeName) (\(short(id)))"
    }

    private func short(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func money(_ cents: Int) -> String {
        Money(cents: cents).formatted
    }

    private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return right ? padding + text : text + padding
    }

    private func describe(_ warning: ReconciliationWarning) -> String {
        switch warning {
        case let .subCentYNABAmount(transactionID, milliunits):
            return "YNAB transaction \(short(transactionID)) has a sub-cent amount (\(milliunits) milliunits)"
        case .noPartnersConfigured:
            return "SPLIT_PARTNERS is empty, so every inflow is treated as a possible repayment"
        }
    }
}
