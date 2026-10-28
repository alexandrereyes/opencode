import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// A window-local Spotlight-style child panel. Opening only snapshots the already loaded catalog.
@MainActor final class MacModelPalette {
  private(set) var panel: NSPanel?
  private(set) var state: MacModelPaletteState?
  private var monitor: Any?
  private var resize: NSObjectProtocol?
  private weak var previous: NSResponder?
  private var restore: (() -> Void)?

  func open(runtime: MacWindowRuntime, conversation: ConversationStore, draft: ConversationDraft, theme: AppTheme) {
    guard let sessions = runtime.store else { return }
    open(window: runtime.window, sessions: sessions, models: conversation.displayModels,
      providers: conversation.providers, current: conversation.selectedModel(draft), theme: theme,
      restore: { draft.focusSuppressed = false; draft.focused = true }) { model in draft.model = model }
    draft.focused = false
    draft.focusSuppressed = true
  }

  func open(window: NSWindow?, sessions: SessionStore, models: [ModelInfo], providers: [ProviderInfo],
    current: ModelReference?, theme: AppTheme, restore: @escaping () -> Void, apply: @escaping (ModelReference) -> Void) {
    guard let window else { return }
    close()
    let start = ContinuousClock.now
    let parent = window.attachedSheet ?? window
    previous = parent.firstResponder
    self.restore = restore
    let state = MacModelPaletteState(sessions: sessions,
      models: ModelCatalog.merging(models, fallback: sessions.catalog.models), providers: providers, current: current)
    self.state = state
    state.dismiss = { [weak self] in self?.close() }
    state.apply = { [weak self] model, remember in
      apply(model)
      sessions.catalog.committed(model)
      self?.close()
      if remember {
        Task {
          do { try await sessions.rememberNewSessionModel(model) }
          catch { sessions.toast.show("Não foi possível guardar o modelo como padrão para novas sessões.", kind: .error) }
        }
      }
    }
    let frame = window.convertToScreen(window.contentLayoutRect)
    let panel = MacModelPalettePanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    panel.identifier = NSUserInterfaceItemIdentifier("mac-model-palette")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.worksWhenModal = true
    let paletteTheme = theme.dark ? theme : AppTheme.load(theme.id.replacingOccurrences(of: "-light", with: "-dark"))
    panel.contentView = NSHostingView(rootView: MacModelPaletteView(state: state).environment(\.appTheme, paletteTheme))
    self.panel = panel
    parent.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    resize = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
      [weak panel, weak window] _ in
      MainActor.assumeIsolated {
        guard let window else { return }
        panel?.setFrame(window.convertToScreen(window.contentLayoutRect), display: true)
      }
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
      guard let self, event.window === panel, let state = self.state else { return event }
      return state.key(event) ? nil : event
    }
    #if DEBUG
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
    print("MacPalette open \(start.duration(to: .now)) · \(state.rows.count) modelos · cache, zero reloads")
    #endif
  }

  func close() {
    if let resize { NotificationCenter.default.removeObserver(resize) }
    resize = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    let parent = panel?.parent
    if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
    panel = nil
    state = nil
    parent?.makeKey()
    if let previous { parent?.makeFirstResponder(previous) }
    previous = nil
    let restore = restore
    self.restore = nil
    restore?()
  }
}

private final class MacModelPalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor @Observable final class MacModelPaletteState {
  let sessions: SessionStore
  let models: [ModelInfo]
  let providers: [ProviderInfo]
  let current: ModelReference?
  let recent: [ModelReference]
  var favorites: Set<String>
  var query = "" { didSet { rebuild() } }
  private(set) var rows: [ModelPalette.Row] = []
  var selected: String?
  var efforts: [String: String] = [:]
  var dismiss: () -> Void = {}
  var apply: (ModelReference, Bool) -> Void = { _, _ in }

