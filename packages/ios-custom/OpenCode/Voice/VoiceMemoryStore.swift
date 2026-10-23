import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class VoiceMemoryStore {
  private(set) var context = VoiceMemoryContext()
  private(set) var pending = 0
  private(set) var status: VoiceMemoryStatus = .offline
  private(set) var localError = false
  @ObservationIgnored private let service: VoiceMemoryService
  @ObservationIgnored private var syncing: Task<Void, Never>?
  #if DEBUG
  private(set) var isPreview = false
  #endif

  init(client: OpenCodeClient, root: URL? = nil) {
    service = VoiceMemoryService(client: client,
      buffer: VoiceMemoryBuffer(server: client.configuration.url.absoluteString, root: root))
  }
  func prepare() async -> VoiceMemoryContext? {
    #if DEBUG
    if isPreview { return context }
    #endif
    resume()
    let history = await service.prepare()
    await update()
    return history
  }
  func capture(_ turn: VoiceMemoryTurn) async {
    do { try await service.buffer.append(turn); await update(); resume() }
    catch { localError = true }
  }
  func finish(_ callID: UUID) async {
    do { try await service.buffer.end(callID.uuidString); await update(); resume() }
    catch { localError = true }
  }
  func resume() {
    #if DEBUG
    if isPreview { return }
    #endif
    guard syncing == nil else { return }
    syncing = Task { [weak self] in
      guard let self else { return }
      defer { syncing = nil }
      var delay = 3
      while !Task.isCancelled {
        await update()
        if pending == 0 { return }
        let complete = await service.flush()
        if complete { _ = await service.prepare() }
        await update()
        if status == .unsupported || (complete && pending == 0) { return }
        if complete { delay = 3; continue }
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        delay = min(30, delay * 2)
      }
    }
  }
  func stop() async {
    syncing?.cancel()
    await service.cancel()
    await syncing?.value
    syncing = nil
  }
  private func update() async {
    do {
      let snapshot = try await service.buffer.snapshot()
      context = snapshot.context; pending = snapshot.pending.count
      status = await service.status
    } catch { localError = true }
  }

  #if DEBUG
  func preview() {
    isPreview = true
    context = VoiceMemoryContext(summary: "Alexandre prefere respostas curtas e está acompanhando uma tarefa.", turns: [
      .init(id: "preview-user", role: .user, text: "Confira a sessão de demonstração.", at: 1_792_760_000_000),
      .init(id: "preview-assistant", role: .assistant, text: "Vou conferir e resumir o resultado.", at: 1_792_760_001_000, interrupted: true),
    ], truncated: true)
    status = .available
  }
  func previewUpdate() {
    context.turns.append(.init(id: "preview-live-\(context.turns.count)", role: .assistant,
      text: "Atualização local recebida durante a chamada.", at: 1_792_760_002_000))
  }
  #endif
}
