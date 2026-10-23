import OpenCodeKit
import SwiftUI

struct VoiceTranscriptView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let memory: VoiceMemoryStore
  var body: some View {
    NavigationStack {
      List {
        if memory.localError {
          Text("Não foi possível salvar algumas falas neste aparelho.")
            .foregroundStyle(theme.color(.error)).appFont(.secondary)
        }
        if memory.status != .available {
          Text(memory.status == .unsupported
            ? "Este servidor ainda não oferece memória de voz. Falas locais aguardam sincronização."
            : "Memória do servidor indisponível; falas preservadas neste aparelho.")
            .appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
        }
        if !memory.context.summary.isEmpty {
          Section("Memória resumida") {
            Text(memory.context.summary).appFont(.message).textSelection(.enabled)
              .accessibilityIdentifier("voice-memory-summary")
          }
        }
        Section("Conversa por voz") {
          if memory.context.turns.isEmpty {
            Text("Suas falas aparecerão aqui durante a chamada.").appFont(.secondary)
              .foregroundStyle(theme.color(.textSecondary))
          }
          ForEach(memory.context.turns) { turn in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                Text(turn.role == .user ? "Alexandre" : "Voz").appFont(.secondary, weight: .semibold)
                Spacer()
                Text(Date(timeIntervalSince1970: turn.at / 1000), format: .dateTime.hour().minute())
                  .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
              }
              Text(turn.text).appFont(.message).textSelection(.enabled)
              if turn.interrupted == true {
                Label("Fala interrompida", systemImage: "waveform.slash")
                  .appFont(.caption).foregroundStyle(theme.color(.warning))
              }
            }.padding(.vertical, 5).accessibilityIdentifier("voice-memory-turn-" + turn.id)
          }
        }
        if memory.context.truncated {
          Text("Exibição limitada ao contexto recente.").appFont(.footnote)
            .foregroundStyle(theme.color(.textSecondary))
        }
        if memory.pending > 0 {
          Text("Pendências de sincronização: \(memory.pending)").appFont(.footnote)
            .foregroundStyle(theme.color(.textSecondary))
        }
      }
      .accessibilityIdentifier("voice-memory-transcript")
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .foregroundStyle(theme.color(.text))
      .navigationTitle("Transcrição da voz").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } }
        #if DEBUG
        if memory.isPreview {
          ToolbarItem(placement: .bottomBar) {
            Button("Adicionar fala de demonstração") { memory.previewUpdate() }
              .accessibilityIdentifier("voice-memory-fixture-update")
          }
        }
        #endif
      }
    }.tint(theme.color(.primary)).presentationDetents([.large])
      .task { _ = await memory.prepare() }
  }
}