  init(sessions: SessionStore, models: [ModelInfo], providers: [ProviderInfo], current: ModelReference?) {
    self.sessions = sessions
    self.models = models
    self.providers = providers
    self.current = current
    recent = ModelPaletteMemory(server: sessions.client.configuration.url.absoluteString).recent
    favorites = Set(models.filter { ConversationProjection.favorite($0, preferences: sessions.preferences?.data.models) }.map(\.identity))
    rebuild()
  }

  func rebuild() {
    rows = ModelPalette.rows(models: models, preferences: sessions.preferences?.data.models, providers: providers,
      favorites: favorites, recent: recent, query: query)
    if !rows.contains(where: { $0.id == selected }) { selected = rows.first?.id }
  }

  func effort(_ info: ModelInfo) -> String {
    efforts[info.identity] ?? ModelPalette.effort(info, current: current, saved: sessions.preferences?.data.models?.variant[info.identity])
  }

  func use(_ info: ModelInfo, effort: String? = nil, remember: Bool = false) {
    apply(ModelReference(id: info.id, providerID: info.providerID, variant: effort ?? self.effort(info)), remember)
  }

  func favorite(_ info: ModelInfo) {
    let value = !favorites.contains(info.identity)
    if value { favorites.insert(info.identity) } else { favorites.remove(info.identity) }
    rebuild()
    Task {
      await sessions.mutate(.modelFavorite(providerID: info.providerID, modelID: info.id, favorite: value))
      favorites = Set(models.filter { ConversationProjection.favorite($0, preferences: sessions.preferences?.data.models) }.map(\.identity))
      rebuild()
    }
  }

  func key(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { dismiss(); return true }
    guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return false }
    let index = rows.firstIndex { $0.id == selected } ?? 0
    if event.keyCode == 125 || event.keyCode == 126 {
      guard !rows.isEmpty else { return true }
      selected = rows[min(max(index + (event.keyCode == 125 ? 1 : -1), 0), rows.count - 1)].id
      return true
    }
    guard rows.indices.contains(index) else { return false }
    let info = rows[index].model
    if event.keyCode == 123 || event.keyCode == 124 {
      let values = ModelPalette.efforts(info)
      let current = values.firstIndex(of: effort(info)) ?? 0
      efforts[info.identity] = values[min(max(current + (event.keyCode == 124 ? 1 : -1), 0), values.count - 1)]
      return true
    }
    if event.keyCode == 36 || event.keyCode == 76 { use(info, remember: event.modifierFlags.contains(.command)); return true }
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" {
      favorite(info); return true
    }
    return false
  }
}

