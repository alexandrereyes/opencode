import OpenCodeKit
import SwiftUI

/// The three-line row of "Precisa de você" and "Trabalhando".
struct SessionRowView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let row: SessionRow
  let preview: SessionPreview
  let directory: SessionDirectoryLabel?
  @Environment(\.sessionRowsMixChats) private var mixChats
  /// A chat beside repository sessions reads "Chats" where they read their path and branch.
  private var line: SessionDirectoryLabel? { row.sharesChatAvatar(mixed: mixChats) ? .chats : directory }
  /// The colored state line of a "Precisa de você" row, shown instead of the preview.
  var detail: String? = nil
  /// Its color, from the row's reason there (an unread answer, or a row held open, has no state color).
  var detailTint: ThemeRole? = nil

  private var status: (text: String, tint: ThemeRole)? {
    if row.state == .running, let progress = row.progress {
      return ("trabalhando · \(progress.count)\(progress.current.map { " " + $0.content } ?? "")", .success)
    }
    if row.state == .running { return (row.workingStatus(activity: preview.activity), .success) }
    if let detail, let tint = detailTint ?? row.state.tint { return (detail, tint) }
    return nil
  }

  var body: some View {
    HStack(spacing: AppLayout.avatarGap) {
      SessionAvatar(row: row, size: AppLayout.avatar)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(row.session.displayTitle)
            .appFont(.heading, weight: row.unread ? .bold : .regular)
            .foregroundStyle(theme.color(.textStrong))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
          Spacer(minLength: 0)
          SessionRowTime(at: row.interactionAt, unread: row.unread)
        }
        SessionDirectoryLine(label: line)
        HStack(spacing: 7) {
          if let status {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Circle().fill(theme.color(status.tint)).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) {
                $0[VerticalAlignment.center] + 4
              }
              if row.state == .running, let progress = row.progress {
                // `trabalhando · ◔ 3/7 item…`: the item truncates, the ring and the count stay.
                Text("trabalhando ·").foregroundStyle(theme.color(status.tint)).layoutPriority(1)
                ConversationProgressRing(fraction: progress.fraction, color: theme.color(.primary),
                  track: theme.color(.border))
                  .frame(width: 12, height: 12)
                  .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text("\(progress.count)\(progress.current.map { " " + $0.content } ?? "")")
                  .monospacedDigit().foregroundStyle(theme.color(status.tint))
              } else {
                Text(status.text).foregroundStyle(theme.color(status.tint))
              }
            }
            .appFont(.preview)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(
              "\(preview.image ? Text("\(Image(systemName: "photo")) ").foregroundColor(theme.color(.icon)) : Text(""))\(Text(preview.text).foregroundColor(theme.color(.textPreview)))"
            )
            .appFont(.preview)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          // The tinted state line already flags a request or failure; an unread answer keeps its dot.
          SessionRowMarks(row: row, dot: detail == nil || row.state.tint == nil)
        }.padding(.top, 1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.session.displayTitle), \(SessionList.relativeTime(row.interactionAt, now: now).accessibilityLabel)\(line.map { ", " + $0.accessibilityLabel } ?? ""), \(status?.text ?? preview.text)\(row.unread ? ", não lida" : "")\(row.pinned ? ", fixada" : "")\(row.notify ? ", avisa ao terminar" : "")"
    )
  }
}

/// The two-line row of "Fixadas", the days and "Anteriores": title and time, then `path · branch`.
struct SessionCompactRowView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let row: SessionRow
  let directory: SessionDirectoryLabel?
  @Environment(\.sessionRowsMixChats) private var mixChats
  /// A chat beside repository sessions reads "Chats" where they read their path and branch.
  private var line: SessionDirectoryLabel? { row.sharesChatAvatar(mixed: mixChats) ? .chats : directory }
  /// Adds a "trabalhando" line under a running row (the session switcher, which has no Trabalhando section).
  var showsWorking = false

  var body: some View {
    HStack(spacing: AppLayout.avatarGap) {
      SessionAvatar(row: row, size: AppLayout.compactAvatar)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(row.session.displayTitle)
            .appFont(.preview, weight: row.unread ? .bold : .regular)
            .foregroundStyle(theme.color(row.unread ? .textStrong : .text))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
          Spacer(minLength: 0)
          SessionRowTime(at: row.interactionAt, unread: row.unread)
        }
        if line != nil || row.notify || row.pinned || row.unread {
          HStack(spacing: 7) {
            SessionDirectoryLine(label: line).frame(maxWidth: .infinity, alignment: .leading)
            SessionRowMarks(row: row)
          }
        }
        if showsWorking && row.state == .running {
          HStack(spacing: 6) {
            Circle().fill(theme.color(.success)).frame(width: 7, height: 7)
            Text("trabalhando").appFont(.caption)
          }.foregroundStyle(theme.color(.success))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.session.displayTitle), \(SessionList.relativeTime(row.interactionAt, now: now).accessibilityLabel)\(line.map { ", " + $0.accessibilityLabel } ?? "")\(showsWorking && row.state == .running ? ", trabalhando" : "")\(row.unread ? ", não lida" : "")\(row.pinned ? ", fixada" : "")\(row.notify ? ", avisa ao terminar" : "")"
    )
  }
}

