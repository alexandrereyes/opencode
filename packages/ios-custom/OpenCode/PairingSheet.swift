import OpenCodeKit
import SwiftUI
import VisionKit

struct PairingSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let servers: ServerStore
  @State private var payload = ""
  @State private var name = ""
  @State private var busy = false
  @State private var result: ServerConfiguration?
  @State private var version: String?
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  var body: some View {
    NavigationStack {
      List {
        Section {
          if result != nil {
            Label("Código resgatado com segurança", systemImage: "checkmark.circle.fill")
              .foregroundStyle(theme.color(.success))
          } else if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            PairingScanner { value in
              guard !busy else { return }
              payload = value
              begin()
            }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
          } else {
            ContentUnavailableView("Parear servidor", systemImage: "qrcode.viewfinder",
                                   description: Text("Cole o link ou o JSON do QR code gerado por opencode pair. A câmera não está disponível neste dispositivo."))
          }
        }.listRowBackground(theme.color(.surface))
        Section {
          TextEditor(text: $payload).frame(minHeight: 90).font(.system(.caption, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled().scrollContentBackground(.hidden)
            .accessibilityIdentifier("pairing-payload").disabled(busy || result != nil)
          Button {
            begin()
          } label: {
            HStack { Text("Resgatar código"); Spacer(); if busy { ProgressView() } }
          }.disabled(payload.isEmpty || busy || result != nil).accessibilityIdentifier("pairing-redeem")
          #if DEBUG
          if servers.launchOverride != nil,
             ProcessInfo.processInfo.environment["OPENCODE_SETTINGS_TEST_INPUT"] == "1", result == nil {
            Button("Usar código de teste do sandbox") {
              payload = ProcessInfo.processInfo.environment["OPENCODE_PAIRING_PAYLOAD"] ?? ""
              begin()
            }.disabled(busy).accessibilityIdentifier("pairing-test-input")
          }
          #endif
        } header: { Text("Link ou conteúdo do QR code") }
          footer: { Text("O código é de uso único. Gere outro no terminal se ele já tiver expirado.") }
          .listRowBackground(theme.color(.surface))
        if let result {
          Section("Servidor pareado") {
            TextField("Nome (opcional)", text: $name).textContentType(.nickname).autocorrectionDisabled()
              .accessibilityIdentifier("pairing-name")
            Text(result.url.absoluteString).font(.caption).foregroundStyle(theme.color(.textSecondary))
            Label(version.map { "Conectado · versão \($0)" } ?? "Pareado · conexão indisponível", systemImage: "checkmark.circle.fill")
              .foregroundStyle(theme.color(.success)).accessibilityIdentifier("pairing-result")
            Button("Salvar servidor") { save(result) }.accessibilityIdentifier("pairing-save")
          }.listRowBackground(theme.color(.surface))
        }
        if let error {
          Section { Text(error).foregroundStyle(theme.color(.error)) }.listRowBackground(theme.color(.surface))
        }
      }.settingsList(theme).navigationTitle("Ler QR code").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
    }.onDisappear { task?.cancel() }
  }
  private func begin() {
    task?.cancel()
    task = Task {
      busy = true
      error = nil
      defer { if !Task.isCancelled { busy = false } }
      do {
        let link = try PairingLink(payload)
        try link.urls.forEach { try servers.validate($0) }
        let configuration = try await PairingClient().redeem(link)
        try Task.checkCancellation()
        result = configuration
        payload = "Código resgatado"
        let info = try await PairingClient().test(configuration)
        try Task.checkCancellation()
        version = info.version
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }
  private func save(_ result: ServerConfiguration) {
    do {
      try servers.add(name: name, address: result.url.absoluteString, password: result.password)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private struct PairingScanner: UIViewControllerRepresentable {
  let scanned: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
      isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
    controller.delegate = context.coordinator
    try? controller.startScanning()
    return controller
  }
  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
    context.coordinator.scanned = scanned
  }
  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
    controller.stopScanning()
    controller.delegate = nil
  }
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    var scanned: (String) -> Void
    init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      guard let value = addedItems.compactMap({ item -> String? in
        if case .barcode(let barcode) = item { return barcode.payloadStringValue }
        return nil
      }).first else { return }
      scanned(value)
    }
  }
}
