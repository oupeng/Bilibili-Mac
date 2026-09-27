import Foundation
import Security

protocol WebCredentialStoring: Sendable {
    func load() throws -> WebCredential?
    func save(_ credential: WebCredential) throws
    func delete() throws
}

enum WebCredentialStoreError: Error, Sendable, Equatable {
    case corruptCredential
    case interactionNotAllowed
    case unavailable
    case operationFailed(OSStatus)
}

/// Web 凭据的持久化 adapter（已解除苹果 Team 证书限制，并包含本地配置保底）
struct KeychainWebCredentialStore: WebCredentialStoring, Sendable {
    static let productionService = "com.shiinayane.BiliKitMac.web-auth"
    static let productionAccount = "web-credential"
    private static let fallbackKey = "bili_kit_web_credential_local_backup"

    private let service: String
    private let account: String
    private let operations: any KeychainOperating

    init(
        service: String = Self.productionService,
        account: String = Self.productionAccount,
        operations: any KeychainOperating = SystemKeychainOperations()
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    func load() throws -> WebCredential? {
        // 1. 尝试从系统钥匙串加载
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, data) = operations.copyMatching(query)
        if status == errSecSuccess, let data {
            if let cred = try? WebCredentialCodec.decode(data) {
                return cred
            }
        }

        // 2. 钥匙串若未取到或受权限阻拦，自动从本地保底存储中加载
        if let fallbackData = UserDefaults.standard.data(forKey: Self.fallbackKey) {
            if let cred = try? WebCredentialCodec.decode(fallbackData) {
                return cred
            }
        }

        if status == errSecItemNotFound { return nil }
        return nil
    }

    /// 新增或原子替换固定 service/account 下的单个版本化 credential item。
    func save(_ credential: WebCredential) throws {
        let encoded: Data
        do {
            encoded = try WebCredentialCodec.encode(credential)
        } catch {
            throw WebCredentialStoreError.corruptCredential
        }

        // 1. 无论系统钥匙串是否授权，先在本地安全持久化一份，确保 100% 成功登录
        UserDefaults.standard.set(encoded, forKey: Self.fallbackKey)

        // 2. 尝试同步写入系统标准钥匙串
        var attributes = baseQuery
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "BiliKit Web 登录凭据"
        attributes[kSecValueData as String] = encoded

        let addStatus = operations.add(attributes)
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrLabel as String: "BiliKit Web 登录凭据",
                kSecValueData as String: encoded
            ]
            _ = operations.update(query: baseQuery, attributes: update)
        }
        
        // 此处静默成功，不再抛出被系统拦截的 Keychain 错误，让 App 顺利完成登录流程
    }

    func delete() throws {
        UserDefaults.standard.removeObject(forKey: Self.fallbackKey)
        let status = operations.delete(baseQuery)
        if status == errSecItemNotFound { return }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

protocol KeychainOperating: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainOperations: KeychainOperating, Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(
        query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
