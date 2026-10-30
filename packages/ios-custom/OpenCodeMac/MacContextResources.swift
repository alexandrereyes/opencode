import AppKit
import OpenCodeKit
import SwiftUI

/// `RECURSOS N · K ligados` as a stage (approved option B, 30/10; `.agent-artifacts/recursos-ao-vivo/opcao-b-palco.png`):
/// one ligado resource large with its live video (the resource window's frame and pointer surface, so Assumir
/// controle works there under the same rules), its state, `agora: …` and the commands an agent ran on it; the other
/// ligados as thumbnails at about one frame a second beside it (below it when narrow); the stopped ones as chips with
/// `+N ›` and Limpar parados. "Seguir o agente" puts on the stage what an agent uses now (`ResourceStage`); a click on
/// a thumbnail turns it off. Every stream stops while the window is hidden or the column closed.
struct MacResourcesSection: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: ContextColumnStore
  let runtime: MacWindowRuntime
  @State private var wide = true
  @State private var visible = true

  var body: some View {
    let on = ResourceStage.on(store.resources)
    let off = ResourceStage.off(store.resources)
    let split = ResourceStage.split(on, stage: store.stageID)
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Recursos",
        count: "\(store.resources.count) · \(on.count) \(on.count == 1 ? "ligado" : "ligados")") {
        if !on.isEmpty { followToggle }
      }
      .padding(.bottom, 10)
      if let stage = split.stage {
        let layout = wide && !split.others.isEmpty
          ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
          MacResourceStage(resource: stage, store: store, wide: wide, visible: visible, actions: actions(stage))
            .id(stage.id)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !split.others.isEmpty { thumbnails(split.others) }
        }
      } else {
        Text("Nenhum recurso ligado agora.").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          .padding(.bottom, 4)
      }
      if !off.isEmpty {
        ContextHairline().padding(.vertical, 12)
        chips(off)
      }
    }
    .onGeometryChange(for: Bool.self) { $0.size.width >= 600 } action: { wide = $0 }
    .onChange(of: split.stage?.id, initial: true) { _, id in store.stageCurrent = id }
    // A minimized or fully covered window draws nothing: every stream pauses until it shows again.
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
      guard let window = note.object as? NSWindow, window === runtime.window else { return }
      visible = shown(window)
    }
    .onAppear { visible = runtime.window.map(shown) ?? true }
    .confirmationDialog("Limpar \(off.count) recursos parados?", isPresented: $store.clearingStopped) {
      Button("Limpar", role: .destructive) { Task { await store.dismissStopped() } }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("Eles saem da lista e voltam se um agente usar de novo.")
    }
    #if DEBUG
    .onChange(of: wide, initial: true) { _, value in MacResourcesProbe.wide = value }
    .onChange(of: store.stageFollowing, initial: true) { _, value in MacResourcesProbe.following = value }
    #endif
  }

  private func shown(_ window: NSWindow) -> Bool {
    #if DEBUG
    if let forced = MacResourcesProbe.forcedVisible { return forced }
    #endif
    return window.occlusionState.contains(.visible)
  }

  private var followToggle: some View {
    Button {
      store.follow(!store.stageFollowing)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: store.stageFollowing ? "checkmark" : "circle").font(.system(size: 10, weight: .bold))
          .foregroundStyle(theme.color(store.stageFollowing ? .primary : .icon))
        Text("Seguir o agente")
      }
      .appFont(.caption).foregroundStyle(theme.color(store.stageFollowing ? .text : .textSecondary))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(store.stageFollowing ? "O palco mostra o recurso que um agente está usando" : "Seguir o agente de novo")
    .accessibilityIdentifier("resources-follow")
  }

  private func thumbnails(_ others: [SessionResource]) -> some View {
    let layout = wide ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout {
      ForEach(others) { resource in
        MacResourceThumbnail(resource: resource, client: store.client, visible: visible, wide: wide,
          actions: actions(resource)) { store.choose(resource) }
        .id(resource.id)
      }
    }
    .frame(width: wide ? 190 : nil, alignment: .leading)
  }

  private func chips(_ off: [SessionResource]) -> some View {
    let chips = ResourceStage.chips(off, limit: wide ? 8 : 5, all: store.stoppedExpanded)
    return MCPFlowLayout(spacing: 6, centered: false) {
      ForEach(chips.shown) { resource in MacResourceChip(resource: resource, actions: actions(resource)) }
      if chips.more > 0 || store.stoppedExpanded {
        Button {
          store.stoppedExpanded.toggle()
        } label: {
          Text(store.stoppedExpanded ? "Mostrar menos" : "+\(chips.more) ›").appFont(.caption)
            .foregroundStyle(theme.color(.text)).padding(.horizontal, 9).padding(.vertical, 4)
            .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("resources-more")
      }
      Button("Limpar parados") { store.clearingStopped = true }
        .buttonStyle(.plain).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        .padding(.vertical, 4).padding(.leading, 4)
        .disabled(store.acting.contains("stopped"))
        .help("Encerrar todos os recursos parados (voltam se um agente usar de novo)")
        .accessibilityIdentifier("resources-clear")
    }
    #if DEBUG
    .onChange(of: chips.shown.map(\.id), initial: true) { _, ids in
      MacResourcesProbe.chips = ids
      MacResourcesProbe.more = chips.more
    }
    #endif
  }

  private func actions(_ resource: SessionResource) -> MacResourceActions {
    MacResourceActions(
      open: { openWindow(id: "resource", value: resource.id) },
      capture: { MacResourceCapture.save(resource, client: store.client, toast: store.sessions.toast) },
      close: { Task { await store.dismiss(resource) } })
  }
}

