import Observation
import OpenCodeKit
import SwiftUI

struct SideQuestionLaunch: Identifiable {
  let id = UUID()
  let text: String
  var submit = false
}

@MainActor @Observable private final class SideQuestionState {
  var text: String
  var entries: [SideQuestionEntry] = []
  var pending: UUID?
  var failed: UUID?
  let toast = ToastCenter()
  @ObservationIgnored private var task: Task<Void, Never>?
  init(text: String) { self.text = text }
  func ask(store: ConversationStore, retry: UUID? = nil) {
    guard pending == nil else { return }
    let entry =
      retry.flatMap { id in entries.first { $0.id == id } }
      ?? SideQuestionEntry(question: text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !entry.question.isEmpty else { return }
    Haptics.play(.light)
    if retry == nil {
      entries.append(entry)
      text = ""
    }
    pending = entry.id
    failed = nil
    let request = SideQuestionRequest(
      question: entry.question, history: entries.filter { $0.id != entry.id })
    task = Task { [self] in
      do {
        let answer = try await store.askSideQuestion(request)
        try Task.checkCancellation()
        guard !answer.isEmpty else { throw SideQuestionError.empty }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
          entries[index].answer = answer
        }
      } catch {
        guard !Task.isCancelled else { return }
        failed = entry.id
        toast.show("Não foi possível responder à pergunta paralela.", kind: .error) { [weak self] in
          self?.ask(store: store, retry: entry.id)
        }
      }
      pending = nil
      task = nil
    }
  }
  func stop(restore: Bool = true) {
    task?.cancel()
    task = nil
    if restore, let id = pending, let entry = entries.first(where: { $0.id == id }), text.isEmpty {
      text = entry.question
    }
    if let id = pending { entries.removeAll { $0.id == id } }
    pending = nil
  }
  private enum SideQuestionError: Error { case empty }
}

struct SideQuestionSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let launch: SideQuestionLaunch
  @State private var state: SideQuestionState
  @State private var focused = false
  @State private var detent = PresentationDetent.large
  init(store: ConversationStore, launch: SideQuestionLaunch) {
    self.store = store
    self.launch = launch
    _state = State(initialValue: SideQuestionState(text: launch.text))
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text("Usa o contexto e o modelo desta sessão. Não fica salva na conversa.")
          .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(
            .vertical, 12)
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              ForEach(state.entries) { entry in
                VStack(alignment: .leading, spacing: 18) {
                  HStack {
                    Spacer(minLength: 36)
                    SideQuestionBubble(text: entry.question).font(.body).textSelection(.enabled)
                      .foregroundStyle(theme.color(.userBubbleText)).padding(13)
                      .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 16))
                  }
                  if !entry.answer.isEmpty {
                    ResponseMarkdown(
                      text: entry.answer, messageID: entry.id.uuidString, partID: "answer")
                    Button("Copiar resposta", systemImage: "doc.on.doc") {
                      UIPasteboard.general.string = entry.answer
                      Haptics.play(.selection)
                      state.toast.show("Resposta copiada")
                    }.font(.caption).foregroundStyle(theme.color(.textSecondary))
                  }
                  if state.pending == entry.id {
                    HStack(spacing: 10) {
                      AgentPixels(color: theme.color(.primary))
                      Text("Pensando…").font(.subheadline)
                      Spacer()
                      Button("Parar", systemImage: "stop.fill") { state.stop() }
                    }.foregroundStyle(theme.color(.textSecondary))
                  }
                  if state.failed == entry.id {
                    Button("Tentar novamente", systemImage: "arrow.clockwise") {
                      state.ask(store: store, retry: entry.id)
                    }
                    .font(.subheadline)
                  }
                }.id(entry.id)
              }
              theme.color(.background).opacity(0).frame(height: 1).id("side-bottom")
            }.padding(20)
          }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("side-question-scroll")
            .onChange(of: state.entries) { _, _ in proxy.scrollTo("side-bottom", anchor: .bottom) }
            .onChange(of: state.pending) { _, _ in proxy.scrollTo("side-bottom", anchor: .bottom) }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        // Like the conversation's composer, the card sits on the opaque background, so the answer
        // never shows through it; the fade softens the edge where the answer scrolls under it.
        VStack(spacing: 0) {
          LinearGradient(
            colors: [theme.color(.background).opacity(0), theme.color(.background)],
            startPoint: .top, endPoint: .bottom
          ).frame(height: 12).allowsHitTesting(false)
          composer.padding([.horizontal, .bottom], 12).background(theme.color(.background))
        }
      }
      .navigationTitle("Pergunta paralela").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Fechar", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
        }
      }
      .toastOverlay(state.toast)
      // Opens ready to type, like the expanded composer: focusing during the presentation stalled it.
      .background(ComposerCoverAppearance { focused = true }.frame(width: 0, height: 0))
    }
    .environment(state.toast).environment(\.responseSelection, nil).environment(
      \.responseSelectionChanged, nil
    )
    .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
    .presentationBackground(theme.color(.background)).tint(theme.color(.primary))
    .task { if launch.submit { state.ask(store: store) } }
    .onDisappear { state.stop(restore: false) }
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 12) {
      SideQuestionInput(
        text: $state.text, focused: $focused, theme: theme,
        canSubmit: canSubmit, submit: submit
      )
      .overlay(alignment: .topLeading) {
        if state.text.isEmpty {
          Text("Pergunte em paralelo…").foregroundStyle(theme.color(.textSecondary))
            .allowsHitTesting(false)
        }
      }
      HStack {
        Text(store.modelLabel(store.session?.model)).font(.system(size: 12))
          .foregroundStyle(theme.color(.textSecondary))
        Spacer()
        Button {
          submit()
        } label: {
          Image(
            systemName: state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? "mic.fill" : "arrow.up"
          )
          .font(.system(size: 19, weight: .medium)).foregroundStyle(theme.color(.onPrimary))
          .frame(width: 36, height: 36).background(theme.color(.primary), in: Circle())
        }.disabled(!canSubmit)
          .accessibilityLabel(state.text.isEmpty ? "Microfone" : "Enviar pergunta paralela")
          .accessibilityHint(state.text.isEmpty ? "Em breve" : "")
      }
    }.padding(14).background(
      theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 22)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color(.border), lineWidth: 0.7)
    }
    .accessibilityElement(children: .contain).accessibilityIdentifier("side-question-card")
  }
  private var canSubmit: Bool {
    state.pending == nil && !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && store.ready && store.session?.model != nil
  }
  private func submit() {
    guard canSubmit else { return }
    focused = false
    state.ask(store: store)
  }
}

private struct SideQuestionBubble: View {
  let text: String
  private var lines: [String] { text.components(separatedBy: "\n") }
  var body: some View {
    let quoted = lines.prefix { $0.hasPrefix("> ") }
    VStack(alignment: .leading, spacing: 10) {
      if !quoted.isEmpty {
        QuotedPassage(text: quoted.map { String($0.dropFirst(2)) }.joined(separator: "\n"))
      }
      let question = lines.dropFirst(quoted.count).joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      if !question.isEmpty { Text(question) }
    }
  }
}
