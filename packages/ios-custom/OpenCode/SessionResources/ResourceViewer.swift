import OpenCodeKit
import SwiftUI

/// Full-screen viewer for one resource, opened from "Agentes e tarefas" or an `opencode-resource:` link.
struct ResourceViewerScreen: View {
  @State private var model: ResourceViewerModel
  init(resource: SessionResource, client: OpenCodeClient, close: @escaping () -> Void) {
    let model = ResourceViewerModel(resource: resource, client: client)
    model.close = close
    _model = State(initialValue: model)
  }
  var body: some View {
    switch model.resource.kind {
    case .iosSimulator: IOSSimulatorResourceView(model: model)
    case .androidEmulator: AndroidEmulatorResourceView(model: model)
    case .chrome: ChromeResourceView(model: model)
    case .unknown: ResourceViewerShell(model: model, tools: { EmptyView() })
    }
  }
}

/// The shared "B" layout: the screen fills the view; floating glass controls sit on top.
///
/// Showing and hiding the controls never steals a touch meant for the resource:
/// - while only watching, touches do not reach the resource, so a tap on the screen toggles the controls;
/// - in control, every touch on the screen goes to the resource. The controls hide when control is taken and a
///   small edge handle (drag it along the edge so it never covers what matters) toggles them; the "Você no controle"
///   pill at the top stays visible and also offers "Mostrar controles" and "Devolver controle".
///
/// Kinds pass their screen (`surface`, default `ResourceFrameView`), their side tools (`tools`) and optionally their
/// own bottom bar (`bottom`, default `ResourceControlBar`, which Chrome replaces with its address bar).
struct ResourceViewerShell<Surface: View, Tools: View, Bottom: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var model: ResourceViewerModel
  let contentSize: CGSize?
  let surface: () -> Surface
  let tools: () -> Tools
  let bottom: () -> Bottom
  @AppStorage("resourceViewer.handle") private var handle = 0.5
  @GestureState private var handleDrag: CGFloat = 0

  init(
    model: ResourceViewerModel, contentSize: CGSize? = nil, @ViewBuilder surface: @escaping () -> Surface,
    @ViewBuilder tools: @escaping () -> Tools, @ViewBuilder bottom: @escaping () -> Bottom
  ) {
    self.model = model
    self.contentSize = contentSize
    self.surface = surface
    self.tools = tools
    self.bottom = bottom
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        theme.color(.background).ignoresSafeArea()
        screen.padding(.horizontal, 8).padding(.vertical, 4)
        // While watching, a tap anywhere outside the controls toggles them (the controls' own background catches it
        // while they are shown). In control nothing catches it: touches go to the resource underneath.
        if !model.touching, !model.controlsVisible { toggleArea }
        if model.controlsVisible {
          controls.background { if !model.touching { toggleArea } }.transition(.opacity)
        }
        if model.inControl, !model.controlsVisible {
          controlPill.excludedFromTouches(model, "pill-top").padding(.top, 6).frame(maxHeight: .infinity, alignment: .top)
        }
        if model.inControl, !model.controlsVisible { edgeHandle(height: geometry.size.height) }
        if model.controlsVisible { closeButton.transition(.opacity) }
        ResourceKeyboard(model: model, active: $model.keyboardVisible, style: model.keyboardStyle)
          .frame(width: 1, height: 1).opacity(0.02)
      }
      .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
      .animation(.easeOut(duration: 0.2), value: model.inControl)
    }
    .foregroundStyle(theme.color(.textStrong))
    .tint(theme.color(.primary))
    .task { model.start() }
    // Closing ends the viewer for good (giving control back without reopening the stream); the background only
    // pauses it, and coming back reconnects at once.
    .onDisappear { model.finish() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { model.suspend() }
      if phase == .active { model.resume() }
    }
  }

  private var screen: some View {
    ZStack {
      surface()
      ResourceTouchOverlay(model: model, contentSize: contentSize, indicator: theme.uiColor(.primary))
    }

    .overlay {
      if model.inControl {
        RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.primary), lineWidth: 3).allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .bottom) {
      // Connection failures first; otherwise an adapter's or input's short notice, which fades on its own.
      if let text = model.failure ?? model.notice {
        Text(text).appFont(.caption).multilineTextAlignment(.center).lineLimit(3)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .resourceGlass(.capsule).padding(.horizontal, 24).padding(.bottom, 96).allowsHitTesting(false)
          .accessibilityIdentifier(model.failure == nil ? "resource-notice" : "resource-failure")
          .transition(.opacity)
      }
    }
  }

  private var closeButton: some View {
    Button {
      if let close = model.close { close() } else { dismiss() }
    } label: {
      Image(systemName: "xmark").appSymbol(.action).frame(width: 44, height: 44).resourceGlass(.circle)
        .contentShape(.rect)
    }
    .buttonStyle(.plain).accessibilityLabel("Fechar").accessibilityIdentifier("resource-close")
    .excludedFromTouches(model, "close")
    .padding(.leading, 12).padding(.top, 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var toggleArea: some View {
    Color.clear.contentShape(.rect).onTapGesture { model.controlsVisible.toggle() }.accessibilityHidden(true)
  }

  private var controls: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        // The close button is its own top layer (see `body`); this keeps its place in the row.
        Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
        pill(model.status, dot: model.connected ? .success : .textWeak).layoutPriority(1)
          .contextMenu { ForEach(model.statusDetails, id: \.self) { Text($0) } }
          .accessibilityIdentifier("resource-status")
          .accessibilityValue(model.statusDetails.joined(separator: ", "))
          .excludedFromTouches(model, "status")
        Spacer(minLength: 0)
        if model.inControl {
          controlPill.excludedFromTouches(model, "pill-bar")
        } else {
          pill(holderText, dot: model.holder == .agent ? .success : .primary).accessibilityIdentifier("resource-holder")
        }
      }
      .padding(.horizontal, 12).padding(.top, 6)
      Spacer()
      // Kinds without side tools (Android's navigation pill, Chrome's address bar) pass `EmptyView`.
      if Tools.self != EmptyView.self {
        HStack {
          Spacer()
          VStack(spacing: 10) { tools() }.padding(6).resourceGlass(.capsule)
            .accessibilityIdentifier("resource-tools").excludedFromTouches(model, "tools")
        }.padding(.trailing, 10)
      }
      Spacer()
      bottom().excludedFromTouches(model, "bottom")
    }
  }

  private var holderText: String {
    switch model.holder {
    case .agent: "\(model.resource.owner?.agent ?? "Agente") no controle"
    case .me: "Você no controle"
    case .elsewhere: "Você no controle (outro aparelho)"
    }
  }

  private func pill(_ text: String, dot: ThemeRole) -> some View {
    HStack(spacing: 6) {
      Circle().fill(theme.color(dot)).frame(width: 7, height: 7)
      Text(text).appFont(.micro, weight: .medium).lineLimit(1).monospacedDigit()
    }
    .padding(.horizontal, 11).frame(height: 32).resourceGlass(.capsule)
  }

  private var controlPill: some View {
    Menu {
      Button(model.controlsVisible ? "Ocultar controles" : "Mostrar controles", systemImage: "slider.horizontal.3") {
        model.controlsVisible.toggle()
      }
      Button("Devolver controle", systemImage: "hand.raised.slash") { Task { await model.giveBack() } }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "pause.fill").appSymbol(.inline).foregroundStyle(theme.color(.primary))
        Text("Você no controle").appFont(.footnote, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1).fixedSize()
      }
      .padding(.horizontal, 14).frame(height: 34)
      .resourceGlass(.capsule, tint: .primary)
    }
    .accessibilityIdentifier("resource-control-pill")
  }

  private func edgeHandle(height: CGFloat) -> some View {
    let span = max(1, height - 160)
    let top = min(max(80, 80 + span * handle + handleDrag), height - 80) - 32
    return VStack(spacing: 0) {
      Color.clear.frame(width: 1, height: max(0, top)).allowsHitTesting(false)
      Capsule().fill(.clear).frame(width: 22, height: 64)
        .overlay { Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).appSymbol(.disclosure) }
        .resourceGlass(.capsule)
        .contentShape(.capsule)
        .gesture(
          DragGesture(minimumDistance: 4)
            .updating($handleDrag) { value, state, _ in state = value.translation.height }
            .onEnded { value in handle = min(1, max(0, handle + value.translation.height / span)) }
        )
        .simultaneousGesture(TapGesture().onEnded { model.controlsVisible = true })
        .accessibilityElement().accessibilityLabel("Mostrar controles").accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("resource-handle")
        .excludedFromTouches(model, "handle")
      Spacer(minLength: 0).allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.trailing, 2)
  }
}

