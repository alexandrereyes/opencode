import OpenCodeKit
import SwiftUI
import WatchKit

/// Responder (`app-3-responder-pergunta.png`): one large button per option (recommended first, orange),
/// dictation for free text, or the permission decisions. Success returns to the dashboard with a haptic.
struct ReplyView: View {
  @Environment(\.dismiss) private var dismiss
  let model: WatchModel
  let route: ReplyRoute

  @State private var request: WatchRequest?
  @State private var failure: String?
  @State private var sending = false
  /// Multiple-choice or multi-question forms collect answers before "Enviar".
  @State private var selections: [String: Set<String>] = [:]
  @State private var texts: [String: String] = [:]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        header
        if let request {
          switch request {
          case .question(let question) where request.answerableOnWatch: questionBody(question)
          case .question: phoneOnly
          case .permission(let permission): permissionBody(permission)
          }
        } else if failure == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 12)
        }
        if let failure {
          Text(failure).font(.footnote).foregroundStyle(Color.watch(.error)).padding(.top, 4)
            .accessibilityIdentifier("watch-reply-error")
        }
      }
    }
    .disabled(sending)
    .task { await load() }
  }

  private var kind: AgentsState.Kind { route.attention.kind }
  private var role: ThemeRole { kind == .permission ? .warning : .accent }

  private var header: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: kind == .permission ? "hand.raised.fill" : "questionmark")
        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.watch(.textStrong))
        .frame(width: 24, height: 24).background(Circle().fill(Color.watch(role)))
      VStack(alignment: .leading, spacing: 1) {
        Text(route.attention.title).font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.watch(.textStrong)).lineLimit(2)
        Text("\(route.attention.project) · \(Text(.currentDate, format: AgentsText.ago(since: route.attention.asked)))")
          .font(.system(size: 12)).foregroundStyle(Color.watch(.textSecondary))
      }
    }
  }

  @ViewBuilder private func questionBody(_ question: WatchRequest.Question) -> some View {
    let immediate = question.questions.count == 1 && !question.questions[0].multiple
    ForEach(question.questions) { field in
      Text(field.text).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.watch(.textStrong))
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.watch(.accent).opacity(0.2))
          .strokeBorder(Color.watch(.accent).opacity(0.7), lineWidth: 1))
      ForEach(field.orderedOptions) { option in
        let selected = selections[field.id]?.contains(option.id) == true
        Button {
          if immediate {
            send(.question([.init(questionID: field.id, optionIDs: [option.id])]))
          } else {
            toggle(option.id, in: field)
          }
        } label: {
          Text(option.recommended == true ? "\(option.label) (Recomendado)" : option.label)
            .font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
            .foregroundStyle(option.recommended == true ? Color.watch(.onPrimary) : Color.watch(.textStrong))
        }
        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        .tint(option.recommended == true ? Color.watch(.primary) : (selected ? Color.watch(.accent) : Color.watch(.surfaceRaised)))
        .accessibilityIdentifier("watch-option-\(option.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      if field.allowText {
        TextFieldLink(prompt: Text("Diga a resposta")) {
          Label(texts[field.id].map { "“\($0)”" } ?? "Responder por voz", systemImage: "mic.fill")
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.watch(.primary))
            .frame(maxWidth: .infinity)
        } onSubmit: { text in
          let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { return }
          if immediate {
            send(.question([.init(questionID: field.id, text: text)]))
          } else {
            texts[field.id] = text
          }
        }
        .accessibilityIdentifier("watch-dictate-\(field.id)")
      }
    }
    if !immediate {
      Button("Enviar") { send(.question(answers(question))) }
        .buttonStyle(.borderedProminent).tint(Color.watch(.primary))
        .disabled(question.questions.contains { selections[$0.id]?.isEmpty ?? true && texts[$0.id] == nil })
    }
  }

  @ViewBuilder private func permissionBody(_ permission: WatchRequest.Permission) -> some View {
    Text(permission.summary).font(.system(size: 15, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.watch(.textStrong)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.watch(.warning).opacity(0.2))
        .strokeBorder(Color.watch(.warning).opacity(0.7), lineWidth: 1))
    decision("Permitir uma vez", .once, tint: .primary)
    decision("Sempre permitir", .always, tint: .surfaceRaised)
    decision("Negar", .reject, tint: .error)
  }

  private func decision(_ title: String, _ value: WatchReply.Decision, tint: ThemeRole) -> some View {
    Button { send(.permission(value)) } label: {
      Text(title).font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity)
        .foregroundStyle(tint == .primary ? Color.watch(.onPrimary) : Color.watch(.textStrong))
    }
    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).tint(Color.watch(tint))
    .accessibilityIdentifier("watch-decision-\(value.rawValue)")
  }

  private var phoneOnly: some View {
    Text("Este formulário só pode ser respondido no iPhone.").font(.footnote)
      .foregroundStyle(Color.watch(.textSecondary))
  }

  private func toggle(_ option: String, in field: WatchRequest.Field) {
    var set = selections[field.id] ?? []
    if field.multiple {
      if !set.insert(option).inserted { set.remove(option) }
    } else {
      set = [option]
    }
    selections[field.id] = set
  }

  private func answers(_ question: WatchRequest.Question) -> [WatchReply.Answer] {
    question.questions.map { field in
      let options = selections[field.id].map { Array($0) }
      return WatchReply.Answer(questionID: field.id, optionIDs: options?.isEmpty == false ? options : nil,
        text: texts[field.id])
    }
  }

  private func load() async {
    if model.fixture {
      request = route.attention.kind == .permission ? WatchFixture.permission : WatchFixture.question
      return
    }
    guard let requestID = route.attention.requestID else {
      failure = "Este pedido precisa ser respondido no iPhone."
      return
    }
    guard let client = model.client else { return }
    do {
      request = try await client.request(requestID)
    } catch let error as WatchGatewayError {
      failure = error.message
    } catch {
      failure = WatchGatewayError.unreachable.message
    }
  }

  private func send(_ reply: WatchReply) {
    guard let request, !sending else { return }
    if model.fixture {
      WKInterfaceDevice.current().play(.success)
      dismiss()
      return
    }
    guard let client = model.client else { return }
    sending = true
    Task {
      defer { sending = false }
      do {
        try await client.reply(request.requestID, reply)
        WKInterfaceDevice.current().play(.success)
        model.refresh()
        dismiss()
      } catch let error as WatchGatewayError {
        WKInterfaceDevice.current().play(.failure)
        failure = error.message
        if error == .gone { model.refresh() }
      } catch {
        WKInterfaceDevice.current().play(.failure)
        failure = WatchGatewayError.unreachable.message
      }
    }
  }
}
