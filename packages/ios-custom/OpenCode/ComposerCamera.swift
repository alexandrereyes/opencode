import AVFoundation
import OpenCodeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Câmera in the composer's "+" (Alexandre, 02/11): one photo from the system camera, imported like Fotos. Access is
/// asked only when Câmera is tapped; nothing is saved to the photo library and the microphone is never asked.
enum ComposerCamera {
  enum Access: Equatable { case ready, denied, restricted, unavailable }

  @MainActor static func request() async -> Access {
    #if DEBUG
    if let mode = ComposerCameraFixture.mode {
      return ["denied": .denied, "restricted": .restricted, "unavailable": .unavailable][mode] ?? .ready
    }
    #endif
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return .ready
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
    case .restricted: return .restricted
    default: return .denied
    }
  }

  /// The photo as JPEG at full quality, its orientation in the EXIF; the attachment pipeline then converts it
  /// (`AttachmentEncoding.prepare`) as it does a photo from Fotos.
  nonisolated static func jpeg(_ image: UIImage) -> Data? { image.jpegData(compressionQuality: 1) }
}

/// The system camera in photo mode: the picker's own shutter, Usar Foto and Cancelar.
struct ComposerCameraPicker: UIViewControllerRepresentable {
  let finish: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.cameraCaptureMode = .photo
    picker.delegate = context.coordinator
    return picker
  }
  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let finish: (UIImage?) -> Void
    init(finish: @escaping (UIImage?) -> Void) { self.finish = finish }
    func imagePickerController(_ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any])
    {
      finish(info[.originalImage] as? UIImage)
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
  }
}

extension ComposerCamera.Access {
  var title: String {
    switch self {
    case .denied: "Permita a câmera"
    case .restricted: "Câmera restrita"
    case .unavailable, .ready: "Câmera indisponível"
    }
  }
  var message: String {
    switch self {
    case .denied: "Ative a câmera do OpenCode nos Ajustes para tirar fotos e anexá-las à mensagem."
    case .restricted: "O acesso à câmera está bloqueado neste iPhone (Tempo de Uso ou perfil de gerenciamento)."
    case .unavailable, .ready: "Não há câmera disponível agora. Use Fotos ou Arquivos para anexar uma imagem."
    }
  }
}

#if DEBUG
/// `-OpenCodeCameraFixture photo|denied|restricted|unavailable` (isolated sandbox launches only): the simulator has
/// no camera, so `photo` stands in for the system picker with a rotated test photo and the same Usar foto/Cancelar.
@MainActor enum ComposerCameraFixture {
  static var mode: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-OpenCodeCameraFixture"), args.indices.contains(index + 1),
      ServerConfiguration.launch().isolatedTestSandbox else { return nil }
    return args[index + 1]
  }
  /// 300 × 200 pixels stored sideways (orientation `.right`): imported upright it is 200 × 300.
  static var photo: UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let base = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
      UIColor.systemOrange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 300, height: 40))
    }
    return UIImage(cgImage: base.cgImage!, scale: 1, orientation: .right)
  }
}

struct ComposerCameraFixtureView: View {
  let finish: (UIImage?) -> Void
  var body: some View {
    VStack(spacing: 24) {
      Text("Câmera de teste").font(.headline)
      Image(uiImage: ComposerCameraFixture.photo).resizable().scaledToFit().frame(maxHeight: 300)
      HStack(spacing: 40) {
        Button("Cancelar") { finish(nil) }.accessibilityIdentifier("camera-fixture-cancel")
        Button("Usar foto") { finish(ComposerCameraFixture.photo) }.accessibilityIdentifier("camera-fixture-use")
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white)
  }
}
#endif
