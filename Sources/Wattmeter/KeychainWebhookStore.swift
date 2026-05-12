import Foundation
import Security

/// Stores webhook URLs in the macOS Keychain as generic passwords.
///
/// - `service` = `dev.emreisik.Wattmeter.webhook`
/// - `account` = caller-chosen ref (e.g. "default" or a UUID string)
///
/// Budget structs hold only the ref string; the raw URL is never persisted in
/// UserDefaults or plist files, and never logged in cleartext.
enum KeychainWebhookStore {
    static let service: String = "dev.emreisik.Wattmeter.webhook"

    enum KeychainError: Error, CustomStringConvertible {
        case unhandled(OSStatus)
        case encoding

        var description: String {
            switch self {
            case .unhandled(let s): return "Keychain error \(s)"
            case .encoding:         return "Keychain UTF-8 encoding failed"
            }
        }
    }

    /// Inserts or updates the webhook URL associated with `ref`.
    static func save(_ url: String, ref: String) throws {
        guard let data = url.data(using: .utf8) else { throw KeychainError.encoding }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref
        ]

        // Try update first
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandled(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unhandled(addStatus)
        }
    }

    /// Returns the webhook URL for the given ref, or nil if absent.
    static func load(ref: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the entry for the given ref.
    @discardableResult
    static func delete(ref: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Lists the refs (accounts) currently stored under this service.
    static func listRefs() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Utility for log redaction. Webhook URLs must NEVER be printed in cleartext.
enum WebhookRedaction {
    /// Returns a redacted form of a webhook URL safe for logging.
    /// e.g. "https://hooks.slack.com/services/T***/B***/***"
    static func redact(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return "<redacted>" }
        let scheme = parsed.scheme ?? "https"
        let segments = parsed.pathComponents.filter { $0 != "/" }
        // Keep only the first path segment; mask the rest.
        let first = segments.first.map { "/\($0)" } ?? ""
        let masked = segments.count > 1 ? "/***" : ""
        return "\(scheme)://\(host)\(first)\(masked)"
    }
}
