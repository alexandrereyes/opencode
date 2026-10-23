import SwiftUI

struct TranscriptionSettingsView: View {
  @Environment(\.appTheme) private var theme
  let transcription: TranscriptionController
  @State private var download = false
  @State private var remove = false
  var body: some View {
    List {
      Section {
        Text(transcription.label).accessibilityIdentifier("transcription-status")
        LabeledContent("Download", value: Self.size(transcription.totalBytes))
        LabeledContent("No aparelho", value: Self.size(transcription.diskBytes))
        if transcription.status == .downloading {
          ProgressView(value: transcription.progress).tint(theme.color(.primary))
          Text("\(Self.size(transcription.downloaded)) de \(Self.size(transcription.totalBytes))").appFont(.caption)
          if !transcription.cellular {
            Button("Continuar pelos dados móveis") { download = true }
          }
        }
        if transcription.status == .missing {
          Button("Baixar modelo") { download = true }.accessibilityIdentifier("transcription-download")
        }
        if case .failed = transcription.status {
          Button("Tentar de novo") { transcription.retry() }
        }
        if transcription.status != .missing {
          Button("Apagar modelo", role: .destructive) { remove = true }.disabled(!transcription.canRemove)
        }
      } header: { Text("Parakeet Ultra") } footer: {
        Text("25 idiomas, incluindo português. A detecção é automática. A primeira preparação pode levar cerca de 15 segundos. O áudio nunca sai do iPhone; só o texto entra no rascunho. Revise e envie quando quiser.")
      }.listRowBackground(theme.color(.surface))
      Section("Licenças") {
        Text("FluidAudio 0.17.7 · Apache 2.0\nParakeet Ultra · moondream / NVIDIA\nConversão CoreML · FluidInference\nModelo · CC BY 4.0")
          .appFont(.caption)
        NavigationLink("Avisos e atribuições") { TranscriptionNoticesView() }
      }.listRowBackground(theme.color(.surface))
    }.settingsList(theme).navigationTitle("Transcrição").navigationBarTitleDisplayMode(.inline)
      .onAppear { transcription.refreshDiskSize() }
      .alert("Baixar transcrição no aparelho?", isPresented: $download) {
        Button("Baixar por Wi-Fi") { transcription.download(cellular: false) }
        Button("Usar dados móveis") { transcription.download(cellular: true) }
        Button("Cancelar", role: .cancel) {}
      } message: { Text(TranscriptionController.downloadMessage) }
      .alert("Apagar modelo de transcrição?", isPresented: $remove) {
        Button("Apagar modelo", role: .destructive) { Task { await transcription.removeModel() } }
        Button("Cancelar", role: .cancel) {}
      } message: { Text("Libera espaço neste iPhone. Os rascunhos e áudios aguardando transcrição serão preservados. Você poderá baixar o modelo novamente.") }
  }
  static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private struct TranscriptionNoticesView: View {
  @Environment(\.appTheme) private var theme
  var body: some View {
    ScrollView {
      Text(Bundle.main.url(forResource: "TranscriptionNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Licenças indisponíveis.")
        .appFont(.caption).textSelection(.enabled).padding(20)
    }.background(theme.color(.background)).foregroundStyle(theme.color(.text))
      .navigationTitle("Licenças").navigationBarTitleDisplayMode(.inline)
  }
}
