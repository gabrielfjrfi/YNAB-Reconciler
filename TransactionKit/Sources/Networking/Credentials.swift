import Foundation
import Security

public enum Credential: String, CaseIterable, Sendable {
    case upToken = "up-token"
    case ynabToken = "ynab-token"
}

public protocol CredentialStore: Sendable {
    func save(_ value: String, for credential: Credential) throws
    func value(for credential: Credential) throws -> String?
    func remove(_ credential: Credential) throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychainFailure(status: OSStatus)
    case invalidStoredValue
}

public struct KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(_ value: String, for credential: Credential) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    public func value(for credential: Credential) throws -> String? {
        var query = baseQuery(for: credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        return value
    }

    public func remove(_ credential: Credential) throws {
        let status = SecItemDelete(baseQuery(for: credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    private func baseQuery(for credential: Credential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue
        ]
    }
}

public struct AccountSettingsStore: @unchecked Sendable {
    private enum Key {
        static let ynabPlanID = "ynabPlanID"
        static let ynabAccountID = "ynabAccountID"
        static let upAccountID = "upAccountID"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var ynabPlanID: String? {
        get { defaults.string(forKey: Key.ynabPlanID) }
        nonmutating set { defaults.set(newValue, forKey: Key.ynabPlanID) }
    }

    public var ynabAccountID: String? {
        get { defaults.string(forKey: Key.ynabAccountID) }
        nonmutating set { defaults.set(newValue, forKey: Key.ynabAccountID) }
    }

    public var upAccountID: String? {
        get { defaults.string(forKey: Key.upAccountID) }
        nonmutating set { defaults.set(newValue, forKey: Key.upAccountID) }
    }
}