/// The resource on the stage: its live video and, beside it (below it when narrow or landscape), its title, state,
/// `agora: …`, its latest commands and the actions. In use now, the title shimmers and the video gets a live orange
/// outline; in control (Assumir controle) a click is a touch and the keyboard types into it, as in its window.
private struct MacResourceStage: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.macStillCapture) private var still
  let resource: SessionResource
  let store: ContextColumnStore
  let wide: Bool
  let visible: Bool
  let actions: MacResourceActions
  @State private var model: ResourceViewerModel

  init(resource: SessionResource, store: ContextColumnStore, wide: Bool, visible: Bool, actions: MacResourceActions) {
    self.resource = resource
    self.store = store
    self.wide = wide
    self.visible = visible
    self.actions = actions
    _model = State(initialValue: ResourceViewerModel(resource: resource, client: store.client))
  }

  private var using: Bool { resource.state == .agent }

  var body: some View {
    // A portrait screen keeps its details beside it in a wide panel; a landscape page puts them below.
    let beside = wide && resource.kind != .chrome
    let layout = beside ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
    layout {
      MacResourceVideo(model: model, height: beside ? 420 : 300, highlight: using || model.inControl, interactive: true)
      details
    }
    .task {
      model.decodeMaxPixels = 1_000
      model.start()
      if !visible { model.suspend() }
    }
    .onDisappear {
      model.finish()
      store.stageControlling = false
    }
    .onChange(of: visible) { _, shown in shown ? model.resume() : model.suspend() }
    .onChange(of: model.inControl) { _, value in store.stageControlling = value }
    .contextMenu { MacResourceMenu(resource: resource, actions: actions) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("resource-stage-" + resource.id)
    #if DEBUG
    .onAppear {
      MacResourcesProbe.stage = resource.id
      MacResourcesProbe.stageModel = model
    }
    .onDisappear { if MacResourcesProbe.stage == resource.id { MacResourcesProbe.stage = nil } }
    #endif
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 5) {
      title
      HStack(spacing: 6) {
        dot
        Text(ResourceStage.status(resource, session: store.session?.displayTitle, subagent: subagent, now: now))
          .foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.middle)
      }
      .appFont(.caption)
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        Text(line).appFont(.caption).monospacedDigit()
          .foregroundStyle(theme.color(index == 0 && line.hasPrefix("agora") ? .text : .textWeak))
          .lineLimit(1).truncationMode(.tail)
      }
      // Narrow, or wide without room for every word, only control keeps its words; the others are icons with their
      // names in the tooltip. Shrinking keeps the wide layout under its 600-pt threshold: otherwise a narrowed column
      // would stay wide (and overflow) with an iPhone beside its details.
      ViewThatFits(in: .horizontal) {
        if wide { controls(compact: false) }
        controls(compact: true)
      }
      .padding(.top, 8)
      if let text = model.failure ?? model.notice {
        Text(text).appFont(.footnote).foregroundStyle(theme.color(.textSecondary)).lineLimit(2).padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var title: some View {
    let text = ContextColumn.title(resource)
    if using, !reduceMotion, !still {
      MacShimmerText(text: text, font: .systemFont(ofSize: AppTextStyle.body.size, weight: .semibold),
        base: theme.nsColor(.textSecondary), peak: theme.nsColor(.textStrong))
        .accessibilityLabel(text)
    } else {
      Text(text).appFont(.body, weight: .semibold).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
    }
  }

  @ViewBuilder private var dot: some View {
    switch resource.state {
    case .user: Circle().fill(theme.color(.primary)).frame(width: 6, height: 6)
    case .agent, .live: Circle().fill(theme.color(.success)).frame(width: 6, height: 6)
    default: Circle().strokeBorder(theme.color(.textSecondary), lineWidth: 1).frame(width: 7, height: 7)
    }
  }

  /// The subagent that used it, by its title; nil when the shown session itself did.
  private var subagent: String? {
    ContextColumn.user(of: resource, rootID: store.id, members: store.members).flatMap(store.title)
  }

  /// `agora: …` (its command still running, else the subagent's current tool while it uses the resource), then the
  /// latest commands.
  private var lines: [String] {
    let history = ResourceStage.history(resource, now: now)
    guard using, history.first?.hasPrefix("agora") != true,
      let owner = resource.owner?.sessionID, let activity = store.activities[owner] else { return history }
    return Array((["agora: " + activity] + history).prefix(3))
  }

  private func controls(compact: Bool) -> some View {
    HStack(spacing: compact ? 12 : 16) {
      action("macwindow", "Abrir janela", compact: compact, actions.open)
      action(model.inControl ? "hand.raised.slash" : "hand.tap", model.inControl ? "Devolver controle" : "Assumir controle",
        tone: .primary, compact: false) {
        Task { model.inControl ? await model.giveBack() : await model.takeControl() }
      }
      .disabled(model.busy || !resource.live.input || model.holder == .elsewhere)
      .help(resource.live.input ? "Clique e teclado vão para o recurso; o agente espera até você devolver"
        : "Este recurso não aceita controle")
      .accessibilityIdentifier("resource-stage-control")
      action("camera", "Captura", compact: compact, actions.capture)
      action("xmark.circle", "Encerrar", compact: compact, actions.close)
        .help("Encerrar (tira da lista; volta se um agente usar de novo)")
    }
  }

  private func action(_ symbol: String, _ title: String, tone: ThemeRole = .text, compact: Bool,
    _ run: @escaping () -> Void) -> some View
  {
    Button(action: run) {
      Label(title, systemImage: symbol).labelStyle(MacResourceActionStyle(compact: compact)).appFont(.caption)
        .foregroundStyle(theme.color(tone)).lineLimit(1).fixedSize().contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}

/// An action's icon and words, or the icon alone (narrow).
private struct MacResourceActionStyle: LabelStyle {
  let compact: Bool
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon
      if !compact { configuration.title }
    }
  }
}

