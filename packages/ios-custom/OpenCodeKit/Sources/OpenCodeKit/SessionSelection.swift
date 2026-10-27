import Foundation

/// The Sessões list's selection mode, like the custom web sidebar's (`sidebar-selection.ts`): rows leave the
/// selection when they stop being visible, finished actions keep only the failures, and an empty selection ends the mode.
public struct SessionSelection: Sendable, Equatable {
  public private(set) var active = false
  public private(set) var ids: [String] = []

  public init() {}

  public func contains(_ id: String) -> Bool { ids.contains(id) }

  public mutating func start(_ id: String) {
    active = true
    ids = [id]
  }

  public mutating func toggle(_ id: String) {
    guard active else { return }
    if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
    if ids.isEmpty { clear() }
  }

  public mutating func selectAll(_ visible: [String]) {
    guard active else { return }
    ids = ids + visible.filter { !ids.contains($0) }
  }

  public mutating func clear() { self = Self() }

  /// Drops rows that were hidden, archived or deleted elsewhere.
  public mutating func retain(_ visible: Set<String>) {
    guard active else { return }
    ids.removeAll { !visible.contains($0) }
    if ids.isEmpty { clear() }
  }

  public mutating func complete(_ result: SessionBulkResult) {
    ids.removeAll { result.succeeded.contains($0) }
    if ids.isEmpty { clear() }
  }
}

public struct SessionBulkResult: Sendable, Equatable {
  public var succeeded: [String] = []
  public var failed: [String] = []
  public init(succeeded: [String] = [], failed: [String] = []) {
    self.succeeded = succeeded
    self.failed = failed
  }
}

/// Portuguese copy for the batch actions; the custom web has these strings in English only (`session.bulk.*`).
public enum SessionBulkCopy {
  public static func count(_ count: Int) -> String { count == 1 ? "1 selecionada" : "\(count) selecionadas" }

  public static func deleteTitle(_ count: Int) -> String { count == 1 ? "Excluir 1 sessão" : "Excluir \(count) sessões" }

  public static func deleteMessage(count: Int, running: Int, master: Bool) -> String {
    let base =
      count == 1
      ? "Excluir a sessão selecionada e todas as suas sessões filhas? Isso exclui permanentemente suas mensagens e não pode ser desfeito."
      : "Excluir as \(count) sessões selecionadas e todas as suas sessões filhas? Isso exclui permanentemente suas mensagens e não pode ser desfeito."
    let runningNotice =
      running == 0 ? nil
      : running == 1 ? "1 sessão está trabalhando e será interrompida."
      : "\(running) sessões estão trabalhando e serão interrompidas."
    // Same wording as the web's `session.delete.master` (ea4a54f3317).
    let masterNotice =
      master
      ? "Esta é a Sessão mestra do iPhone. Excluir apaga o histórico definitivamente; uma nova, vazia, é criada no próximo acesso."
      : nil
    return ([base, runningNotice, masterNotice].compactMap { $0 } + ["Para manter o histórico, arquive em vez de excluir."])
      .joined(separator: "\n\n")
  }

  public static func done(_ count: Int, archived: Bool) -> String {
    let verb = archived ? "arquivada" : "excluída"
    return count == 1 ? "1 sessão \(verb)" : "\(count) sessões \(verb)s"
  }

  public static func failure(_ result: SessionBulkResult) -> String {
    let failed = result.failed.count == 1 ? "1 falhou" : "\(result.failed.count) falharam"
    let done = result.succeeded.count == 1 ? "1 concluída" : "\(result.succeeded.count) concluídas"
    return "\(done); \(failed). As que falharam continuam selecionadas."
  }
}
