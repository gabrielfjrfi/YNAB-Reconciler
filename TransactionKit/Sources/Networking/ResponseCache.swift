import CryptoKit
import Foundation

public enum ResponseCacheKey: Hashable, Sendable {
    case upTransactions(accountID: String?)
    case ynabTransactions(planID: String, accountID: String)
    case ynabCategories(planID: String)
    case ynabPayees(planID: String)

    fileprivate var stableValue: String {
        switch self {
        case .upTransactions(let accountID):
            return "up-transactions:\(accountID ?? "all")"
        case .ynabTransactions(let planID, let accountID):
            return "ynab-transactions:\(planID):\(accountID)"
        case .ynabCategories(let planID):
            return "ynab-categories:\(planID)"
        case .ynabPayees(let planID):
            return "ynab-payees:\(planID)"
        }
    }
}

public protocol ResponseCache: Sendable {
    func store(_ data: Data, for key: ResponseCacheKey) async throws
    func load(for key: ResponseCacheKey) async throws -> Data?
}

public actor DiskResponseCache: ResponseCache {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = applicationSupport.appending(path: "YNABReconcile/ResponseCache", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = self.directory
        try mutableDirectory.setResourceValues(values)
    }

    public func store(_ data: Data, for key: ResponseCacheKey) async throws {
        let url = fileURL(for: key)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    public func load(for key: ResponseCacheKey) async throws -> Data? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func fileURL(for key: ResponseCacheKey) -> URL {
        let digest = SHA256.hash(data: Data(key.stableValue.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).cache")
    }
}

public actor InMemoryResponseCache: ResponseCache {
    private var values: [ResponseCacheKey: Data] = [:]

    public init() {}

    public func store(_ data: Data, for key: ResponseCacheKey) async throws {
        values[key] = data
    }

    public func load(for key: ResponseCacheKey) async throws -> Data? {
        values[key]
    }
}
