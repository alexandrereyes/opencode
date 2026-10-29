import OpenCodeKit
import SwiftUI

/// Ajustes → Dados do Mac: one switch per source the OpenCode agents may read on demand (`mac_query`), with the
/// macOS permission of each, like the iPhone's Dados do iPhone.
struct MacDataSettings: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  let agent: MacDataAgent
  var body: some View {
    Form {
      Section {
        if MacDataAgent.active {
          Label(agent.connected ? "Conectado ao servidor" : "Sem conexão com o servidor",
            systemImage: agent.connected ? "checkmark.circle.fill" : "network.slash")
            .foregroundStyle(theme.color(agent.connected ? .success : .textSecondary))
        } else {
          Label("Esta versão de desenvolvimento não responde aos agentes; só o app instalado responde.",
            systemImage: "hammer")
            .foregroundStyle(theme.color(.warning))
        }
      } footer: {
        Text("Os agentes do OpenCode leem estes dados na hora, quando você pede, enquanto o app está aberto neste Mac. Com o app fechado, eles recebem que o Mac está offline.")
          .foregroundStyle(theme.color(.textSecondary))
      }
      Section("Fontes") {
        ForEach(MacDataSource.allCases) { row($0) }
      }
    }
    .formStyle(.grouped)
    .onAppear { agent.refreshPermissions() }
  }

  private func row(_ source: MacDataSource) -> some View {
    let permission = agent.permissions[source] ?? .notDetermined
    return VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: Binding(get: { agent.enabled.contains(source) }, set: { value in
        Task { await agent.setEnabled(source, value) }
      })) {
        Label(source.label, systemImage: source.icon)
      }
      Text(source.detail).font(.caption).foregroundStyle(theme.color(.textSecondary))
      HStack(spacing: 8) {
        Text(status(source, permission)).font(.caption)
          .foregroundStyle(theme.color(permission == .denied || permission == .restricted ? .warning : .textSecondary))
        if agent.enabled.contains(source), permission == .notDetermined {
          Button("Pedir permissão") { Task { await agent.requestPermission(source) } }.controlSize(.small)
        }
        if agent.enabled.contains(source), permission == .denied, let url = privacyPane(source) {
          Button("Abrir Ajustes do Sistema") { openURL(url) }.controlSize(.small)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func status(_ source: MacDataSource, _ permission: MacDataPermission) -> String {
    let last = agent.answered[source].map { "Última consulta " + $0.formatted(.relative(presentation: .named)) }
      ?? "Nenhuma consulta respondida"
    return permission.label + " · " + last
  }

  private func privacyPane(_ source: MacDataSource) -> URL? {
    let pane = switch source {
    case .calendar: "Privacy_Calendars"
    case .reminders: "Privacy_Reminders"
    case .contacts: "Privacy_Contacts"
    }
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
  }
}
