import AppKit
import OpenCodeKit
import SwiftUI

/// Pergunta paralela (the selection menu, `…`, Sessão ▸ Pergunta paralela… ⌥⌘B, `/btw`): the iPhone's
/// `SideQuestionSheet` on the Mac. The shared `SideQuestionState` asks `POST /generate` with the session's context
/// and model, keeps up to five earlier answers as context and saves nothing to the conversation; closing (Fechar,
/// Esc or a click outside) discards the thread. A selected passage arrives as the question's blockquote.
struct MacSideQuestionSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let launch: SideQuestionLaunch
  @State private var state: SideQuestionState

  init(store: ConversationStore, launch: SideQuestionLaunch) {
    self.store = store
    self.launch = launch
    _state = State(initialValue: SideQuestionState(text: launch.text))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(state.entries) { entry in
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  Spacer(minLength: 80)
                  SideQuestionBubble(text: entry.question).appFont(.message).textSelection(.enabled)
                    .foregroundStyle(theme.color(.userBubbleText))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.color(.userBubble), in: RoundedRectangle(cornerRadius: 14))
                }
                if !entry.answer.isEmpty {
                  MacMarkdownText(text: entry.answer)
                  Button("Copiar resposta", systemImage: "doc.on.doc") { copy(entry.answer) }
                    .buttonStyle(.plain).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                }
                if state.pending == entry.id {
                  HStack(spacing: 10) {
                    AgentPixels(color: theme.color(.primary))
                    Text("Pensando…").appFont(.secondary)
                    Spacer()
                    Button("Parar", systemImage: "stop.fill") { state.stop() }.buttonStyle(.plain)
                  }
                  .foregroundStyle(theme.color(.textSecondary))
                }
                if state.failed == entry.id {
                  Button("Tentar novamente", systemImage: "arrow.clockwise") { state.ask(store: store, retry: entry.id) }
                    .buttonStyle(.plain).appFont(.secondary).foregroundStyle(theme.color(.primary))
                }
              }
              .id(entry.id)
            }
            Color.clear.frame(height: 1).id("side-bottom")
          }
          .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .macThinScrollers()
        .onChange(of: state.entries) { _, _ in proxy.scrollTo("side-bottom", anchor: .bottom) }
        .onChange(of: state.pending) { _, _ in proxy.scrollTo("side-bottom", anchor: .bottom) }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      // The card sits on the opaque background, as in the conversation; the fade softens the answer under it.
      VStack(spacing: 0) {
        LinearGradient(colors: [theme.color(.background).opacity(0), theme.color(.background)],
          startPoint: .top, endPoint: .bottom)
          .frame(height: 12).allowsHitTesting(false)
        composer.padding([.horizontal, .bottom], 16).background(theme.color(.background))
      }
    }
    .frame(width: 680, height: 600)
    .background(theme.color(.background))
    .toastOverlay(state.toast)
    .task { if launch.submit { state.ask(store: store) } }
    .onDisappear { state.stop(restore: false) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Pergunta paralela").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
            .background(theme.color(.surface), in: Circle())
            .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.7) }
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.text))
        .keyboardShortcut(.cancelAction).help("Fechar (esc)").accessibilityLabel("Fechar")
      }
      Text("Usa o contexto e o modelo desta sessão. Não fica salva na conversa.")
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
    }
    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 6)
  }

  /// The composer in its `reply` mode: dictation and the right Option key, Return asks, Esc closes.
  private var composer: some View {
    MacReplyComposer(store: store, text: $state.text, placeholder: "Pergunte em paralelo…", features: .reply,
      canSubmit: canSubmit, submit: submit, cancel: { dismiss() }, focusOnAppear: true,
      identifier: "side-question-composer",
      accessory: AnyView(Text(store.modelLabel(store.session?.model)).appFont(.caption)
        .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)))
      .accessibilityElement(children: .contain).accessibilityIdentifier("side-question-card")
  }

  private var canSubmit: Bool {
    state.pending == nil && !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && store.ready && store.session?.model != nil
  }

  private func submit() {
    guard canSubmit else { return }
    state.ask(store: store)
  }

  private func copy(_ answer: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(answer, forType: .string)
    state.toast.show("Resposta copiada")
  }
}