/// Another ligado resource: its video at about one frame a second, its name and state. A click puts it on the stage.
private struct MacResourceThumbnail: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let resource: SessionResource
  let visible: Bool
  let wide: Bool
  let actions: MacResourceActions
  let choose: () -> Void
  @State private var model: ResourceViewerModel

  init(resource: SessionResource, client: OpenCodeClient, visible: Bool, wide: Bool, actions: MacResourceActions,
    choose: @escaping () -> Void)
  {
    self.resource = resource
    self.visible = visible
    self.wide = wide
    self.actions = actions
    self.choose = choose
    _model = State(initialValue: ResourceViewerModel(resource: resource, client: client))
  }

  var body: some View {
    Button(action: choose) {
      VStack(alignment: .leading, spacing: 5) {
        MacResourceVideo(model: model, height: wide ? 130 : 96, highlight: resource.state == .agent, interactive: false)
        Text(ContextColumn.name(resource)).appFont(.caption, weight: .medium).foregroundStyle(theme.color(.text))
          .lineLimit(1).truncationMode(.middle)
        Text(ResourceStage.status(resource, session: nil, subagent: nil, now: now)).appFont(.footnote)
          .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
      }
      .frame(maxWidth: wide ? 190 : 150, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Pôr no palco")
    .contextMenu { MacResourceMenu(resource: resource, actions: actions) }
    .task {
      model.pace = .seconds(1)
      model.decodeMaxPixels = 400
      model.start()
      if !visible { model.suspend() }
    }
    .onDisappear { model.finish() }
    .onChange(of: visible) { _, shown in shown ? model.resume() : model.suspend() }
    .accessibilityIdentifier("resource-thumbnail-" + resource.id)
    #if DEBUG
    .onAppear { MacResourcesProbe.thumbnails[resource.id] = model }
    .onDisappear { MacResourcesProbe.thumbnails[resource.id] = nil }
    #endif
  }
}

/// The live frame at its upright proportions, at most `height` tall; `interactive` adds the pointer and keyboard
/// surface of the resource window. Frames go straight to a layer (`MacResourceFrameLayer`): this view reads only the
/// stream's size and rotation, so a new frame re-renders nothing in SwiftUI.
private struct MacResourceVideo: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.macStillCapture) private var still
  let model: ResourceViewerModel
  let height: CGFloat
  let highlight: Bool
  let interactive: Bool

  var body: some View {
    // Before the stream's `hello`, a page is landscape and a device portrait.
    let frame = model.hello.map { CGSize(width: $0.width, height: $0.height) }
      ?? (model.resource.kind == .chrome ? CGSize(width: 16, height: 10) : CGSize(width: 9, height: 19.5))
    let rotation = model.rotation
    let ratio = rotation % 180 != 0 ? frame.height / max(frame.width, 1) : frame.width / max(frame.height, 1)
    ZStack {
      // A turned simulator (landscape) and ImageRenderer's stills keep the window's SwiftUI frame view.
      if rotation == 0, !still { MacResourceFrameLayer(model: model) } else { ResourceFrameView(model: model) }
      if interactive, !still {
        ResourceTouchOverlay(model: model, contentSize: frame, indicator: theme.nsColor(.primary))
      }
    }
    .aspectRatio(ratio, contentMode: .fit)
    .frame(maxHeight: height)
    .background(theme.color(.surface))
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(highlight ? theme.color(.primary) : theme.color(.textSecondary).opacity(0.35),
          lineWidth: highlight ? 1.5 : 1)
        .allowsHitTesting(false)
    }
    .shadow(color: highlight ? theme.color(.primary).opacity(0.35) : .clear, radius: 7)
  }
}

