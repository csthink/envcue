// SystemKeychainStore — the real Security-framework implementation of KeychainStore (T2.1).
//
// Stores each secret as a generic-password item keyed by (service, account):
//   service = "dev.mars.envcue" (fixed), account = "{layer}/{VAR}" (design §3).
// (service, account) is the unique address, so the same variable name can hold a
// different secret per layer. Nothing here caches plaintext or touches disk — every
// read is a live `SecItemCopyMatching` (design §3).

import Foundation
import Security

public struct SystemKeychainStore: KeychainStore {
    public init() {}

    /// Identity query for one secret: class + service + account, without value or return
    /// attributes. `get` adds the return flags; `set`/`delete` use it as-is.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: EnvCueKeychain.service,
            kSecAttrAccount as String: account,
        ]
    }

    public func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedData(account: account)
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData(account: account)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    public func set(account: String, value: String) throws {
        let data = Data(value.utf8)
        // Upsert: try to update an existing item first; if there is none, add it. This
        // avoids a delete+add window and keeps the operation atomic from the caller's view.
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(status: addStatus)
            }
        default:
            throw KeychainError.unhandled(status: updateStatus)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return // idempotent: deleting an absent entry is a no-op success
        default:
            throw KeychainError.unhandled(status: status)
        }
    }
}
