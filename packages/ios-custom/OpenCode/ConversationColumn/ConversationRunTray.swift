import OpenCodeKit
import SwiftUI

/// The running line of the tray: `Opus 5.5 · trabalhando · 2m14s`, then Background and Parar.
struct ConversationRunTrayRun {
  let model: String
  /// Epoch milliseconds of the execution's first step; nil hides the elapsed time.
  let started: Double?
  /// Nil when nothing can move to the background.
  let background: (() -> Void)?
  let backgroundBusy: Bool
  let stop: () -> Void
  let stopping: Bool
}

struct ConversationRunTrayItem: Identifiable {
  let id: String
  let text: String
  /// The server knows the item and no action on it is in flight.
  let actionable: Bool
}

/// The card above the composer, shared by the iPhone and future Mac conversations: what is running, then
/// one line per queued message (`Na fila: …`, Editar, Enviar agora and ×). It is absent when both are empty.
struct ConversationRunTray: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var queueHeight: CGFloat = 150
  let run: ConversationRunTrayRun?
  let queue: [ConversationRunTrayItem]
  var editDisabled = false
  let sendNow: (ConversationRunTrayItem) -> Void
  let edit: (ConversationRunTrayItem) -> Void
  let remove: (ConversationRunTrayItem) -> Void

  var body: some View {
    if run != nil || !queue.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        if let run { running(run) }
        if !queue.isEmpty {
          if run != nil { separator }
          // Up to three queued lines size to their rows; longer queues scroll inside about three and a half.
          if queue.count > 3 {
            ScrollView { rows }.frame(height: queueHeight)
          } else {
            rows
          }
        }
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.text))
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color(.border), lineWidth: 0.7) }
    }
  }

  private var separator: some View {
    Rectangle().fill(theme.color(.border)).frame(height: 0.7)
  }

  private func running(_ run: ConversationRunTrayRun) -> some View {
    HStack(spacing: 10) {
      Circle().fill(theme.color(.success)).frame(width: 9, height: 9).accessibilityHidden(true)
      TimelineView(.periodic(from: run.started == nil ? .distantFuture : .now, by: 1)) { context in
        let elapsed = run.started.map { ConversationProjection.duration(context.date.timeIntervalSince1970 * 1000 - $0) }
        Text("\(Text(run.model)) · \(Text("trabalhando").foregroundStyle(theme.color(.success)))\(Text(elapsed.map { " · " + $0 } ?? ""))")
          .foregroundStyle(theme.color(.textSecondary)).monospacedDigit()
          .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.85)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("tray-running")
      }
      if let background = run.background {
        Button("Background", action: background)
          .foregroundStyle(theme.color(.textSecondary)).disabled(run.backgroundBusy)
          .padding(.vertical, 6).contentShape(Rectangle())
      }
      Button(action: run.stop) {
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2.5).fill(theme.color(.error)).frame(width: 11, height: 11)
          Text("Parar").foregroundStyle(theme.color(.error))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.color(.background).opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.color(.controlBorder), lineWidth: 0.7) }
        .contentShape(Rectangle())
      }
      .accessibilityLabel("Parar").disabled(run.stopping)
    }
    .appFont(.footnote)
    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
  }

  private var rows: some View {
    VStack(spacing: 0) {
      ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
        if index > 0 { separator.padding(.leading, 40) }
        queued(item)
      }
    }
  }

  @ViewBuilder private func queued(_ item: ConversationRunTrayItem) -> some View {
    let text = HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "hourglass").appSymbol(.inline, weight: .regular).foregroundStyle(theme.color(.icon))
        .frame(width: 16).accessibilityHidden(true)
      Text("\(Text("Na fila: ").foregroundStyle(theme.color(.textSecondary)))\(Text(item.text))")
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    let actions = HStack(spacing: 14) {
      Button("Editar") { edit(item) }.disabled(editDisabled)
        .accessibilityLabel("Editar mensagem da fila")
      Button("Enviar agora") { sendNow(item) }.foregroundStyle(theme.color(.primary))
      Button { remove(item) } label: {
        Image(systemName: "xmark").appSymbol(.inline).foregroundStyle(theme.color(.textSecondary))
          .frame(width: 24, height: 28).contentShape(Rectangle())
      }.accessibilityLabel("Remover mensagem da fila")
    }.fixedSize()
    Group {
      // Accessibility sizes keep the text readable on its own line, actions below it.
      if typeSize.isAccessibilitySize {
        VStack(alignment: .trailing, spacing: 6) { text; actions }
      } else {
        HStack(spacing: 12) { text; actions }
      }
    }
    .appFont(.footnote)
    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
    .disabled(!item.actionable)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tray-queued-" + item.id)
  }
}