/// Draws the model's frames on a layer as they are decoded (`ResourceViewerModel.onFrame`), aspect-fit.
private struct MacResourceFrameLayer: NSViewRepresentable {
  let model: ResourceViewerModel

  func makeNSView(context: Context) -> FrameView {
    let view = FrameView()
    view.show(model.lastFrame)
    model.onFrame = { [weak view] image in view?.show(image) }
    return view
  }

  func updateNSView(_ view: FrameView, context: Context) {}

  final class FrameView: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer?.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ image: CGImage?) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contents = image
      CATransaction.commit()
    }
  }
}

/// A stopped resource: `iPhone 17 Pro · 2 min` in a hairline capsule. A click opens its window (its last state);
/// right-click has Encerrar.
private struct MacResourceChip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let resource: SessionResource
  let actions: MacResourceActions

  var body: some View {
    Button(action: actions.open) {
      HStack(spacing: 5) {
        Image(systemName: resourceSymbol(resource.kind)).font(.system(size: 9)).foregroundStyle(theme.color(.icon))
        Text(ResourceStage.chip(resource, now: now)).appFont(.caption).monospacedDigit()
          .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
      }
      .padding(.horizontal, 9).padding(.vertical, 4)
      .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 1) }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(ContextColumn.title(resource) + " · " + resource.state.label)
    .contextMenu { MacResourceMenu(resource: resource, actions: actions) }
    .accessibilityIdentifier("resource-chip-" + resource.id)
  }
}

#if DEBUG
/// What the section drew, for `MacAjustesChecks`: its background test copy has no accessibility tree to read.
@MainActor enum MacResourcesProbe {
  static var stage: String?
  static weak var stageModel: ResourceViewerModel?
  static var thumbnails: [String: ResourceViewerModel] = [:]
  static var chips: [String] = []
  static var more = 0
  static var wide = true
  static var following = true
  /// `-OpenCodeMacResourceProfile visible`: an off-screen test window counts as shown, to measure the streams'
  /// cost; a check sets false (then posts the occlusion notification) to see them pause.
  static var forcedVisible: Bool? = MacFixture.value("-OpenCodeMacResourceProfile") == "visible" ? true : nil
}
#endif

struct MacResourceActions {
  let open: () -> Void
  let capture: () -> Void
  /// The server stops nothing on its own: Encerrar takes the resource off the lists (it comes back when an agent
  /// uses it again).
  let close: () -> Void
}

private struct MacResourceMenu: View {
  let resource: SessionResource
  let actions: MacResourceActions
  var body: some View {
    Button("Abrir janela", systemImage: "macwindow", action: actions.open)
    Button("Salvar captura…", systemImage: "camera", action: actions.capture)
    Divider()
    Button("Encerrar", systemImage: "xmark.circle", role: .destructive, action: actions.close)
  }
}

/// Captura: the resource's current frame at full size, saved where Alexandre chooses.
@MainActor enum MacResourceCapture {
  static func save(_ resource: SessionResource, client: OpenCodeClient, toast: ToastCenter) {
    Task {
      do {
        let snapshot = try await client.resourceSnapshot(resource.id)
        guard let data = snapshot.image else { throw ClientError.http(404) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ContextColumn.name(resource) + ".png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        try png.write(to: url)
      } catch {
        toast.show("Não foi possível capturar o recurso.", kind: .error)
      }
    }
  }
}
