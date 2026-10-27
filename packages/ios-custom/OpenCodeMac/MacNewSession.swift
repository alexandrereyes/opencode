import OpenCodeKit
import SwiftUI

/// A minimal Nova sessão for this first Mac version: a repository from the filter chips (its main checkout),
/// the first prompt, the default agent and the model chosen as default for new sessions. Worktrees, MCPs,
/// chats and the model picker stay on the iPhone and the web until the full composer is ported.
struct MacNewSession: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacRuntime
  @State private var project: String?
  @State private var text = ""
  @State private var sending = false
  @State private var error: String?

  private var model: ModelReference? {
    store.preferences?.data.models?.default.map {
      ModelReference(id: $0.modelID, providerID: $0.providerID, variant: $0.variant)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Nova sessão").font(.title3.bold())
      Picker("Repositório", selection: $project) {
        ForEach(store.selectedProjects, id: \.directory) { item in
          Text(item.project.displayName).tag(Optional(item.directory))
        }
      }
      TextField("O que fazer?", text: $text, axis: .vertical)
        .lineLimit(4...10)
        .textFieldStyle(.roundedBorder)
      Text(model.map { "Agente build · \($0.id)\($0.variant.map { " · " + $0 } ?? "")" }
        ?? "Escolha um modelo padrão para novas sessões no app web ou no iPhone.")
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      if let error { Text(error).appFont(.caption).foregroundStyle(theme.color(.error)) }
      HStack {
        Spacer()
        Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(sending ? "Enviando…" : "Enviar") { Task { await send() } }
          .keyboardShortcut(.defaultAction)
          .disabled(project == nil || model == nil || sending
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20).frame(width: 520)
    .onAppear { project = project ?? store.selectedProjects.first?.directory }
  }

  private func send() async {
    guard let directory = project, let model,
      let selected = store.selectedProjects.first(where: { $0.directory == directory }) else { return }
    sending = true
    defer { sending = false }
    let submission = NewSessionSubmission(
      projectID: selected.project.id, root: directory, destination: .root, branch: nil, intents: [:],
      agent: "build", model: model)
    let prompt = text
    do {
      _ = try await submission.send(using: store.client) { _ in
        PromptRequest(text: prompt, delivery: .steer, agent: "build", model: model)
      }
      await store.reload()
      runtime.selection = MacSelection(sessionID: submission.id)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