extension ResourceViewerShell where Surface == ResourceFrameView {
  init(model: ResourceViewerModel, @ViewBuilder tools: @escaping () -> Tools, @ViewBuilder bottom: @escaping () -> Bottom) {
    self.init(model: model, surface: { ResourceFrameView(model: model) }, tools: tools, bottom: bottom)
  }
}

extension ResourceViewerShell where Surface == ResourceFrameView, Bottom == ResourceControlBar<EmptyView> {
  init(model: ResourceViewerModel, @ViewBuilder tools: @escaping () -> Tools) {
    self.init(model: model, surface: { ResourceFrameView(model: model) }, tools: tools, bottom: { ResourceControlBar(model: model) })
  }
}

/// "Assumir controle" / "Devolver" with the gesture hint, the default bottom of the viewer. `accessory` goes between
/// the button and the hint (Android's navigation pill).
struct ResourceControlBar<Accessory: View>: View {
  @Environment(\.appTheme) private var theme
  let model: ResourceViewerModel
  let accessory: () -> Accessory
  init(model: ResourceViewerModel, @ViewBuilder accessory: @escaping () -> Accessory) {
    self.model = model
    self.accessory = accessory
  }
  var body: some View {
    VStack(spacing: 8) {
      if model.inControl {
        Button {
          Task { await model.giveBack() }
        } label: {
          Label("Devolver controle", systemImage: "hand.raised.slash").appFont(.body, weight: .semibold)
            .padding(.horizontal, 24).frame(height: 50).resourceGlass(.capsule)
        }
        .buttonStyle(.plain).accessibilityIdentifier("resource-give-back")
      } else {
        Button {
          Task { await model.takeControl() }
        } label: {
          Label("Assumir controle", systemImage: "hand.raised").appFont(.body, weight: .semibold)
            .foregroundStyle(theme.color(.onPrimary)).padding(.horizontal, 28).frame(height: 50)
            .background(theme.color(.primary), in: .capsule).shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(model.busy || model.holder == .elsewhere || !model.resource.state.running)
        .accessibilityIdentifier("resource-take")
      }
      accessory()
      Text(model.inControl ? "A alça na borda mostra e oculta os controles" : "Toque na tela para ocultar os controles")
        .appFont(.micro).foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 10).padding(.vertical, 4)
        .resourceGlass(.capsule)
    }
    .padding(.bottom, 10)
  }
}

