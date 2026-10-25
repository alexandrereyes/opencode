import OpenCodeKit
import SwiftUI

/// Android Emulator viewer (layout 3B). Foundation stub: the shell's JPEG surface, a keyboard tool and the
/// navigation pill, which Alexandre can drag anywhere so it never covers the app. The live stream (H.264 or gRPC)
/// and the final controls belong to the `resources-android` work.
struct AndroidEmulatorResourceView: View {
  @Environment(\.appTheme) private var theme
  let model: ResourceViewerModel
  var body: some View {
    ResourceViewerShell(model: model) {
      ResourceToolButton("Teclado", systemImage: "keyboard", active: model.keyboardVisible) {
        model.keyboardVisible.toggle()
      }.disabled(!model.inControl)
    }
    .overlay {
      if model.inControl {
        HStack(spacing: 22) {
          navigation("Voltar", "arrowtriangle.backward", "back")
          navigation("Início", "circle", "home")
          navigation("Recentes", "square", "recents")
        }
        .padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: .capsule)
        .resourceDraggable("android-navigation")
        .accessibilityIdentifier("resource-android-navigation")
      }
    }
  }
  private func navigation(_ title: String, _ symbol: String, _ button: String) -> some View {
    Button {
      model.send([.button(button)])
    } label: {
      Image(systemName: symbol).appSymbol(.action).foregroundStyle(theme.color(.textStrong)).frame(width: 36, height: 36)
    }.buttonStyle(.plain).accessibilityLabel(title)
  }
}
