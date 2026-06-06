// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import Foundation
import Security

// Keychain stores the account passphrase for the logged-in cloud session — so
// "Sync now" is one tap and survives restart. A single item (one controller per
// the "sync is sync" rule). "Log out" deletes it. This is the macOS half of the
// cross-platform contract (see docs/cloud-sync.md): iOS uses the same Keychain
// APIs, Android the Keystore.
enum Keychain {
    private static let service = "org.pharosvpn.caravel"
    private static let account = "account-passphrase"

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// store saves (or replaces) the passphrase, readable after first unlock.
    static func store(_ secret: String) {
        SecItemDelete(base() as CFDictionary)
        var add = base()
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// read returns the stored passphrase, or nil if not logged in.
    static func read() -> String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// delete clears the stored passphrase (log out).
    static func delete() {
        SecItemDelete(base() as CFDictionary)
    }

    static var hasCredential: Bool { read() != nil }
}