private struct MacModelPaletteView: View {
  @Environment(\.appTheme) private var theme
  @Bindable var state: MacModelPaletteState
  var body: some View {
    ZStack {
      Color.black.opacity(0.25).onTapGesture { state.dismiss() }
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "sparkles").foregroundStyle(theme.color(.primary))
          MacPaletteField(query: $state.query, placeholder: state.current.flatMap { ref in
            state.models.first { $0.id == ref.id && $0.providerID == ref.providerID }?.name
          } ?? "Buscar modelo", theme: theme).frame(height: 32)
          Button { state.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)) }
            .buttonStyle(.plain).help("Fechar (Esc)")
        }
        .font(.system(size: 24)).padding(18)
        .background(theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(theme.color(.primary), lineWidth: 1) }
        .padding(16)
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 3) {
              ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                if state.query.isEmpty && (index == 0 || state.rows[index - 1].group != row.group) {
                  Text(row.group.uppercased()).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color(.textSecondary)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                }
                line(row).id(row.id)
              }
              if state.rows.isEmpty {
                Text(state.models.isEmpty ? "Catálogo ainda carregando…" : "Nenhum modelo visível encontrado. Gerencie os modelos nos Ajustes.")
                  .foregroundStyle(theme.color(.textSecondary)).padding(24)
              }
            }.padding(.horizontal, 12).padding(.bottom, 12)
          }.frame(height: min(380, max(130, CGFloat(state.rows.count) * 58 + (state.query.isEmpty ? 90 : 0))))
            .onChange(of: state.selected) { _, id in if let id { proxy.scrollTo(id) } }
        }
        Divider()
        Text("↩ usar · ←→ esforço · ⌘↩ usar e lembrar como padrão · esc fechar")
          .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary)).padding(15)
      }
      .frame(maxWidth: 790).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.border), lineWidth: 1) }
      .shadow(color: .black.opacity(0.35), radius: 28, y: 12).padding(24)
      .environment(\.colorScheme, .dark)
    }
    .foregroundStyle(theme.color(.textStrong))
    .accessibilityIdentifier("model-palette")
  }

  private func line(_ row: ModelPalette.Row) -> some View {
    HStack(spacing: 10) {
      Button { state.favorite(row.model) } label: {
        Image(systemName: row.favorite ? "star.fill" : "sparkles")
          .foregroundStyle(theme.color(row.favorite ? .primary : .textSecondary)).frame(width: 20)
      }.buttonStyle(.plain).help(row.favorite ? "Desfavoritar (⌘D)" : "Favoritar (⌘D)")
      Button { state.use(row.model) } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(highlight(row)).font(.system(size: 14)).lineLimit(1)
          Text((state.providers.first { $0.id == row.model.providerID }?.name ?? row.model.providerID)
            + " · " + ContextUsage.compact(row.model.limit.context))
            .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
      HStack(spacing: 4) {
        ForEach(ModelPalette.efforts(row.model), id: \.self) { value in
          Button { state.use(row.model, effort: value) } label: {
            Text(ModelPalette.label(value)).font(.system(size: 11, weight: .medium))
              .frame(minWidth: 23, minHeight: 27).padding(.horizontal, 3)
              .foregroundStyle(theme.color(state.effort(row.model) == value ? .background : .text))
              .background(state.effort(row.model) == value ? theme.color(.primary) : .clear, in: RoundedRectangle(cornerRadius: 7))
              .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color(.border), lineWidth: 0.7) }
          }.buttonStyle(.plain).help(value == "default" ? "Padrão do modelo" : value)
            .accessibilityLabel("\(row.model.name), esforço \(value)")
        }
      }
    }
    .padding(10).background(state.selected == row.id ? theme.color(.highlight) : .clear, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .contain).accessibilityAddTraits(state.selected == row.id ? .isSelected : [])
  }

  private func highlight(_ row: ModelPalette.Row) -> AttributedString {
    var text = AttributedString(row.model.name)
    for range in row.matches {
      if let lower = AttributedString.Index(range.lowerBound, within: text),
        let upper = AttributedString.Index(range.upperBound, within: text) { text[lower..<upper].font = .system(size: 14, weight: .bold) }
    }
    return text
  }
}

/// A detached AppKit panel cannot rely on SwiftUI FocusState's scene election (in particular while locked).
/// Its native field explicitly owns first responder, just as Spotlight's search does.
private struct MacPaletteField: NSViewRepresentable {
  @Binding var query: String
  let placeholder: String
  let theme: AppTheme
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Field {
    let field = Field()
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 24)
    field.delegate = context.coordinator
    field.setAccessibilityIdentifier("model-palette-search")
    field.setAccessibilityLabel("Buscar modelo")
    return field
  }
  func updateNSView(_ field: Field, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != query { field.stringValue = query }
    field.placeholderString = placeholder
    field.textColor = theme.nsColor(.textStrong)
    field.appearance = NSAppearance(named: .darkAqua)
  }
  final class Field: NSTextField {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.initialFirstResponder = self
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, self.window === window else { return }
        window?.makeFirstResponder(self)
      }
    }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: MacPaletteField
    init(_ parent: MacPaletteField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.query = field.stringValue
    }
  }
}

extension MacWindowRuntime {
  func openModelPalette(theme: AppTheme = .selected) {
    if let newSessionPalette { newSessionPalette(); return }
    guard let id = selection.childID ?? selection.sessionID, let store else { return }
    let conversation = store.conversation(id, master: selection.master && selection.childID == nil)
    modelPalette.open(runtime: self, conversation: conversation, draft: input(conversation).draft, theme: theme)
  }
}
