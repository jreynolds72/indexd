import Foundation
import Security

public protocol SecureStoring: Sendable {
    func save(_ data: Data, account: String, service: String) async throws
    func load(account: String, service: String) async throws -> Data?
    func delete(account: String, service: String) async throws
}

public enum SecureStoreError: Error {
    case unexpectedStatus(OSStatus)
}

public final class KeychainSecureStore: SecureStoring, Sendable {
    public init() {}

    public func save(_ data: Data, account: String, service: String) async throws {
        try await delete(account: account, service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    public func load(account: String, service: String) async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    public func delete(account: String, service: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }
}

public actor InMemorySecureStore: SecureStoring {
    private struct Key: Hashable {
        let account: String
        let service: String
    }

    private var storage: [Key: Data] = [:]

    public init() {}

    public func save(_ data: Data, account: String, service: String) async throws {
        storage[Key(account: account, service: service)] = data
    }

    public func load(account: String, service: String) async throws -> Data? {
        return storage[Key(account: account, service: service)]
    }

    public func delete(account: String, service: String) async throws {
        storage.removeValue(forKey: Key(account: account, service: service))
    }
}

public final class UserDefaultsSecureStore: SecureStoring, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let namespace: String

    public init(
        suiteName: String = "indexd.DevSecureStore",
        namespace: String = "dev.securestore"
    ) {
        self.userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.namespace = namespace
    }

    public func save(_ data: Data, account: String, service: String) async throws {
        userDefaults.set(data, forKey: key(account: account, service: service))
    }

    public func load(account: String, service: String) async throws -> Data? {
        userDefaults.data(forKey: key(account: account, service: service))
    }

    public func delete(account: String, service: String) async throws {
        userDefaults.removeObject(forKey: key(account: account, service: service))
    }

    private func key(account: String, service: String) -> String {
        "\(namespace).\(service).\(account)"
    }
}
