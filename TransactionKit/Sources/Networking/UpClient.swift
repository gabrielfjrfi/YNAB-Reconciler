import Foundation
import TransactionKit

public protocol UpClientProtocol: Sendable {
    func fetchTransactions(
        since: LocalDate,
        timeZone: TimeZone,
        accountID: String?,
        progress: (@Sendable (UpFetchProgress) async -> Void)?
    ) async throws -> [UpTransaction]
}

public struct UpFetchProgress: Equatable, Sendable {
    public let pagesFetched: Int
    public let transactionsFetched: Int

    public init(pagesFetched: Int, transactionsFetched: Int) {
        self.pagesFetched = pagesFetched
        self.transactionsFetched = transactionsFetched
    }
}

public struct UpClient: UpClientProtocol, Sendable {
    private let token: String
    private let httpClient: RetryingHTTPClient
    private let baseURL: URL
    private let cache: (any ResponseCache)?

    public init(
        token: String,
        httpClient: RetryingHTTPClient = RetryingHTTPClient(),
        baseURL: URL = URL(string: "https://api.up.com.au/api/v1")!,
        cache: (any ResponseCache)? = nil
    ) {
        self.token = token
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.cache = cache
    }

    public func fetchTransactions(
        since: LocalDate,
        timeZone: TimeZone,
        accountID: String? = nil,
        progress: (@Sendable (UpFetchProgress) async -> Void)? = nil
    ) async throws -> [UpTransaction] {
        let path = accountID.map { "accounts/\($0)/transactions" } ?? "transactions"
        let endpoint = baseURL.appending(path: path)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "page[size]", value: "100"),
            URLQueryItem(name: "filter[since]", value: Self.sinceTimestamp(for: since, in: timeZone))
        ]
        // URLComponents leaves `+` literal in query values, where servers may
        // interpret it as a space. Up requires the offset sign as `%2B`.
        let encodedQuery = components?.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard var nextURL = components?.url else { throw NetworkError.invalidURL }

        var transactions: [UpTransaction] = []
        var seen: Set<String> = []
        var visitedPageURLs: Set<URL> = []
        var cachedPages: [Data] = []
        while true {
            try Task.checkCancellation()
            guard visitedPageURLs.insert(nextURL).inserted else {
                throw NetworkError.paginationLoop
            }
            let data = try await httpClient.execute(.authenticated(url: nextURL, token: token))
            cachedPages.append(data)
            let page: Page
            do {
                page = try JSONDecoder().decode(Page.self, from: data)
            } catch {
                throw NetworkError.decodingFailure
            }
            for transaction in page.data where seen.insert(transaction.id).inserted {
                transactions.append(transaction)
            }
            await progress?(UpFetchProgress(
                pagesFetched: cachedPages.count,
                transactionsFetched: transactions.count
            ))
            guard let next = page.links?.next else { break }
            guard let url = URL(string: next, relativeTo: nextURL)?.absoluteURL else {
                throw NetworkError.invalidURL
            }
            nextURL = url
        }
        if let cache {
            let payload = try JSONEncoder().encode(CachedPages(pages: cachedPages))
            try await cache.store(payload, for: .upTransactions(accountID: accountID))
        }
        return transactions
    }

    public static func sinceTimestamp(for date: LocalDate, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let localMidnight = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: date.year,
            month: date.month,
            day: date.day,
            hour: 0,
            minute: 0,
            second: 0
        ))!
        let seconds = timeZone.secondsFromGMT(for: localMidnight)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3_600
        let minutes = magnitude % 3_600 / 60
        return "\(date.description)T00:00:00\(sign)\(String(format: "%02d:%02d", hours, minutes))"
    }

    private struct Page: Decodable {
        let data: [UpTransaction]
        let links: Links?
    }

    private struct Links: Decodable {
        let next: String?
    }

    private struct CachedPages: Codable {
        let pages: [Data]
    }
}
