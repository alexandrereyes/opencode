import OpenCodeKit
import SwiftUI

/// The batch actions of the column's selection mode, shown by the header only while it is active.
struct SessionColumnSelection {
  let count: Int
  let canSelectAll: Bool
  let working: Bool
  let archive: () -> Void
  let delete: () -> Void
  let selectAll: () -> Void
  let cancel: () -> Void
}

/// The title row of the Sessões column: "Sessões", then voice, the optional Configurações and Nova sessão.
/// iOS keeps settings in Você and passes no `settings` action; the Mac passes one to show the gear.
struct SessionColumnHeader: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var voiceActive = false
  let voice: () -> Void
  var settings: (() -> Void)?
  let newSession: () -> Void
  var newSessionDisabled = false
  var selection: SessionColumnSelection?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if dynamicTypeSize.isAccessibilitySize {
        // The scaled title gets its own line, below the buttons, like a native large title.
        VStack(alignment: .trailing, spacing: 6) {
          buttons
          title.frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(spacing: 12) {
          title.lineLimit(1).minimumScaleFactor(0.8)
          Spacer(minLength: 0)
          buttons
        }
      }
      if let selection { selectionBar(selection) }
    }
    .padding(.horizontal, AppLayout.margin)
    .padding(.top, 4)
    .padding(.bottom, 8)
    .background {
      // A soft edge: rows fade out below the header instead of showing through the title.
      LinearGradient(
        stops: [
          .init(color: theme.color(.background), location: 0),
          .init(color: theme.color(.background), location: 0.72),
          .init(color: theme.color(.background).opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom
      )
      .padding(.bottom, -18)
      .ignoresSafeArea(edges: .top)
      .allowsHitTesting(false)
    }
  }

  private var title: some View {
    Text("Sessões").appFont(.largeTitle, weight: .bold)
      .foregroundStyle(theme.color(.textStrong))
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("sessions-title")
  }

  private var buttons: some View {
    GlassEffectContainer(spacing: 10) {
      HStack(spacing: 10) {
        if let selection {
          Menu {
            Button("Arquivar (\(selection.count))", systemImage: "archivebox", action: selection.archive)
            Button("Excluir (\(selection.count))", systemImage: "trash", role: .destructive, action: selection.delete)
            Divider()
            Button("Cancelar", systemImage: "xmark", action: selection.cancel)
          } label: {
            if selection.working {
              ProgressView().tint(theme.color(.textStrong)).frame(width: 48, height: 48)
            } else {
              symbol("ellipsis", color: .textStrong)
            }
          }
          .disabled(selection.working)
          .glassEffect(.regular.interactive(), in: .circle)
          .accessibilityLabel("Ações das sessões selecionadas")
          .accessibilityIdentifier("sessions-selection-menu")
        }
        Button(action: voice) {
          symbol("waveform", color: voiceActive ? .primary : .textStrong)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(voiceActive ? "Encerrar conversa por voz" : "Conversar por voz")
        .accessibilityIdentifier("voice-start")
        if let settings {
          Button(action: settings) { symbol("gearshape", color: .textStrong) }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Configurações")
            .accessibilityIdentifier("sessions-settings")
        }
        Button(action: newSession) { symbol("plus", color: .onPrimary) }
          .glassEffect(.regular.tint(theme.color(.primary)).interactive(), in: .circle)
          .opacity(newSessionDisabled ? 0.5 : 1)
          .disabled(newSessionDisabled)
          .accessibilityLabel("Nova sessão")
      }
      .buttonStyle(.plain)
    }
  }

  private func selectionBar(_ selection: SessionColumnSelection) -> some View {
    HStack(spacing: 16) {
      Text(SessionBulkCopy.count(selection.count))
        .appFont(.secondary, weight: .semibold).monospacedDigit()
        .foregroundStyle(theme.color(.textStrong))
        .accessibilityIdentifier("sessions-selection-count")
      Spacer(minLength: 0)
      Button("Selecionar todas", action: selection.selectAll)
        .disabled(!selection.canSelectAll || selection.working)
        .opacity(selection.canSelectAll && !selection.working ? 1 : 0.4)
      Button("OK", action: selection.cancel)
        .fontWeight(.semibold)
        .accessibilityLabel("Sair da seleção")
        .accessibilityIdentifier("sessions-selection-done")
    }
    .appFont(.secondary)
    .buttonStyle(.plain)
    .foregroundStyle(theme.color(.textAccent))
    .frame(minHeight: 32)
  }

  private func symbol(_ name: String, color: ThemeRole) -> some View {
    Image(systemName: name).appSymbol(.header).foregroundStyle(theme.color(color))
      .frame(width: 48, height: 48).contentShape(Circle())
  }
}
