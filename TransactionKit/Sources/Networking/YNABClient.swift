import Foundation
import TransactionKit

public protocol YNABClientProtocol: Sendable {
    func fetchBalanceCents(planID: String, accountID: String) async throws -> Int
    func fetchTransactions(planID: String, accountID: String, since: LocalDate) async throws -> [YNABTransaction]
    func fetchCategories(planID: String) async throws -> [YNABCategoryGroup]
    func fetchPayees(planID: String) async throws -> [String]
    func createTransactions(planID: String, request: YNABCreateRequest) async throws -> [String]
}

public struct YNABCategoryGroup: Equatable, Sendable {
    public let id: String
    public let name: String
    public let categories: [YNABCategory]

    public init(id: String, name: String, categories: [YNABCategory]) {
        self.id = id
        self.name = name
        self.categories = categories
    }
}

public struct YNABCategory: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct YNABClient: YNABClientProtocol, Sendable {
    private let token: String
    private let httpClient: RetryingHTTPClient
    private let baseURL: URL
    private let cache: (any ResponseCache)?

    public init(
        token: String,
        httpClient: RetryingHTTPClient = RetryingHTTPClient(),
        baseURL: URL = URL(string: "https://api.ynab.com/v1")!,
        cache: (any ResponseCache)? = nil
    ) {
        self.token = token
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.cache = cache
    }

    public func fetchBalanceCents(planID: String, accountID: String) async throws -> Int {
        let data = try await fetchWithPlanFallback(
            planID: planID,
            suffix: "accounts/\(accountID)"
        )
        let response: AccountResponse = try decode(data)
        return Money.fromYNAB(
            milliunits: response.data.account.balance,
            transactionID: "account:\(accountID)"
        ).money.cents
    }

    public func fetchTransactions(
        planID: String,
        accountID: String,
        since: LocalDate
    ) async throws -> [YNABTransaction] {
        let data = try await fetchWithPlanFallback(
            planID: planID,
            suffix: "accounts/\(accountID)/transactions",
            queryItems: [URLQueryItem(name: "since_date", value: since.description)]
        )
        let response: YNABResponse = try decode(data)
        if let cache {
            try await cache.store(data, for: .ynabTransactions(planID: planID, accountID: accountID))
        }
        return response.normalizedTransactions().values
    }

    public func fetchCategories(planID: String) async throws -> [YNABCategoryGroup] {
        let data = try await fetchWithPlanFallback(planID: planID, suffix: "categories")
        let response: CategoryResponse = try decode(data)
        let groups = response.data.categoryGroups.compactMap { group -> YNABCategoryGroup? in
            guard !group.internalFlag, !group.hidden, !group.deleted else { return nil }
            let categories: [YNABCategory] = group.categories.compactMap { category in
                guard !category.internalFlag, !category.hidden, !category.deleted else { return nil }
                return YNABCategory(id: category.id, name: category.name)
            }
            guard !categories.isEmpty else { return nil }
            return YNABCategoryGroup(id: group.id, name: group.name, categories: categories)
        }
        if let cache { try await cache.store(data, for: .ynabCategories(planID: planID)) }
        return groups
    }

    public func fetchPayees(planID: String) async throws -> [String] {
        let data = try await fetchWithPlanFallback(planID: planID, suffix: "payees")
        let response: PayeeResponse = try decode(data)
        let names = Set(response.data.payees.compactMap { payee in
            !payee.deleted && payee.transferAccountID == nil ? payee.name : nil
        })
        if let cache { try await cache.store(data, for: .ynabPayees(planID: planID)) }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func createTransactions(
        planID: String,
        request: YNABCreateRequest
    ) async throws -> [String] {
        let body: Data
        do {
            body = try request.encoded()
        } catch {
            throw NetworkError.decodingFailure
        }
        let data = try await sendWithPlanFallback(
            planID: planID,
            suffix: "transactions",
            body: body
        )
        let response: CreateResponse = try decode(data)
        return response.data.transactionIDs
    }

    private func fetchWithPlanFallback(
        planID: String,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        do {
            return try await fetch(noun: "plans", planID: planID, suffix: suffix, queryItems: queryItems)
        } catch NetworkError.wrongPlanOrAccount {
            return try await fetch(noun: "budgets", planID: planID, suffix: suffix, queryItems: queryItems)
        }
    }

    private func sendWithPlanFallback(
        planID: String,
        suffix: String,
        body: Data
    ) async throws -> Data {
        do {
            return try await send(noun: "plans", planID: planID, suffix: suffix, body: body)
        } catch NetworkError.wrongPlanOrAccount {
            return try await send(noun: "budgets", planID: planID, suffix: suffix, body: body)
        }
    }

    private func fetch(
        noun: String,
        planID: String,
        suffix: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let url = baseURL.appending(path: "\(noun)/\(planID)/\(suffix)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components?.url else { throw NetworkError.invalidURL }
        return try await httpClient.execute(.authenticated(url: finalURL, token: token))
    }

    private func send(
        noun: String,
        planID: String,
        suffix: String,
        body: Data
    ) async throws -> Data {
        let url = baseURL.appending(path: "\(noun)/\(planID)/\(suffix)")
        return try await httpClient.execute(
            .authenticated(url: url, token: token, method: "POST", body: body)
        )
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingFailure
        }
    }
}

private struct AccountResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let account: Account
    }

    struct Account: Decodable {
        let balance: Int
    }
}

private struct CreateResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let transactionIDs: [String]

        enum CodingKeys: String, CodingKey {
            case transactionIDs = "transaction_ids"
        }
    }
}

private struct CategoryResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let categoryGroups: [Group]

        enum CodingKeys: String, CodingKey {
            case categoryGroups = "category_groups"
        }
    }

    struct Group: Decodable {
        let id: String
        let name: String
        let internalFlag: Bool
        let hidden: Bool
        let deleted: Bool
        let categories: [Category]

        enum CodingKeys: String, CodingKey {
            case id, name, hidden, deleted, categories
            case internalFlag = "internal"
        }
    }

    struct Category: Decodable {
        let id: String
        let name: String
        let internalFlag: Bool
        let hidden: Bool
        let deleted: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, hidden, deleted
            case internalFlag = "internal"
        }
    }
}

private struct PayeeResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let payees: [Payee]
    }

    struct Payee: Decodable {
        let name: String
        let deleted: Bool
        let transferAccountID: String?

        enum CodingKeys: String, CodingKey {
            case name, deleted
            case transferAccountID = "transfer_account_id"
        }
    }
}
