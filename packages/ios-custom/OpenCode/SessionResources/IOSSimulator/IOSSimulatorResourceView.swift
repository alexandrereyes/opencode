import OpenCodeKit
import SwiftUI

/// iOS Simulator viewer (layout 2B). Foundation stub: the shell's JPEG surface and basic tools. The live stream,
/// rotation and the remaining tools belong to the `resources-ios-sim` work.
struct IOSSimulatorResourceView: View {
  let model: ResourceViewerModel
  var body: some View {
    ResourceViewerShell(model: model) {
      ResourceToolButton("Início", systemImage: "house") { model.send([.button("home")]) }.disabled(!model.inControl)
      ResourceToolButton("Teclado", systemImage: "keyboard", active: model.keyboardVisible) {
        model.keyboardVisible.toggle()
      }.disabled(!model.inControl)
    }
  }
}
