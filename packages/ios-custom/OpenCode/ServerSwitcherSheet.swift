import OpenCodeKit
import SwiftUI

/// The server list of Sessões' title (approved option B, 3 November): the current server with its connection, the
/// others to switch to (name and address only: their state is not monitored), then Gerenciar, Adicionar and Ler QR
/// code, the editor and the reader Você ▸ Servidores already uses. A switch from here stays in Sessões.
struct ServerSwitcherSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let runtime: AppRuntime
  let store: SessionStore
  /// Gerenciar servidores: Você ▸ Servidores opens once this sheet has closed.
  let manage: () -> Void
  @State private var request: SavedServer?
  @State private var adding = false
  @State private var pairing = false
  @State private var error: String?

  var body: some View {
    let servers = runtime.servers
    let entries = ServerSwitcher.entries(servers.servers, activeID: servers.activeID)
    let connection = ServerSwitcher.Connection(connected: store.connected, failed: store.error != nil)
    NavigationStack {
      List {
        if let current = entries.first(where: \.active) {
          Section("Atual") {
            row(current, detail: connection.label + " · " + current.address, connection: connection)
              .accessibilityElement(children: .combine)
              .accessibilityAddTraits(.isSelected)
              .accessibilityIdentifier("server-current")
          }
        }
        let others = entries.filter { !$0.active }
        if !others.isEmpty {
          Section("Trocar para") {
            ForEach(others) { entry in
              Button {
                if runtime.callActive { request = entry.server } else { choose(entry.server) }
              } label: { row(entry, detail: entry.address, connection: nil) }
              .buttonStyle(.plain)
              .accessibilityIdentifier("server-switch-" + entry.id)
            }
          }
        }
        Section {
          HStack(spacing: 8) {
            action("Gerenciar", symbol: "gearshape", id: "server-manage") {
              manage()
              dismiss()
            }
            action("Adicionar", symbol: "plus", id: "server-add-header") { adding = true }
            action("QR code", symbol: "qrcode.viewfinder", id: "server-pair-header") { pairing = true }
          }
          .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
        } footer: {
          Text("Trocar fecha a conversa aberta; rascunhos e posições de leitura ficam salvos por servidor.")
        }
      }
      .settingsList(theme, voice: false)
      .navigationTitle("Servidores").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Fechar", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("server-sheet-close")
        }
      }
      .serverSwitchConfirmation($request, perform: choose)
      .alert("Não foi possível trocar de servidor", isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
      .sheet(isPresented: $adding) { ServerEditor(servers: servers, server: nil).sessionAlertOverlay() }
      .sheet(isPresented: $pairing) { PairingSheet(servers: servers).sessionAlertOverlay() }
    }
    // Tall enough for the actions under a few servers; more of them scroll, or the sheet grows to full height.
    .presentationDetents([.fraction(min(0.9, 0.52 + 0.09 * Double(max(0, runtime.servers.servers.count - 1)))), .large])
    .presentationDragIndicator(.visible)
  }

  private func row(_ entry: ServerSwitcher.Entry, detail: String, connection: ServerSwitcher.Connection?) -> some View {
    HStack(spacing: 12) {
      ServerAvatar(entry: entry, size: 36, dot: connection?.role)
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.server.title).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          .lineLimit(2)
        Text(detail).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if entry.active {
        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(theme.color(.primary))
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  private func action(_ title: String, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) {
      Label(title, systemImage: symbol).appFont(.secondary, weight: .medium).lineLimit(1).minimumScaleFactor(0.8)
        .foregroundStyle(theme.color(.textStrong))
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(theme.color(.surface), in: Capsule())
        .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 0.7) }
        .contentShape(Capsule())
    }
    .buttonStyle(.borderless)
    .accessibilityIdentifier(id)
  }

  private func choose(_ server: SavedServer) {
    do {
      try runtime.select(server, fromSettings: false)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

extension View {
  /// Asks before a switch would end the voice call, like the Mac's `MacServerConfirmation`: Cancelar keeps the call
  /// and the server; Trocar ends the call through the normal switch.
  func serverSwitchConfirmation(_ request: Binding<SavedServer?>, perform: @escaping (SavedServer) -> Void) -> some View {
    alert("Trocar para \(request.wrappedValue?.title ?? "outro servidor")?", isPresented: Binding(
      get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
      presenting: request.wrappedValue
    ) { server in
      Button("Trocar") {
        request.wrappedValue = nil
        perform(server)
      }
      Button("Cancelar", role: .cancel) { request.wrappedValue = nil }
    } message: { server in
      Text("A conversa por voz será encerrada. Sessões passa a mostrar as de \(server.title); rascunhos e posições de leitura ficam salvos por servidor.")
    }
  }
}
