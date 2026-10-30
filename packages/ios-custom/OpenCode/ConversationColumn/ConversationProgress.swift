import OpenCodeKit
import SwiftUI

/// Progresso above the tray, shared by the iPhone and the Mac: `◔ 3/7 · current item`, opening the whole list (a
/// sheet on the iPhone, a popover on the Mac). It shows only while `ConversationStore.progress` does: the session
/// itself executes and its list still has an open item (`plugin-app-custom/docs/progress.md`).
struct ConversationProgressPill: View {
  @Environment(\.appTheme) private var theme
  let progress: SessionProgress
  @State private var open = false
  #if DEBUG
  /// The Mac offline checks (`MacAjustesChecks.progresso`) run without an accessibility client: the pill's spoken
  /// label while one is on screen, and a request that opens it.
  static var shown: String?
  static let openRequest = Notification.Name("OpenCodeProgressOpen")
  #endif

  private var label: String {
    "Progresso: \(progress.done) de \(progress.total)\(progress.current.map { ". Agora: \($0.content)" } ?? "")"
  }

  var body: some View {
    Button { open = true } label: {
      HStack(spacing: 8) {
        ConversationProgressRing(fraction: progress.fraction, color: theme.color(.primary),
          track: theme.color(.border))
          .frame(width: 15, height: 15)
        Text(progress.count).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
        if let current = progress.current {
          Text(current.content).foregroundStyle(theme.color(.text)).lineLimit(1).truncationMode(.tail)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.color(.textSecondary))
      }
      .appFont(.footnote)
      .padding(.horizontal, 14).padding(.vertical, 9)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("conversation-progress")
    #if DEBUG
    .onAppear { Self.shown = label }
    .onChange(of: label) { Self.shown = label }
    .onDisappear { Self.shown = nil }
    .onReceive(NotificationCenter.default.publisher(for: Self.openRequest)) { _ in open = true }
    #endif
    #if os(macOS)
    .popover(isPresented: $open, arrowEdge: .top) {
      ConversationProgressList(progress: progress).frame(width: 360).padding(.vertical, 10)
    }
    #else
    .sheet(isPresented: $open) {
      ConversationProgressList(progress: progress, close: { open = false })
        .padding(.top, 18)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.color(.background))
    }
    #endif
  }
}

/// The whole list: `Progresso · 3 de 7`, then every item with its state.
struct ConversationProgressList: View {
  @Environment(\.appTheme) private var theme
  let progress: SessionProgress
  var close: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Progresso").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Text("\(progress.done) de \(progress.total)").appFont(.footnote).monospacedDigit()
          .foregroundStyle(theme.color(.textSecondary))
        Spacer(minLength: 0)
        if let close {
          Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
              .foregroundStyle(theme.color(.textSecondary)).frame(width: 30, height: 30)
              .background(theme.color(.surface), in: Circle())
          }
          .buttonStyle(.plain).accessibilityLabel("Fechar")
        }
      }
      .padding(.horizontal, 16)
      GeometryReader { proxy in
        // A short bar of the ring's fill, one segment per item like the mockups.
        HStack(spacing: 3) {
          ForEach(Array(progress.items.enumerated()), id: \.offset) { _, item in
            Capsule().fill(theme.color(item.status.finished ? .primary : .border))
              .frame(width: max((proxy.size.width - 3 * CGFloat(progress.total - 1)) / CGFloat(max(progress.total, 1)), 2))
          }
        }
      }
      .frame(height: 5).padding(.horizontal, 16).accessibilityHidden(true)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(progress.items.enumerated()), id: \.offset) { index, item in
            row(item, current: item == progress.current)
              .accessibilityIdentifier("conversation-progress-item-\(index)")
          }
        }
        .padding(.horizontal, 8)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .accessibilityIdentifier("conversation-progress-list")
  }

  private func row(_ item: SessionProgress.Item, current: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      glyph(item.status).frame(width: 18)
      Text(item.content)
        .strikethrough(item.status == .cancelled)
        .appFont(.secondary, weight: current ? .semibold : .regular)
        .foregroundStyle(theme.color(color(item.status, current: current)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 8).padding(.vertical, 8)
    .background(current ? theme.color(.surface) : .clear, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label(item.status)): \(item.content)")
  }

  @ViewBuilder private func glyph(_ status: SessionProgress.Status) -> some View {
    switch status {
    case .completed:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.color(.textSecondary))
    case .inProgress:
      ConversationProgressRing(fraction: 0.35, color: theme.color(.primary), track: theme.color(.border))
        .frame(width: 15, height: 15)
    case .pending:
      Image(systemName: "circle.dashed").foregroundStyle(theme.color(.textSecondary))
    case .cancelled:
      Image(systemName: "xmark").foregroundStyle(theme.color(.textWeak))
    }
  }

  private func color(_ status: SessionProgress.Status, current: Bool) -> ThemeRole {
    if current { return .textStrong }
    switch status {
    case .completed: return .textSecondary
    case .cancelled: return .textWeak
    case .inProgress, .pending: return .text
    }
  }

  private func label(_ status: SessionProgress.Status) -> String {
    switch status {
    case .completed: "Concluída"
    case .inProgress: "Em andamento"
    case .pending: "Pendente"
    case .cancelled: "Cancelada"
    }
  }
}

/// The small ring of the pill and of the Sessões row: `fraction` of a circle in `color` over a track.
struct ConversationProgressRing: View {
  let fraction: Double
  let color: Color
  let track: Color

  var body: some View {
    ZStack {
      Circle().stroke(track, lineWidth: 2)
      Circle().trim(from: 0, to: max(min(fraction, 1), 0.04))
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(1)
    .accessibilityHidden(true)
  }
}
