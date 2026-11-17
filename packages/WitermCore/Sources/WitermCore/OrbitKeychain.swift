#if os(macOS)
  import Foundation
  import LocalAuthentication
  import Security

  /// Orbit's OpenAI API key in the data protection Keychain, on this Mac
  /// only, kept only after the user chooses to. The app saves and removes
  /// it; the app and, for a paired device's request, the background service
  /// read it to give Orbit, which holds it in memory only (docs/orbit.md).
  public enum OrbitKeychain {
    static let service = "com.witerm.orbit.v1"
    static let account = "openai-api-key"

    static var query: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true,
      ]
    }

    /// Never asks the user anything; nil when there's no key or it can't be read.
    public static func read() -> String? {
      var request = query
      request[kSecReturnData as String] = true
      request[kSecMatchLimit as String] = kSecMatchLimitOne
      let context = LAContext()
      context.interactionNotAllowed = true
      request[kSecUseAuthenticationContext as String] = context
      var result: CFTypeRef?
      guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
        return nil
      }
      return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String) -> Bool {
      delete()
      var request = query
      request[kSecValueData as String] = Data(key.utf8)
      request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete() -> Bool {
      let status = SecItemDelete(query as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
  }
#endif
