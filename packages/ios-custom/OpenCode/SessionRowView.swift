import OpenCodeKit
import SwiftUI

struct SessionRowView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let row: SessionRow
  let preview: SessionPreview
  let directory: SessionDirectoryLabel?

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
        SessionDirectoryLine(label: directory)
        HStack(spacing: 7) {
          Text(
            "\(preview.image && row.state != .running ? Text("\(Image(systemName: "photo")) ").foregroundColor(theme.color(.icon)) : Text(""))\(Text(row.state == .running ? "trabalhando · \(preview.activity ?? "pensando")" : preview.text).foregroundColor(theme.color(row.state == .running ? .success : .textPreview)))"
          )
          .appFont(.preview)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
          .frame(maxWidth: .infinity, alignment: .leading)
          if row.muted {
            Image(systemName: "bell.slash.fill").appSymbol(.inline).foregroundStyle(
              theme.color(.icon))
          }
          if row.pinned {
            Image(systemName: "pin.fill").appSymbol(.inline).foregroundStyle(
              theme.color(.icon))
          }
          if row.unread {
            Circle().fill(theme.color(row.muted ? .textWeak : .primary)).frame(
              width: 8, height: 8)
          }
        }.padding(.top, 1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(row.session.displayTitle), \(SessionList.relativeTime(row.interactionAt, now: now).accessibilityLabel)\(directory.map { ", " + $0.accessibilityLabel } ?? ""), \(row.state == .running ? "trabalhando" : preview.text)\(row.unread ? ", não lida" : "")\(row.pinned ? ", fixada" : "")\(row.muted ? ", silenciada" : "")"
    )
  }
}

struct SessionAvatar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let row: SessionRow
  let size: CGFloat

  var body: some View {
    let colors = theme.avatar(SessionList.avatarColor(row.project, fallback: row.session.projectID))
    ZStack {
      Circle().fill(colors.background)
      Text(SessionList.monogram(row.projectName)).appFont(.message, weight: .medium)
        .minimumScaleFactor(0.6).lineLimit(1)
        .foregroundStyle(colors.text)
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
      } else if row.state == .permission || row.state == .question {
        Image(systemName: row.state == .permission ? "shield.fill" : "questionmark")
          .appSymbol(.disclosure, weight: .semibold)
          .foregroundStyle(theme.color(.background))
          .frame(width: 18, height: 18)
          .background(theme.color(row.state == .permission ? .error : .info), in: Circle())
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
  }
}
