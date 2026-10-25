import OpenCodeKit
import SwiftUI

/// Android Emulator viewer (layout 3B). The shell draws the JPEG stream (already upright: the adapter rotates it with
/// the display) and maps touches; this view adds Android's navigation pill (Voltar, Início, Recentes), the keyboard
/// and a "…" menu with the remaining hardware buttons.
///
/// With the controls visible the pill sits under **Assumir controle** / **Devolver controle**. In control, with the
/// controls hidden, it floats over the screen and can be dragged anywhere (position remembered), since any fixed
/// place would cover some app's bottom bar.
struct AndroidEmulatorResourceView: View {
  let model: ResourceViewerModel
  var body: some View {
    ResourceViewerShell(model: model, tools: { EmptyView() }) {
      ResourceControlBar(model: model) {
        AndroidNavigationBar(model: model)
          .accessibilityElement(children: .contain).accessibilityIdentifier("resource-android-navigation")
      }
    }
    .overlay {
      if model.inControl, !model.controlsVisible {
        AndroidNavigationBar(model: model)
          .accessibilityElement(children: .contain).accessibilityIdentifier("resource-android-navigation-floating")
          .resourceDraggable("android-navigation", initial: CGPoint(x: 0.66, y: 0.93))
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
  }
}

/// ◁ ○ □ and the keyboard in one glass capsule, plus a round "…" menu. Disabled until Alexandre holds control.
private struct AndroidNavigationBar: View {
  @Environment(\.appTheme) private var theme
  let model: ResourceViewerModel

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        button("Voltar", "arrowtriangle.backward", identifier: "resource-android-back") { model.send([.button("back")]) }
        button("Início", "circle", identifier: "resource-android-home") { model.send([.button("home")]) }
        button("Recentes", "square", identifier: "resource-android-recents") { model.send([.button("recents")]) }
        Divider().frame(height: 22).overlay(theme.color(.border))
        button(
          model.keyboardVisible ? "Ocultar teclado" : "Teclado",
          model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
          identifier: "resource-android-keyboard", active: model.keyboardVisible
        ) { model.keyboardVisible.toggle() }
      }
      .padding(.horizontal, 8).frame(height: 48)
      .glassEffect(.regular.interactive(), in: .capsule)
      more
    }
    .disabled(!model.inControl)
    .opacity(model.inControl ? 1 : 0.55)
  }

  private var more: some View {
    Menu {
      Button("Girar para a esquerda", systemImage: "rotate.left") { model.send([.button("rotate-left")]) }
      Button("Girar para a direita", systemImage: "rotate.right") { model.send([.button("rotate-right")]) }
      Button("Bloquear ou ligar a tela", systemImage: "lock") { model.send([.button("lock")]) }
      Button("Aumentar volume", systemImage: "speaker.plus") { model.send([.button("volume-up")]) }
      Button("Diminuir volume", systemImage: "speaker.minus") { model.send([.button("volume-down")]) }
    } label: {
      Image(systemName: "ellipsis").appSymbol(.action).foregroundStyle(theme.color(.textStrong))
        .frame(width: 48, height: 48).glassEffect(.regular.interactive(), in: .circle)
    }
    .accessibilityLabel("Mais botões do Android")
    .accessibilityIdentifier("resource-android-more")
  }

  private func button(
    _ title: String, _ symbol: String, identifier: String, active: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).appSymbol(.action)
        .foregroundStyle(theme.color(active ? .primary : .textStrong))
        .frame(width: 44, height: 44).contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityIdentifier(identifier)
  }
}
