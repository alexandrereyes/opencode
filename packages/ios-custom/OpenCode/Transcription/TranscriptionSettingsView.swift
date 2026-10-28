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
            Button(networkAction) { download = true }
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
        #if os(macOS)
        Text("25 idiomas, incluindo português. A detecção é automática. O modelo é preparado uma vez após o download ou atualização do app. O áudio nunca sai do Mac; só o texto entra no rascunho. Revise e envie quando quiser.")
          .font(.caption).fontWeight(.regular).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        #else
        Text("25 idiomas, incluindo português. A detecção é automática. Depois do download e a cada atualização do app, o \(TranscriptionController.device) otimiza o modelo uma vez (cerca de 15 segundos), em segundo plano. O áudio nunca sai do \(TranscriptionController.device); só o texto entra no rascunho. Revise e envie quando quiser.")
        #endif
      }.listRowBackground(theme.color(.surface))
      Section("Licenças") {
        Text("FluidAudio 0.17.7 · Apache 2.0\nParakeet Ultra · moondream / NVIDIA\nConversão CoreML · FluidInference\nModelo · CC BY 4.0")
          .appFont(.caption)
        NavigationLink("Avisos e atribuições") { TranscriptionNoticesView() }
      }.listRowBackground(theme.color(.surface))
    }.settingsList(theme).navigationTitle("Transcrição").inlineNavigationTitle()
      .onAppear { transcription.refreshDiskSize() }
      .alert("Baixar transcrição no aparelho?", isPresented: $download) {
        Button("Baixar por Wi-Fi") { transcription.download(cellular: false) }
        Button(anyNetwork) { transcription.download(cellular: true) }
        Button("Cancelar", role: .cancel) {}
      } message: { Text(TranscriptionController.downloadMessage) }
      .alert("Apagar modelo de transcrição?", isPresented: $remove) {
        Button("Apagar modelo", role: .destructive) { Task { await transcription.removeModel() } }
        Button("Cancelar", role: .cancel) {}
      } message: { Text("Libera espaço neste \(TranscriptionController.device). Os rascunhos e áudios aguardando transcrição serão preservados. Você poderá baixar o modelo novamente.") }
  }
  static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
  private var networkAction: String {
    #if os(macOS)
    "Continuar em qualquer rede"
    #else
    "Continuar pelos dados móveis"
    #endif
  }
  private var anyNetwork: String {
    #if os(macOS)
    "Usar qualquer rede"
    #else
    "Usar dados móveis"
    #endif
  }
}

private struct TranscriptionNoticesView: View {
  @Environment(\.appTheme) private var theme
  var body: some View {
    ScrollView {
      Text(Bundle.main.url(forResource: "TranscriptionNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Licenças indisponíveis.")
        .appFont(.caption).textSelection(.enabled).padding(20)
    }.background(theme.color(.background)).foregroundStyle(theme.color(.text))
      .navigationTitle("Licenças").inlineNavigationTitle()
  }
}
