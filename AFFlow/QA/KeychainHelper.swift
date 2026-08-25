import Foundation
import LocalAuthentication
import Security

enum KeychainHelper {
    // A keychain namespace of AF Flow's own, deliberately distinct from the
    // one the upstream project used, so AF Flow can never read or migrate a
    // secret that an upstream install left behind on the same Mac.
    //
    // The sentence above once named the upstream service and said "upstream AF
    // Flow", which an earlier rename pass had made nonsense of. Comments are the
    // part of a rename that goes wrong quietly.
    static let service = "com.frolikov.afflow"

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func set(_ value: String, for key: String, allowUserInteraction: Bool = false) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if !allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            return false
        }

        var attributes = query
        attributes.removeValue(forKey: kSecUseAuthenticationContext as String)
        attributes.removeValue(forKey: kSecUseAuthenticationUI as String)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    static func get(_ key: String, allowUserInteraction: Bool = false) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String, allowUserInteraction: Bool = false) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if !allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    static func migrateUserDefaultsString(
        defaultsKey: String,
        keychainKey: String,
        defaults: UserDefaults = .standard,
        allowUserInteraction: Bool = false
    ) -> String? {
        if let existing = get(keychainKey, allowUserInteraction: allowUserInteraction), !existing.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            return existing
        }

        guard let legacy = defaults.string(forKey: defaultsKey), !legacy.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }

        if set(legacy, for: keychainKey, allowUserInteraction: allowUserInteraction) {
            defaults.removeObject(forKey: defaultsKey)
        }
        return legacy
    }
}
