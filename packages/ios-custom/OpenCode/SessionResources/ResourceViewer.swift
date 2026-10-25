import OpenCodeKit
import SwiftUI

/// Full-screen viewer for one resource, opened from "Agentes e tarefas" or an `opencode-resource:` link.
struct ResourceViewerScreen: View {
  @State private var model: ResourceViewerModel
  init(resource: SessionResource, client: OpenCodeClient) {
    _model = State(initialValue: ResourceViewerModel(resource: resource, client: client))
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
        if model.controlsVisible { controls.transition(.opacity) }
        if model.inControl, !model.controlsVisible { controlPill.padding(.top, 6).frame(maxHeight: .infinity, alignment: .top) }
        if model.inControl, !model.controlsVisible { edgeHandle(height: geometry.size.height) }
        ResourceKeyboard(model: model, active: $model.keyboardVisible).frame(width: 1, height: 1).opacity(0.02)
      }
      .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
      .animation(.easeOut(duration: 0.2), value: model.inControl)
    }
    .foregroundStyle(theme.color(.textStrong))
    .tint(theme.color(.primary))
    .statusBarHidden(!model.controlsVisible)
    .task { model.start() }
    .onDisappear {
      if model.inControl { Task { await model.giveBack() } }
      model.stop()
    }
  }

  private var screen: some View {
    ZStack {
      surface()
      ResourceTouchOverlay(model: model, contentSize: contentSize, indicator: theme.uiColor(.primary)) {
        model.controlsVisible.toggle()
      }
    }
    .overlay {
      if model.inControl {
        RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.primary), lineWidth: 3).allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .bottom) {
      if let failure = model.failure {
        Text(failure).appFont(.caption).padding(.horizontal, 12).padding(.vertical, 8)
          .glassEffect(.regular, in: .capsule).padding(.bottom, 96).allowsHitTesting(false)
      }
    }
  }

  private var controls: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark").appSymbol(.action).frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
        }.buttonStyle(.plain).accessibilityLabel("Fechar").accessibilityIdentifier("resource-close")
        pill(model.status, dot: model.connected ? .success : .textWeak).layoutPriority(1)
          .accessibilityIdentifier("resource-status")
        Spacer(minLength: 0)
        if model.inControl {
          controlPill
        } else {
          pill(holderText, dot: model.holder == .agent ? .success : .primary).accessibilityIdentifier("resource-holder")
        }
      }
      .padding(.horizontal, 12).padding(.top, 6)
      Spacer()
      HStack {
        Spacer()
        VStack(spacing: 10) { tools() }.padding(6).glassEffect(.regular, in: .capsule)
          .accessibilityIdentifier("resource-tools")
      }.padding(.trailing, 10)
      Spacer()
      bottom()
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
    .padding(.horizontal, 11).frame(height: 32).glassEffect(.regular, in: .capsule)
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
      .glassEffect(.regular.tint(theme.color(.primary).opacity(0.18)).interactive(), in: .capsule)
    }
    .accessibilityIdentifier("resource-control-pill")
  }

  private func edgeHandle(height: CGFloat) -> some View {
    let span = max(1, height - 160)
    let y = min(max(80, 80 + span * handle + handleDrag), height - 80)
    return Capsule().fill(.clear).frame(width: 22, height: 64)
      .overlay { Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).appSymbol(.disclosure) }
      .glassEffect(.regular.interactive(), in: .capsule)
      .contentShape(.capsule)
      .gesture(
        DragGesture(minimumDistance: 4)
          .updating($handleDrag) { value, state, _ in state = value.translation.height }
          .onEnded { value in handle = min(1, max(0, handle + value.translation.height / span)) }
      )
      .simultaneousGesture(TapGesture().onEnded { model.controlsVisible = true })
      .accessibilityElement().accessibilityLabel("Mostrar controles").accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("resource-handle")
      .offset(y: y - height / 2)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
      .padding(.trailing, 2)
  }
}

extension ResourceViewerShell where Surface == ResourceFrameView {
  init(model: ResourceViewerModel, @ViewBuilder tools: @escaping () -> Tools, @ViewBuilder bottom: @escaping () -> Bottom) {
    self.init(model: model, surface: { ResourceFrameView(model: model) }, tools: tools, bottom: bottom)
  }
}

extension ResourceViewerShell where Surface == ResourceFrameView, Bottom == ResourceControlBar {
  init(model: ResourceViewerModel, @ViewBuilder tools: @escaping () -> Tools) {
    self.init(model: model, surface: { ResourceFrameView(model: model) }, tools: tools, bottom: { ResourceControlBar(model: model) })
  }
}

/// "Assumir controle" / "Devolver" with the gesture hint, the default bottom of the viewer.
struct ResourceControlBar: View {
  @Environment(\.appTheme) private var theme
  let model: ResourceViewerModel
  var body: some View {
    VStack(spacing: 8) {
      if model.inControl {
        Button {
          Task { await model.giveBack() }
        } label: {
          Label("Devolver controle", systemImage: "hand.raised.slash").appFont(.body, weight: .semibold)
            .padding(.horizontal, 24).frame(height: 50).glassEffect(.regular.interactive(), in: .capsule)
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
      Text(model.inControl ? "A alça na borda mostra e oculta os controles" : "Toque na tela para ocultar os controles")
        .appFont(.micro).foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
    .padding(.bottom, 10)
  }
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
        .frame(width: 46, height: 46).glassEffect(.regular.interactive(), in: .circle)
    }
    .buttonStyle(.plain).accessibilityLabel(title)
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

extension View {
  func resourceDraggable(_ key: String, initial: CGPoint = CGPoint(x: 0.5, y: 0.92)) -> some View {
    modifier(ResourceDraggable(key: key, initial: initial))
  }
}
