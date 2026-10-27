import AppKit
import OpenCodeKit
import SwiftUI

/// The chat's composer, like the iPhone's: `Pergunte qualquer coisa…`, then `+`, the model and MCP capsules
/// (`composerCapsule()`) and the microphone, which turns into Enviar once there is text. Below it,
/// `● build ⌄ · Contexto 28% · 278,6k / 1M · ⚡ Cache 99,5%`.
struct MacComposer: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: MacTranscriptStore
  @FocusState private var focused: Bool

  private var empty: Bool { store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(spacing: 7) {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Pergunte qualquer coisa…", text: $store.draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...8)
          .appFont(.message)
          .focused($focused)
          .onSubmit { Task { await store.send() } }
          .disabled(store.selectedModel == nil)
          .padding(.horizontal, 4).padding(.top, 2)
        HStack(spacing: 8) {
          attach
          model
          if MCPSummary(store.mcp).visible { mcp }
          Spacer(minLength: 4)
          action
        }
      }
      .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
      .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      usage
    }
  }

  private var attach: some View {
    Menu {
      Button("Inserir caminho de arquivo…", systemImage: "doc") { insertPath() }
    } label: {
      Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(.text))
        .frame(width: 28, height: 28)
        .overlay { Circle().strokeBorder(theme.color(.controlBorder), lineWidth: 0.7) }
        .contentShape(Circle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Adicionar")
    .accessibilityLabel("Adicionar")
  }

  /// `Opus 5.5 · xhigh`: the model and its effort for the next prompt.
  private var model: some View {
    Menu {
      ForEach(store.models.filter { $0.enabled != false }, id: \.identity) { info in
        let variants = info.variants ?? []
        if variants.isEmpty {
          Button(info.name) { store.model = ModelReference(id: info.id, providerID: info.providerID) }
        } else {
          Menu(info.name) {
            ForEach(variants) { variant in
              Button(variant.id) {
                store.model = ModelReference(id: info.id, providerID: info.providerID, variant: variant.id)
              }
            }
          }
        }
      }
    } label: {
      Text(store.selectedModel.map(store.modelLabel) ?? "Modelo").appFont(.chrome).lineLimit(1)
        .foregroundStyle(theme.color(.text))
        .composerCapsule(horizontal: 9)
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Modelo e esforço")
  }

  /// `● MCP · 1/4 ⌄`: the session's MCP servers, each one switched on or off from the menu.
  private var mcp: some View {
    let summary = MCPSummary(store.mcp)
    return Menu {
      ForEach(MCPServer.ordered(store.mcp)) { server in
        Toggle(isOn: Binding(get: { server.status.status == .connected }, set: { _ in Task { await store.toggle(server) } })) {
          Text(server.name + (server.status.status == .connected ? "" : " · " + server.status.status.label))
        }
        .disabled(store.acting.contains("mcp:" + server.name))
      }
    } label: {
      HStack(spacing: 4) {
        Circle().fill(theme.color(summary.connected > 0 ? .success : .textWeak)).frame(width: 5, height: 5)
        Text(summary.label).monospacedDigit()
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .appFont(.mcp).foregroundStyle(theme.color(.textSecondary))
      .composerCapsule()
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel(summary.accessibilityLabel)
  }

  /// The microphone starts the system's dictation in the field; with text, Enviar.
  @ViewBuilder private var action: some View {
    if empty {
      Button {
        focused = true
        DispatchQueue.main.async { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
      } label: {
        circle("mic.fill")
      }
      .buttonStyle(.plain)
      .help("Ditar (ditado do macOS)")
      .accessibilityLabel("Ditar")
    } else {
      Button {
        Task { await store.send() }
      } label: {
        circle(store.sending ? "hourglass" : "arrow.up")
      }
      .buttonStyle(.plain)
      .disabled(store.sending)
      .help("Enviar (Return)")
      .accessibilityLabel("Enviar")
    }
  }

  private func circle(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(theme.color(.onPrimary))
      .frame(width: 32, height: 32).background(theme.color(.primary), in: Circle())
  }

  /// `● build ⌄ · Contexto 28% · 278,6k / 1M · ⚡ Cache 99,5%`.
  private var usage: some View {
    let usage = store.usage
    return HStack(spacing: 6) {
      Menu {
        ForEach(store.primaryAgents, id: \.id) { agent in
          Button(agent.name) { store.agent = agent.id }
        }
      } label: {
        HStack(spacing: 4) {
          Circle().fill(agentColor).frame(width: 6, height: 6)
          Text(store.primaryAgents.first { $0.id == store.selectedAgent }?.name ?? store.selectedAgent)
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(theme.color(.text))
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .help("Agente")
      Text("·").foregroundStyle(theme.color(.textWeak))
      if let usage {
        ContextUsageRing(usage: usage, size: 10)
        Text(usage.contextLabel + " · " + usage.tokenLabel)
      } else {
        Text("Contexto —")
      }
      Text("·").foregroundStyle(theme.color(.textWeak))
      Image(systemName: "bolt.fill").font(.system(size: 9))
        .foregroundStyle(theme.color((store.cacheHit ?? 1) < ContextColumn.cacheWarning ? .warning : .textSecondary))
      Text("Cache " + (store.cacheHit.map(ContextColumn.percent) ?? "—"))
    }
    .appFont(.footnote).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
  }

  private var agentColor: Color {
    let agent = store.agents.first { $0.id == store.selectedAgent }
    return theme.agentColor(agent, id: store.selectedAgent)
  }

  /// Puts a file's path, relative to the session, in the prompt.
  private func insertPath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    if let directory = store.session?.location.directory { panel.directoryURL = URL(fileURLWithPath: directory) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let directory = store.session?.location.directory ?? ""
    let path = url.path.hasPrefix(directory + "/") ? String(url.path.dropFirst(directory.count + 1)) : url.path
    store.draft += (store.draft.isEmpty || store.draft.hasSuffix(" ") ? "" : " ") + path + " "
    focused = true
  }
}
