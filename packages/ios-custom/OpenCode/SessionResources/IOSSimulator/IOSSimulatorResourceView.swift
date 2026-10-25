import OpenCodeKit
import SwiftUI
import UIKit

/// iOS Simulator viewer (layout 2B): the shell's live screen, turned upright when the simulator is in landscape
/// (`meta.rotation` from serve-sim), and the simulator's tools: Início, Girar, Teclado and Captura.
/// Adapter and wire details: `docs/resources-ios-simulator.md`.
struct IOSSimulatorResourceView: View {
  let model: ResourceViewerModel
  @State private var capturing = false
  @State private var anchor = CaptureAnchor()

  var body: some View {
    ResourceViewerShell(model: model) {
      ResourceToolButton("Início", systemImage: "house") { model.send([.button("home")]) }
        .disabled(!model.inControl)
      ResourceToolButton("Girar", systemImage: "rotate.right") { model.send([.button("rotate-right")]) }
        .disabled(!model.inControl)
      ResourceToolButton("Teclado", systemImage: "keyboard", active: model.keyboardVisible) {
        model.keyboardVisible.toggle()
      }
      .disabled(!model.inControl)
      ResourceToolButton("Captura de tela", systemImage: "camera") { Task { await takeCapture() } }
        .disabled(capturing)
        .background(CaptureAnchorView(anchor: anchor))
    }
  }

  /// The simulator's full-size screen (`simctl io screenshot` through the hub, already upright), shared from a
  /// temporary file so the share sheet offers "Salvar imagem" at the original resolution. The file is removed when
  /// the sheet closes.
  private func takeCapture() async {
    capturing = true
    defer { capturing = false }
    guard let snapshot = try? await model.client.resourceSnapshot(model.resource.id), let data = snapshot.image else {
      return Haptics.play(.warning)
    }
    let name = (model.resource.meta.name ?? "Simulador").replacingOccurrences(of: "/", with: "-")
    let directory = FileManager.default.temporaryDirectory.appending(path: "SimulatorCaptures/\(UUID().uuidString)")
    let file = directory.appending(path: "\(name).jpg")
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
      (try? data.write(to: file)) != nil, let source = anchor.view, let presenter = Self.presenter(from: source)
    else { return Haptics.play(.warning) }
    Haptics.play(.success)
    let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
    sheet.popoverPresentationController?.sourceView = source
    presenter.present(sheet, animated: true)
  }

  /// The view controller on top of the one hosting `view` (the viewer is itself a full-screen cover).
  private static func presenter(from view: UIView) -> UIViewController? {
    var controller = view.window?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
}

/// The capture button's UIKit view, to present the share sheet from it.
@MainActor final class CaptureAnchor {
  weak var view: UIView?
}

private struct CaptureAnchorView: UIViewRepresentable {
  let anchor: CaptureAnchor
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    anchor.view = view
    return view
  }
  func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}
