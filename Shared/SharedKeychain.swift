import Foundation
import Security

/// Shared Keychain storage for imported node credentials and full configuration URIs.
/// This API is lifecycle-only and must never be called from the packet loop.
enum SharedKeychain {
    private static let service = "com.shaolihuang.auratunnel.nodes"

    static func save(_ data: Data, reference: String) throws {
        let baseQuery = try query(reference: reference)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SharedKeychainError.operationFailed(addStatus)
            }
        default:
            throw SharedKeychainError.operationFailed(updateStatus)
        }
    }

    static func load(reference: String) throws -> Data {
        var loadQuery = try query(reference: reference)
        loadQuery[kSecReturnData as String] = true
        loadQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw SharedKeychainError.operationFailed(status)
        }
        return data
    }

    static func remove(reference: String) throws {
        let status = SecItemDelete(try query(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedKeychainError.operationFailed(status)
        }
    }

    static func replaceBatch(_ secrets: [KeychainSecret]) throws -> [KeychainBackup] {
        var backups: [KeychainBackup] = []
        backups.reserveCapacity(secrets.count)
        do {
            for secret in secrets {
                let previousValue = try? load(reference: secret.reference)
                try save(secret.data, reference: secret.reference)
                backups.append(KeychainBackup(reference: secret.reference, previousValue: previousValue))
            }
            return backups
        } catch {
            try? restore(backups)
            throw error
        }
    }

    static func restore(_ backups: [KeychainBackup]) throws {
        var firstError: Error?
        for backup in backups.reversed() {
            do {
                if let previousValue = backup.previousValue {
                    try save(previousValue, reference: backup.reference)
                } else {
                    try remove(reference: backup.reference)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private static func query(reference: String) throws -> [String: Any] {
        guard !reference.isEmpty else {
            throw SharedKeychainError.invalidReference
        }
        guard
            let accessGroup = Bundle.main.object(
                forInfoDictionaryKey: SharedConfiguration.keychainAccessGroupInfoKey
            ) as? String,
            !accessGroup.isEmpty,
            !accessGroup.contains("$(")
        else {
            throw SharedKeychainError.accessGroupUnavailable
        }

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}

struct KeychainSecret: Sendable {
    let reference: String
    let data: Data
}

struct KeychainBackup: Sendable {
    let reference: String
    let previousValue: Data?
}

enum SharedKeychainError: LocalizedError {
    case invalidReference
    case accessGroupUnavailable
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            "节点密钥引用无效。"
        case .accessGroupUnavailable:
            "共享 Keychain Access Group 未配置，请检查两个 Target 的签名能力。"
        case .operationFailed(let status):
            "Keychain 操作失败（OSStatus: \(status)）。"
        }
    }
}
