import Foundation
import Networking
import Testing
import TransactionKit

@Suite("Networking", .serialized)
struct NetworkingTests {
    @Test("Up retrieves a selected account balance in base units")
    func upSelectedAccountBalance() async throws {
        let response = Data(
            #"{"data":{"attributes":{"balance":{"valueInBaseUnits":12536}}}}"#.utf8
        )
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: response) }
        let client = UpClient(
            token: "secret",
            httpClient: testHTTPClient(),
            baseURL: URL(string: "https://up.test")!
        )

        let balance = try await client.fetchBalanceCents(accountID: "account-id")

        #expect(balance == 12_536)
        #expect(FakeURLProtocol.requests().first?.url?.path == "/accounts/account-id")
    }

    @Test("Up sums all account balances when no account is selected")
    func upAllAccountBalances() async throws {
        let response = Data(
            #"{"data":[{"attributes":{"balance":{"valueInBaseUnits":12536}}},{"attributes":{"balance":{"valueInBaseUnits":-400}}}]}"#.utf8
        )
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: response) }
        let client = UpClient(
            token: "secret",
            httpClient: testHTTPClient(),
            baseURL: URL(string: "https://up.test")!
        )

        let balance = try await client.fetchBalanceCents(accountID: nil)

        #expect(balance == 12_136)
        #expect(FakeURLProtocol.requests().first?.url?.path == "/accounts")
    }

    @Test("YNAB retrieves the account balance and converts milliunits to cents")
    func ynabAccountBalance() async throws {
        let response = Data(
            #"{"data":{"account":{"balance":-6211640,"cleared_balance":0,"uncleared_balance":0}}}"#.utf8
        )
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: response) }
        let client = YNABClient(
            token: "secret",
            httpClient: testHTTPClient(),
            baseURL: URL(string: "https://ynab.test/v1")!
        )

        let balance = try await client.fetchBalanceCents(
            planID: "plan-id",
            accountID: "account-id"
        )

        #expect(balance == -621_164)
        #expect(FakeURLProtocol.requests().first?.url?.path == "/v1/plans/plan-id/accounts/account-id")
    }

    @Test("Up follows pagination and de-duplicates repeated IDs")
    func paginationAndDeduplication() async throws {
        let fixture = try jsonObject(named: "up")
        let records = try #require(fixture["data"] as? [[String: Any]])
        let firstRecords = Array(records.prefix(100))
        let secondRecords = [firstRecords[0]] + Array(records.dropFirst(100))
        let pageOne = try JSONSerialization.data(withJSONObject: [
            "data": firstRecords,
            "links": ["next": "https://up.test/page-2"]
        ])
        let pageTwo = try JSONSerialization.data(withJSONObject: [
            "data": secondRecords,
            "links": ["next": NSNull()]
        ])
        FakeURLProtocol.configure { request, _ in
            request.url?.path == "/page-2"
                ? .init(status: 200, data: pageTwo)
                : .init(status: 200, data: pageOne)
        }
        let client = UpClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)
        let transactions = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )

        #expect(transactions.count == records.count)
        #expect(Set(transactions.map(\.id)).count == records.count)
        #expect(FakeURLProtocol.requests().count == 2)
    }

    @Test("Up reports page progress while paginating")
    func paginationProgress() async throws {
        let emptyPage = Data(#"{"data":[],"links":{"next":"https://up.test/page-2"}}"#.utf8)
        let finalPage = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { request, _ in
            request.url?.path == "/page-2"
                ? .init(status: 200, data: finalPage)
                : .init(status: 200, data: emptyPage)
        }
        let recorder = ProgressRecorder()
        let client = UpClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)

        _ = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        ) { progress in
            await recorder.append(progress)
        }

        #expect(await recorder.values() == [
            UpFetchProgress(pagesFetched: 1, transactionsFetched: 0),
            UpFetchProgress(pagesFetched: 2, transactionsFetched: 0)
        ])
    }

    @Test("Up rejects a repeated pagination URL")
    func paginationLoop() async throws {
        let loopingPage = Data(#"{"data":[],"links":{"next":"https://up.test/page-2"}}"#.utf8)
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: loopingPage) }
        let client = UpClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)

        await #expect(throws: NetworkError.paginationLoop) {
            _ = try await client.fetchTransactions(
                since: LocalDate(isoDate: "2026-09-01"),
                timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
            )
        }
        #expect(FakeURLProtocol.requests().count == 2)
    }

    @Test("Authenticated requests have a finite timeout")
    func requestTimeout() async throws {
        let empty = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: empty) }
        let client = UpClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)

        _ = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )

        #expect(FakeURLProtocol.requests().first?.timeoutInterval == 30)
    }

    @Test("Up since timestamps use date-specific Melbourne offsets and percent-encode plus")
    func daylightSavingOffsets() async throws {
        let empty = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: empty) }
        let client = UpClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)
        let melbourne = try #require(TimeZone(identifier: "Australia/Melbourne"))

        _ = try await client.fetchTransactions(since: LocalDate(isoDate: "2026-01-15"), timeZone: melbourne)
        _ = try await client.fetchTransactions(since: LocalDate(isoDate: "2026-07-15"), timeZone: melbourne)

        let requests = FakeURLProtocol.requests()
        #expect(requests[0].url?.absoluteString.contains("filter%5Bsince%5D=2026-01-15T00:00:00%2B11:00") == true)
        #expect(requests[1].url?.absoluteString.contains("filter%5Bsince%5D=2026-07-15T00:00:00%2B10:00") == true)
    }

    @Test("429 honours Retry-After before retrying")
    func rateLimitRetry() async throws {
        let empty = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { _, attempt in
            attempt == 1
                ? .init(status: 429, headers: ["Retry-After": "7"], data: Data())
                : .init(status: 200, data: empty)
        }
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(
            transport: URLSessionTransport(session: fakeSession()),
            sleeper: sleeper,
            maximumAttempts: 5,
            initialBackoffSeconds: 1
        )
        let client = UpClient(token: "secret", httpClient: retrying, baseURL: URL(string: "https://up.test")!)

        _ = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )

        #expect(await sleeper.recordedSeconds() == [7])
        #expect(FakeURLProtocol.requests().count == 2)
    }

    @Test("5xx responses use exponential backoff")
    func serverFailureRetry() async throws {
        let empty = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { _, attempt in
            attempt < 3
                ? .init(status: 503, data: Data())
                : .init(status: 200, data: empty)
        }
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(
            transport: URLSessionTransport(session: fakeSession()),
            sleeper: sleeper,
            maximumAttempts: 5,
            initialBackoffSeconds: 2
        )
        let client = UpClient(token: "secret", httpClient: retrying, baseURL: URL(string: "https://up.test")!)

        _ = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )

        #expect(await sleeper.recordedSeconds() == [2, 4])
        #expect(FakeURLProtocol.requests().count == 3)
    }

    @Test("Cached response data never contains the bearer token")
    func cacheExcludesToken() async throws {
        let empty = Data(#"{"data":[],"links":{"next":null}}"#.utf8)
        FakeURLProtocol.configure { _, _ in .init(status: 200, data: empty) }
        let cache = InMemoryResponseCache()
        let token = "up:yeah:must-not-be-cached"
        let client = UpClient(
            token: token,
            httpClient: testHTTPClient(),
            baseURL: URL(string: "https://up.test")!,
            cache: cache
        )

        _ = try await client.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )

        let cached = try #require(try await cache.load(for: .upTransactions(accountID: nil)))
        #expect(!cached.contains(Data(token.utf8)))
    }

    @Test("YNAB retries a plans 404 through budgets")
    func plansFallback() async throws {
        let fixture = try resource(named: "ynab")
        FakeURLProtocol.configure { request, _ in
            request.url?.path.contains("/plans/") == true
                ? .init(status: 404, data: Data())
                : .init(status: 200, data: fixture)
        }
        let client = YNABClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://ynab.test/v1")!)
        let transactions = try await client.fetchTransactions(
            planID: "plan-id",
            accountID: "account-id",
            since: LocalDate(isoDate: "2026-09-01")
        )

        #expect(transactions.count == 79)
        #expect(FakeURLProtocol.requests().map { $0.url?.path } == [
            "/v1/plans/plan-id/accounts/account-id/transactions",
            "/v1/budgets/plan-id/accounts/account-id/transactions"
        ])
    }

    @Test("YNAB filters internal, hidden, deleted, and transfer picker values")
    func pickerFiltering() async throws {
        let categories = Data(#"{"data":{"category_groups":[{"id":"keep","name":"Keep","internal":false,"hidden":false,"deleted":false,"categories":[{"id":"visible","name":"Visible","internal":false,"hidden":false,"deleted":false},{"id":"hidden","name":"Hidden","internal":false,"hidden":true,"deleted":false}]},{"id":"internal","name":"Internal","internal":true,"hidden":false,"deleted":false,"categories":[{"id":"x","name":"X","internal":false,"hidden":false,"deleted":false}]}]}}"#.utf8)
        let payees = Data(#"{"data":{"payees":[{"name":"Zulu","deleted":false,"transfer_account_id":null},{"name":"alpha","deleted":false,"transfer_account_id":null},{"name":"Deleted","deleted":true,"transfer_account_id":null},{"name":"Transfer","deleted":false,"transfer_account_id":"account"}]}}"#.utf8)
        FakeURLProtocol.configure { request, _ in
            request.url?.path.hasSuffix("/categories") == true
                ? .init(status: 200, data: categories)
                : .init(status: 200, data: payees)
        }
        let client = YNABClient(token: "secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://ynab.test/v1")!)

        let groups = try await client.fetchCategories(planID: "plan")
        let names = try await client.fetchPayees(planID: "plan")

        #expect(groups == [.init(id: "keep", name: "Keep", categories: [.init(id: "visible", name: "Visible")])])
        #expect(names == ["alpha", "Zulu"])
    }

    @Test("Typed authentication and resource errors do not include credentials")
    func typedErrors() async throws {
        FakeURLProtocol.configure { _, _ in .init(status: 401, data: Data("secret-token".utf8)) }
        let client = UpClient(token: "secret-token", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)
        await #expect(throws: NetworkError.invalidToken) {
            _ = try await client.fetchTransactions(
                since: LocalDate(isoDate: "2026-09-01"),
                timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
            )
        }
    }

    @Test("Fixture-backed clients feed the engine to the expected totals")
    func fixtureBackedIntegration() async throws {
        let upFixture = try resource(named: "up")
        let ynabFixture = try resource(named: "ynab")
        FakeURLProtocol.configure { request, _ in
            request.url?.host == "up.test"
                ? .init(status: 200, data: upFixture)
                : .init(status: 200, data: ynabFixture)
        }
        let upClient = UpClient(token: "up-secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://up.test")!)
        let ynabClient = YNABClient(token: "ynab-secret", httpClient: testHTTPClient(), baseURL: URL(string: "https://ynab.test/v1")!)
        async let up = upClient.fetchTransactions(
            since: LocalDate(isoDate: "2026-09-01"),
            timeZone: try #require(TimeZone(identifier: "Australia/Melbourne"))
        )
        async let ynab = ynabClient.fetchTransactions(
            planID: "plan",
            accountID: "account",
            since: LocalDate(isoDate: "2026-09-01")
        )
        let reconciliation = try await Reconciler().reconcile(
            up: up,
            ynab: ynab,
            parameters: .init(partners: ["$partner_handle"], heldStatus: "cleared")
        )

        #expect(reconciliation.inputCounts.up == 182)
        #expect(reconciliation.inputCounts.ynab == 79)
        #expect(reconciliation.matched.count == 56)
        #expect(reconciliation.reversals.count == 1)
        #expect(reconciliation.splitsInYNAB.count == 23)
        #expect(reconciliation.repaid.count == 1)
        #expect(reconciliation.shareBlocks.count == 24)
        #expect(reconciliation.adds.count == 28)
        #expect(reconciliation.totals.upTotalCents == -395_400)
        #expect(reconciliation.totals.ynabTotalCents == -202_888)
        #expect(reconciliation.totals.gapCents == -192_512)
        #expect(reconciliation.totals.identityHolds)
    }

    @Test("YNAB creates a batch with the exact encoded body")
    func createBatch() async throws {
        let response = Data(#"{"data":{"transaction_ids":["created-1"]}}"#.utf8)
        FakeURLProtocol.configure { request, _ in
            .init(status: 200, data: response)
        }
        let client = YNABClient(
            token: "secret",
            httpClient: testHTTPClient(),
            baseURL: URL(string: "https://ynab.test/v1")!
        )
        let request = YNABCreateRequest(transactions: [
            YNABCreateTransaction(
                accountID: "account",
                date: try LocalDate(isoDate: "2026-09-14"),
                amount: -12_340,
                payeeName: "Market",
                categoryID: "groceries",
                cleared: "cleared"
            )
        ])

        let ids = try await client.createTransactions(planID: "plan", request: request)
        let sent = try #require(FakeURLProtocol.requests().first)
        let expectedBody = try request.encoded()

        #expect(ids == ["created-1"])
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/v1/plans/plan/transactions")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.httpBody == expectedBody)
    }

    private func testHTTPClient() -> RetryingHTTPClient {
        RetryingHTTPClient(
            transport: URLSessionTransport(session: fakeSession()),
            sleeper: RecordingSleeper()
        )
    }

    private func fakeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func resource(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "TestResources"))
        return try Data(contentsOf: url)
    }

    private func jsonObject(named name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: resource(named: name)) as? [String: Any])
    }
}

private actor RecordingSleeper: RetrySleeper {
    private var seconds: [UInt64] = []

    func sleep(seconds: UInt64) async throws {
        self.seconds.append(seconds)
    }

    func recordedSeconds() -> [UInt64] {
        seconds
    }
}

private actor ProgressRecorder {
    private var progress: [UpFetchProgress] = []

    func append(_ value: UpFetchProgress) {
        progress.append(value)
    }

    func values() -> [UpFetchProgress] {
        progress
    }
}

private final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let status: Int
        let headers: [String: String]
        let data: Data

        init(status: Int, headers: [String: String] = [:], data: Data) {
            self.status = status
            self.headers = headers
            self.data = data
        }
    }

    typealias Handler = @Sendable (URLRequest, Int) throws -> Stub

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func configure(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil,
           let stream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.read(stream: stream)
        }
        Self.lock.lock()
        Self.capturedRequests.append(capturedRequest)
        let attempt = Self.capturedRequests.count
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler, let url = capturedRequest.url else {
                throw FakeProtocolError.missingConfiguration
            }
            let stub = try handler(capturedRequest, attempt)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            ) else {
                throw FakeProtocolError.invalidResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private enum FakeProtocolError: Error {
    case missingConfiguration
    case invalidResponse
}
