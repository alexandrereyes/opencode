import Foundation
import Security

@MainActor public protocol CredentialBackend {
  func read(_ account: String) throws -> Data?
  func write(_ data: Data?, account: String) throws
}

public struct KeychainFailure: LocalizedError {
  public let status: OSStatus
  public var errorDescription: String? { "Não foi possível acessar as credenciais no Chaves (\(status))." }
}

@MainActor public struct KeychainBackend: CredentialBackend {
  private let service: String
  public init(service: String = "br.com.alexandrem.opencode.servers") { self.service = service }
  private func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
  }
  public func read(_ account: String) throws -> Data? {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    return result as? Data
  }
  public func write(_ data: Data?, account: String) throws {
    let query = query(account)
    guard let data else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainFailure(status: status)
      }
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainFailure(status: added) }
      return
    }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
  }
}

@MainActor public struct ServerCredentials {
  private let backend: any CredentialBackend
  public init(backend: any CredentialBackend = KeychainBackend()) { self.backend = backend }
  public func password(_ id: String) throws -> String? {
    try backend.read(id).flatMap { String(data: $0, encoding: .utf8) }
  }
  public func set(_ password: String?, for id: String) throws {
    try backend.write(password.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, account: id)
  }
}
