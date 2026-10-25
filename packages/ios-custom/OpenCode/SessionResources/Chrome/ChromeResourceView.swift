import OpenCodeKit
import SwiftUI

/// Chrome viewer (layout 4B). Foundation stub: the shell's JPEG surface with history tools. The address bar at the
/// bottom that rises with the keyboard, password autofill and the CDP stream belong to the `resources-chrome` work.
struct ChromeResourceView: View {
  let model: ResourceViewerModel
  var body: some View {
    ResourceViewerShell(model: model) {
      ResourceToolButton("Voltar", systemImage: "chevron.backward") { model.send([.navigate("back")]) }
        .disabled(!model.inControl)
      ResourceToolButton("Avançar", systemImage: "chevron.forward") { model.send([.navigate("forward")]) }
        .disabled(!model.inControl)
      ResourceToolButton("Recarregar", systemImage: "arrow.clockwise") { model.send([.navigate("reload")]) }
        .disabled(!model.inControl)
      ResourceToolButton("Teclado", systemImage: "keyboard", active: model.keyboardVisible) {
        model.keyboardVisible.toggle()
      }.disabled(!model.inControl)
    }
  }
}
