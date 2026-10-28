#if DEBUG
import AppKit
import OpenCodeKit

/// Checks the production palette/rail/navigation in the closed fixture, including real AppKit key dispatch.
@MainActor enum MacChoicesChecks {
  static func run(_ runtime: MacWindowRuntime) async -> String? {
    guard let store = runtime.store, let window = runtime.window else { return "escolhas sem janela" }
    let original = runtime.selection
    let filter = store.filter
    let project = store.selectedProject
    defer {
      runtime.modelPalette.close()
      runtime.selection = original
      store.filter = filter
      store.selectedProject = project
    }
    runtime.selection = MacSelection(sessionID: MacFixture.rootID)
    try? await Task.sleep(for: .milliseconds(400))
    let reads = await MacChoicesFixture.shared.catalogReads
    runtime.openModelPalette()
    guard let state = runtime.modelPalette.state, let panel = runtime.modelPalette.panel, panel.isVisible,
      state.rows.count > 0 else { return "paleta não abriu do cache" }
    let frame = window.convertToScreen(window.contentLayoutRect)
    guard abs(frame.midX - panel.frame.midX) < 1, abs(frame.midY - panel.frame.midY) < 1 else { return "paleta fora do centro" }
    try? await Task.sleep(for: .milliseconds(200))
    func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
      guard let panel = runtime.modelPalette.panel else { return }
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
      NSApp.sendEvent(event)
    }
    guard let first = state.rows.first else { return "paleta vazia" }
    guard let editor = panel.firstResponder as? NSTextView else { return "campo da paleta sem foco nativo" }
    let query = first.model.name.prefix(3).lowercased()
    editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    try? await Task.sleep(for: .milliseconds(100))
    guard state.query == query else { return "digitação não atualizou a paleta" }
    guard state.rows.contains(where: { $0.id == first.id }) else { return "busca de modelo perdeu resultado" }
    if state.rows.count > 1 {
      key(125)
      guard state.selected == state.rows[1].id else { return "↓ não navegou" }
      key(126)
      guard state.selected == state.rows[0].id else { return "↑ não navegou" }
    }
    let effort = state.effort(first.model)
    key(123)
    if ModelPalette.efforts(first.model).count > 1, effort != "default", state.effort(first.model) == effort {
      return "← não mudou o esforço"
    }
    key(124)
    guard ModelPalette.efforts(first.model).contains(state.effort(first.model)) else { return "esforço inválido" }
    try? await Task.sleep(for: .milliseconds(200))
    guard await MacChoicesFixture.shared.catalogReads == reads else { return "abrir paleta recarregou catálogo" }
    if let folder = MacCapture.folder { MacCapture.shot(window, theme: .selected, to: folder + "/paleta.png") }
    let previousDefault = store.preferences?.data.models?.default?.modelID
    key(36)
    guard runtime.modelPalette.panel == nil,
      runtime.input(store.conversation(MacFixture.rootID)).draft.model?.id == first.model.id else { return "Return não aplicou o modelo" }
    guard store.preferences?.data.models?.default?.modelID == previousDefault else { return "Return simples alterou o padrão" }
    runtime.openModelPalette()
    guard let favoriteState = runtime.modelPalette.state else { return "paleta não reabriu" }
    if MacChoicesFixture.enabled, let row = favoriteState.rows.first {
      let wasFavorite = favoriteState.favorites.contains(row.id)
      key(2, .command, "d")
      try? await Task.sleep(for: .milliseconds(200))
      guard ConversationProjection.favorite(row.model, preferences: store.preferences?.data.models) != wasFavorite else {
        return "favorito não persistiu nas preferências"
      }
      key(2, .command, "d")
      try? await Task.sleep(for: .milliseconds(200))
      favoriteState.efforts[row.id] = "high"
      key(36, .command, "\r")
      try? await Task.sleep(for: .milliseconds(200))
      guard store.preferences?.data.models?.default?.modelID == row.model.id,
        store.preferences?.data.models?.default?.variant == "high" else { return "usar e lembrar não salvou padrão" }
      runtime.openModelPalette()
    }
    guard runtime.modelPalette.state != nil else { return "paleta não reabriu após padrão" }
    key(53)
    guard runtime.modelPalette.panel == nil else { return "Esc não fechou a paleta" }
    store.filter = .running
    MacProjectRail.select(ChipManualOrder.chats, store: store)
    guard store.chatsSelected, store.filter == .running else { return "trilho perdeu o filtro de estado" }
    MacProjectRail.select(ChipManualOrder.chats, store: store)
    guard store.selectedProject == nil else { return "trilho não alternou Chats" }
    guard let repository = store.selectedProjects.first else { return "fixture sem repositórios" }
    MacProjectRail.select(repository.project.id, store: store)
    guard store.selectedProject == repository.project.id else { return "trilho não selecionou projeto" }
    MacProjectRail.select(nil, store: store)
    guard store.filter == .all, store.selectedProject == nil else { return "Todas não limpou filtros" }
    try? await Task.sleep(for: .milliseconds(200))
    if let folder = MacCapture.folder { MacCapture.shot(window, theme: .selected, to: folder + "/trilho.png") }
    runtime.selection.childID = "ses_mac_c1"
    for _ in 0..<30 {
      if store.liveConversation("ses_mac_c1")?.hasTranscript == true { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard runtime.selection.sessionID == MacFixture.rootID, runtime.selection.childID == "ses_mac_c1",
      store.liveConversation("ses_mac_c1")?.session?.parentID == MacFixture.rootID else { return "subagente não abriu sobre a mãe" }
    try? await Task.sleep(for: .milliseconds(300))
    if let folder = MacCapture.folder { MacCapture.shot(window, theme: .selected, to: folder + "/subagente.png") }
    runtime.backToParent()
    guard runtime.selection.childID == nil else { return "voltar não removeu a filha" }
    print("MacStress escolhas: paleta, busca, setas, Return, Esc, trilho, filtros, subagente e volta ok · esforço inicial \(effort)")
    return nil
  }

  static func newSession(_ runtime: MacWindowRuntime) async -> String? {
    guard runtime.newSessionPalette != nil else { return "Nova sessão não registrou sua paleta" }
    runtime.openModelPalette()
    guard runtime.modelPalette.panel?.isVisible == true else { return "paleta não abriu na Nova sessão" }
    if let folder = MacCapture.folder, let window = runtime.window {
      runtime.modelPalette.panel?.contentView?.layoutSubtreeIfNeeded()
      MacCapture.shot(window, theme: .selected, to: folder + "/nova-sessao-paleta.png")
    }
    if MacChoicesFixture.enabled, let state = runtime.modelPalette.state,
      let other = state.rows.first(where: { $0.model.id != state.current?.id }) {
      let conversation = runtime.store.map { runtime.input($0.conversation(MacFixture.rootID)).draft.model }
      let saved = runtime.store?.preferences?.data.models?.default?.modelID
      state.use(other.model)
      runtime.openModelPalette()
      guard runtime.modelPalette.state?.current?.id == other.model.id,
        runtime.store.map({ runtime.input($0.conversation(MacFixture.rootID)).draft.model }) == conversation,
        runtime.store?.preferences?.data.models?.default?.modelID == saved else {
        return "paleta da Nova sessão alterou a conversa ou o padrão"
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    runtime.modelPalette.close()
    print("MacStress escolhas Nova sessão: seleção independente sem alterar padrão ok")
    return nil
  }
}
#endif