extension ResourceControlBar where Accessory == EmptyView {
  init(model: ResourceViewerModel) { self.init(model: model) { EmptyView() } }
}

/// One round tool in the side column.
struct ResourceToolButton: View {
  let title: String
  let systemImage: String
  var active = false
  let action: () -> Void
  init(_ title: String, systemImage: String, active: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.active = active
    self.action = action
  }
  @Environment(\.appTheme) private var theme
  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage).appSymbol(.action)
        .foregroundStyle(theme.color(active ? .primary : .textStrong))
        .frame(width: 46, height: 46).resourceGlass(.circle)
    }
    .buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// Lets a floating control be dragged anywhere over the screen, remembering where Alexandre left it (per key), so it
/// never permanently covers part of the app under it. Android's navigation pill uses it.
struct ResourceDraggable: ViewModifier {
  let key: String
  var initial = CGPoint(x: 0.5, y: 0.92)
  @State private var stored: CGPoint?
  @GestureState private var drag: CGSize = .zero
  func body(content: Content) -> some View {
    GeometryReader { geometry in
      let point = stored ?? Self.load(key) ?? initial
      content
        .position(
          x: min(max(40, point.x * geometry.size.width + drag.width), geometry.size.width - 40),
          y: min(max(40, point.y * geometry.size.height + drag.height), geometry.size.height - 40))
        .gesture(
          DragGesture(minimumDistance: 6)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
              let next = CGPoint(
                x: min(1, max(0, point.x + value.translation.width / max(1, geometry.size.width))),
                y: min(1, max(0, point.y + value.translation.height / max(1, geometry.size.height))))
              stored = next
              UserDefaults.standard.set([next.x, next.y], forKey: "resourceViewer.dock.\(key)")
            })
    }
  }
  private static func load(_ key: String) -> CGPoint? {
    guard let values = UserDefaults.standard.array(forKey: "resourceViewer.dock.\(key)") as? [Double], values.count == 2
    else { return nil }
    return CGPoint(x: values[0], y: values[1])
  }
}

/// Material for controls floating over any screen: a blurred backdrop tinted with the theme background, so text
/// keeps its contrast over light pages in the dark theme (and dark ones in the light theme), a hairline border and a
/// soft shadow. Not Liquid Glass: neighboring glass shapes merge, and a merged non-interactive shape took the touches
/// of the close button beside the status pill. `tint` outlines it in that role (the "Você no controle" pill).
struct ResourceGlass<S: Shape>: ViewModifier {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let shape: S
  var tint: ThemeRole? = nil
  func body(content: Content) -> some View {
    content
      .background {
        shape.fill(.regularMaterial)
          .overlay { shape.fill(theme.color(.background).opacity(0.55)) }
          .overlay { shape.stroke(theme.color(tint ?? .controlBorder), lineWidth: tint == nil ? 1 / displayScale : 1.5) }
          .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.18), radius: 6, y: 2)
      }
      .contentShape(shape)
  }
}

extension View {
  func resourceGlass<S: Shape>(_ shape: S, tint: ThemeRole? = nil) -> some View {
    modifier(ResourceGlass(shape: shape, tint: tint))
  }
  /// Registers this floating control's frame so touches on it never reach the resource underneath.
  func excludedFromTouches(_ model: ResourceViewerModel, _ key: String) -> some View {
    onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.exclusions[key] = $0 }
      .onDisappear { model.exclusions[key] = nil }
  }
  func resourceDraggable(_ key: String, initial: CGPoint = CGPoint(x: 0.5, y: 0.92)) -> some View {
    modifier(ResourceDraggable(key: key, initial: initial))
  }
}
