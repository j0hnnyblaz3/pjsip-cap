import Foundation
import Security

/// The SIP login, kept in the Keychain so a VoIP push can register the phone
/// before the app's web layer has booted — as Android's SipCredentialStore
/// does. Without it a push that woke a killed app had no account to register,
/// the PBX's INVITE had nowhere to go, and CallKit rang with nothing behind it.
///
/// `AfterFirstUnlockThisDeviceOnly`: readable by a push on a locked phone,
/// never synced or restored to another device.
final class SipCredentialStore {
    private let service = "com.redyrect.pjsip.login"
    private let account = "sip"

    func save(_ config: SipConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            pjsipLog("[SipCredentialStore] save failed (\(status)) — a push will not be able to register")
        }
    }

    func load() -> SipConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        do {
            return try JSONDecoder().decode(SipConfig.self, from: data)
        } catch {
            pjsipLog("[SipCredentialStore] saved login unreadable, discarding: \(error)")
            clear()
            return nil
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
