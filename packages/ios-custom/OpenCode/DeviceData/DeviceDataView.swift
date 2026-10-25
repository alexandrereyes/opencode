import OpenCodeKit
import SwiftUI

/// "Você → Dados do iPhone": one switch per source the Sessão mestra may read on demand.
struct DeviceDataView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  let agent: DeviceAgent
  var body: some View {
    List {
      Section {
        Label(agent.connected ? "Conectado ao servidor" : "Sem conexão com o servidor",
          systemImage: agent.connected ? "checkmark.circle" : "wifi.slash")
          .foregroundStyle(theme.color(agent.connected ? .success : .textSecondary))
          .accessibilityIdentifier("device-data-connection")
      } footer: {
        Text("A Sessão mestra lê estes dados na hora, com o app aberto ou durante a conversa por voz. Com o app fechado, ela recebe que o iPhone está offline.")
      }.listRowBackground(theme.color(.surface))
      Section("Fontes") {
        ForEach(DeviceSource.allCases) { source in row(source) }
      }.listRowBackground(theme.color(.surface))
    }
    .settingsList(theme).navigationTitle("Dados do iPhone").navigationBarTitleDisplayMode(.inline)
    .task { await agent.refreshAuthorizations() }
  }

  private func row(_ source: DeviceSource) -> some View {
    let authorization = agent.authorizations[source] ?? .notDetermined
    return VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: Binding(get: { agent.enabled.contains(source) }, set: { value in
        Task { await agent.setEnabled(source, value) }
      })) {
        Label(source.label, systemImage: source.icon)
      }.accessibilityIdentifier("device-source-" + source.rawValue)
      Text(source.detail).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      Text(status(source, authorization)).appFont(.caption)
        .foregroundStyle(theme.color(authorization == .denied || authorization == .restricted ? .warning : .textSecondary))
        .accessibilityIdentifier("device-source-status-" + source.rawValue)
      if agent.enabled.contains(source), authorization == .denied,
        let url = URL(string: UIApplication.openSettingsURLString)
      {
        Button("Abrir Ajustes") { openURL(url) }.appFont(.caption)
      }
    }.padding(.vertical, 3)
  }

  private func status(_ source: DeviceSource, _ authorization: DeviceAuthorization) -> String {
    let permission = source == .device || source == .network ? "Sem permissão necessária" : authorization.label
    let last = agent.answered[source].map { "Última consulta " + $0.formatted(.relative(presentation: .named)) }
      ?? "Nenhuma consulta respondida"
    return permission + " · " + last
  }
}
