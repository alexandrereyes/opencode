import CryptoKit
import Foundation

public struct TranscriptionModelFiles: Sendable {
  public let root: URL
  public let manifest: TranscriptionManifest
  public init(root: URL, manifest: TranscriptionManifest) { self.root = root; self.manifest = manifest }
  public static var defaultRoot: URL {
    URL.applicationSupportDirectory.appending(path: "OpenCode/Transcription", directoryHint: .isDirectory)
  }
  public var installed: URL { root.appending(path: manifest.version, directoryHint: .isDirectory) }
  public var partial: URL { root.appending(path: "\(manifest.version).partial", directoryHint: .isDirectory) }
  public var isInstalled: Bool { FileManager.default.fileExists(atPath: installed.path) }
  public func prepareRoot() throws { try Self.prepare(root) }
  public static func prepare(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
    #endif
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  public func remove() throws {
    for url in [installed, partial] where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
  public func isStaged(_ file: TranscriptionManifest.File) -> Bool {
    let size = try? partial.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
    return size.map(Int64.init) == file.bytes
  }
  public func missingFiles() -> [TranscriptionManifest.File] {
    isInstalled ? [] : manifest.files.filter { !isStaged($0) }
  }
  public func stagedBytes() -> Int64 {
    isInstalled ? manifest.totalBytes : manifest.files.filter(isStaged).reduce(0) { $0 + $1.bytes }
  }
  public func stage(_ file: TranscriptionManifest.File, from location: URL) throws {
    defer { try? FileManager.default.removeItem(at: location) }
    let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
    guard size == file.bytes, try Self.sha256(of: location) == file.sha256 else { throw TranscriptionError.integrity }
    let target = partial.appending(path: file.path)
    try Self.prepare(target.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: location, to: target)
  }
  public func install() throws {
    guard !isInstalled else { return }
    guard manifest.files.allSatisfy(isStaged) else { throw TranscriptionError.integrity }
    try? FileManager.default.removeItem(at: partial.appending(path: ".resume"))
    try FileManager.default.moveItem(at: partial, to: installed)
  }
  public func resumeDataURL(for file: TranscriptionManifest.File) -> URL {
    partial.appending(path: ".resume").appending(path: file.path.replacingOccurrences(of: "/", with: "_"))
  }
  public var bytesOnDisk: Int64 {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    return enumerator.compactMap { $0 as? URL }.reduce(0) { total, url in
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
    }
  }
  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum TranscriptionError: Error, Equatable, LocalizedError {
  case integrity, noSpace, notReady, empty
  case download(String)
  public var errorDescription: String? {
    switch self {
    case .integrity: "O arquivo baixado veio diferente do esperado."
    case .noSpace: "Falta espaço no iPhone para o modelo de transcrição."
    case .notReady: "O modelo de transcrição ainda não está pronto."
    case .empty: "Não foi possível reconhecer fala nesta gravação."
    case .download(let reason): reason
    }
  }
}
