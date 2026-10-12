import Foundation

protocol PushedLogStorage: Sendable {
    func load() throws -> [String: Date]
    func save(_ entries: [String: Date]) throws
}

struct DiskPushedLogStorage: PushedLogStorage {
    private let fileURL: URL

    init(fileManager: FileManager = .default) throws {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resourceValues)
        fileURL = directory.appending(path: "ynab-pushed.json")
    }

    func load() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: Date].self, from: Data(contentsOf: fileURL))
    }

    func save(_ entries: [String: Date]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedFile = fileURL
        try protectedFile.setResourceValues(resourceValues)
    }
}

struct MemoryPushedLogStorage: PushedLogStorage {
    func load() throws -> [String: Date] { [:] }
    func save(_ entries: [String: Date]) throws {}
}