/// "Avisar ao terminar" and pinned icons and the unread dot, trailing a row's last line.
private struct SessionRowMarks: View {
  @Environment(\.appTheme) private var theme
  let row: SessionRow
  var dot = true

  var body: some View {
    if row.notify {
      Image(systemName: "bell.fill").appSymbol(.inline).foregroundStyle(theme.color(.icon))
        .accessibilityIdentifier("session-row-bell")
    }
    if row.pinned {
      Image(systemName: "pin.fill").appSymbol(.inline).foregroundStyle(theme.color(.icon))
    }
    if row.unread && dot {
      Circle().fill(theme.color(.primary)).frame(width: 8, height: 8)
    }
  }
}

extension SessionState {
  /// The color of a "Precisa de você" state: its line, row tint and avatar badge.
  var tint: ThemeRole? {
    switch self {
    case .permission: .warning
    case .question: .accent
    case .failed: .error
    default: nil
    }
  }
}

extension SessionAttention.Reason {
  /// The color of a "Precisa de você" line; an unread answer uses the unread dot's orange.
  var tint: ThemeRole {
    switch self {
    case .permission: .warning
    case .question: .accent
    case .failed: .error
    case .replied: .primary
    }
  }
}

struct SessionAvatar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.sessionRowsMixChats) private var mixChats
  let row: SessionRow
  let size: CGFloat

  var body: some View {
    let colors = theme.avatar(SessionList.avatarColor(row.project, fallback: row.session.projectID))
    ZStack {
      // Beside repository sessions every chat shares one avatar: a conversation symbol on the theme's chat color.
      // Under the Chats filter chats keep their monograms; a project's own icon replaces its monogram. All keep the
      // same arc and badges.
      if row.sharesChatAvatar(mixed: mixChats) {
        Circle().fill(theme.color(.chatAvatar))
        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: size * 0.38, weight: .semibold))
          .foregroundStyle(theme.color(.chatAvatarSymbol))
      } else if !row.chat, let icon = ProjectIcon.of(row.project) {
        ProjectIconAvatar(icon: icon, size: size)
      } else {
        Circle().fill(colors.background)
        Text(SessionList.monogram(row.projectName)).appFont(.message, weight: .medium)
          .minimumScaleFactor(0.6).lineLimit(1)
          .foregroundStyle(colors.text)
      }
      if row.state == .running { RunningArc(size: size + 5).allowsHitTesting(false) }
    }
    .frame(width: size, height: size)
    .overlay(alignment: .bottomTrailing) {
      if row.activeChildren > 0 {
        Text("+\(row.activeChildren)").appFont(.micro, weight: .semibold).monospacedDigit()
          .foregroundStyle(theme.color(.textStrong))
          .padding(4).background(theme.color(.surfaceRaised), in: Capsule())
          .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 1 / displayScale) }
          .offset(x: 3, y: 2)
      } else if let tint = row.state.tint {
        Image(
          systemName: row.state == .permission ? "shield.fill" : row.state == .question ? "questionmark" : "exclamationmark"
        )
        .appSymbol(.disclosure, weight: .semibold)
        .foregroundStyle(theme.color(.background))
        .frame(width: 18, height: 18)
        .background(theme.color(tint), in: Circle())
        .overlay { Circle().strokeBorder(theme.color(.background), lineWidth: 2) }
        .offset(x: 2, y: 2)
      }
    }
    .accessibilityHidden(true)
  }
}

struct RunningArc: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let size: CGFloat
  var filled = false
  @State private var rotating = false

  var body: some View {
    #if os(macOS)
    // Core Animation turns it on the Mac: a SwiftUI `repeatForever` re-renders the whole window every frame.
    MacSpinningArc(from: 0.05, to: 0.5, color: theme.nsColor(.success), lineWidth: filled ? 1 : 1.7, period: 3,
      animated: !reduceMotion, fill: filled ? theme.nsColor(.success) : nil, fillInset: 1.5)
      .frame(width: size, height: size)
    #else
    ZStack {
      if filled { Circle().fill(theme.color(.success)).padding(1.5) }
      Circle().trim(from: 0.05, to: 0.5)
        .stroke(
          theme.color(.success), style: StrokeStyle(lineWidth: filled ? 1 : 1.7, lineCap: .round)
        )
        .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
        .animation(
          reduceMotion ? nil : .linear(duration: 3).repeatForever(autoreverses: false),
          value: rotating)
    }
    .frame(width: size, height: size)
    .onAppear { rotating = true }
    #endif
  }
}

private struct SessionRowsMixChatsKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  /// Rows listing chats beside repository sessions ("Todas", a state filter, the session switcher), not the Chats
  /// filter.
  var sessionRowsMixChats: Bool {
    get { self[SessionRowsMixChatsKey.self] }
    set { self[SessionRowsMixChatsKey.self] = newValue }
  }
}
