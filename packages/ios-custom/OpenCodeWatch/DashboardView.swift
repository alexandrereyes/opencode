import OpenCodeKit
import SwiftUI
import WatchKit

/// Painel (`app-1-painel.png`, Option A of 29/10): ring and counts with the age of the state, then "Precisa de
/// você" (requests open Responder) and a collapsed `Trabalhando N` that lists the working sessions; the microphone
/// starts voice. Refreshes on coming to the front, every 10 s while visible and on pull; in the background the app
/// refresh keeps the cache current (`BackgroundRefresh`).
///
/// The list takes the whole screen and the microphone floats over its bottom trailing corner (rev. 30/10: an opaque
/// inset band used to reserve that strip, which cut the list at the button's height and left it empty below). A
/// transparent bottom strip, which the list scrolls under, moves the list's end up so the last row clears the button.
struct DashboardView: View {
  @Environment(\.scenePhase) private var scenePhase
  let model: WatchModel
  let voice: VoiceCall
  @State private var reply: ReplyRoute?
  @State private var showVoice = false
  // The `progress` and `many` capture fixtures open on their working sessions.
  @State private var showWorking = WatchFixture.combo == .progress || WatchFixture.combo == .many

  var body: some View {
    NavigationStack {
      content
        .navigationDestination(item: $reply) { route in ReplyView(model: model, route: route) }
        .navigationDestination(isPresented: $showVoice) { VoiceView(call: voice, pairing: model.pairing) }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Text("OpenCode").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.watch(.primary))
          }
        }
    }
    .task(id: scenePhase) {
      // While visible: refresh now and every 10 s. In the background, `BackgroundRefresh` takes over.
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        await model.refreshNow()
        try? await Task.sleep(for: .seconds(10))
      }
    }
    .onChange(of: voice.phase) { _, phase in
      if phase != .idle { showVoice = true }
    }
  }

  @ViewBuilder private var content: some View {
    if model.pairing == nil {
      Message(title: model.connection == .unauthorized ? "Pareamento expirado" : "Sem pareamento",
        text: "Abra o OpenCode no iPhone para parear")
    } else if model.connection == .loading && model.entry == nil {
      ProgressView().tint(Color.watch(.primary))
    } else {
      ScrollViewReader { proxy in
      List {
        header.listRowBackground(Color.clear)
        if model.connection == .unreachable {
          offline.listRowBackground(Color.clear)
        }
        ForEach(rows) { row in
          Group {
            switch row {
            case .attention(let item):
              Button { reply = ReplyRoute(attention: item) } label: { AttentionRow(item: item) }
                .listRowBackground(Card(tint: item.kind == .permission ? .warning : .accent, outlined: true))
            case .need(let item):
              // No navigation for sessions in v1: no chevron, not a button.
              NeedRow(item: item).listRowBackground(Card(tint: item.kind.role, outlined: true))
            case .working(let count):
              Button { showWorking.toggle() } label: { WorkingRow(count: count, expanded: showWorking) }
                .listRowBackground(Card(tint: nil, outlined: false))
            case .session(let session):
              SessionRow(row: session, unread: model.state?.counts.unread != nil)
                .listRowBackground(Card(tint: nil, outlined: false))
            }
          }.id(row.id)
        }
        if rows.isEmpty {
          Text("Nenhuma sessão ativa").font(.footnote).foregroundStyle(Color.watch(.textSecondary))
            .listRowBackground(Color.clear).id(Self.emptyID)
        }
      }
      .listStyle(.plain)
      .refreshable { await model.refreshNow() }
      // The list keeps the whole screen and scrolls under this transparent strip; only its end moves up, so the last
      // row can rise above the button. (`contentMargins` does not move a watchOS List's end.)
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Self.clearance).allowsHitTesting(false) }
      .overlay(alignment: .bottomTrailing) { microphone }
      .task {
        guard WatchFixture.launch?.screen == .dashboardEnd else { return }
        try? await Task.sleep(for: .milliseconds(300))
        // Anchoring the last row at the top scrolls as far as the list goes, the strip included.
        proxy.scrollTo(rows.last?.id ?? Self.emptyID, anchor: .top)
      }
      }
    }
  }

  private var rows: [WatchDashboardRow] { model.state?.dashboardRows(working: showWorking) ?? [] }

  static let emptyID = "empty"
  static let microphoneSize: CGFloat = 44
  /// How far the button reaches below the bottom safe area, into the screen's rounded corner (as before 30/10).
  static let microphoneDrop: CGFloat = 14
  /// Without it the last row ends at the bottom safe area, where the button rises `microphoneSize - microphoneDrop`
  /// (30 points): the strip adds that and a gap of about 10 points.
  static let clearance: CGFloat = microphoneSize - microphoneDrop + 8

  /// The floating microphone. During a call it shows a waveform and leads back to the call.
  private var microphone: some View {
    let calling = voice.phase == .live || voice.phase == .connecting
    return Button { showVoice = true } label: {
      Image(systemName: calling ? "waveform" : "mic.fill").font(.system(size: 19))
        .foregroundStyle(Color.watch(calling ? .success : .primary))
        .symbolEffect(.variableColor.iterative, isActive: voice.phase == .live)
    }
    .buttonStyle(.glass).buttonBorderShape(.circle).frame(width: Self.microphoneSize, height: Self.microphoneSize)
    .padding(.trailing, 6).offset(y: Self.microphoneDrop)
    .accessibilityLabel(calling ? "Voltar à conversa com a Sessão mestra" : "Falar com a Sessão mestra")
    .accessibilityIdentifier("watch-voice")
  }

  /// 40 and 41 mm screens: the counts go below the ring across the width, since beside it `3 trabalhando` would not
  /// fit even shrunk; 42 mm and up keep them beside the ring.
  private static let compact = WKInterfaceDevice.current().screenBounds.width < 180

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        let ring: CGFloat = Self.compact ? 54 : 62
        WatchRingView(state: model.state, lineWidth: 6, numberSize: Self.compact ? 23 : 26)
          .frame(width: ring, height: ring)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.state?.forYouLabel ?? model.state?.workingLabel ?? "0 trabalhando")
            .font(.system(size: Self.compact ? 17 : 19, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
            .lineLimit(1).minimumScaleFactor(0.6)
          if !Self.compact { legend }
        }
        // Its own height and the rest of the row's width: proposed less, the title shrank to make room.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if Self.compact { legend }
      if let fetched = model.entry?.fetched {
        // Below the ring, across the width; re-rendered when `agora` turns into the relative age.
        TimelineView(.periodic(from: fetched, by: WatchAge.fresh)) { context in
          HStack(spacing: 3) {
            Text("Atualizado")
            WatchAgeText(fetched: fetched, now: context.date)
          }
          .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.watch(.textSecondary)).lineLimit(1)
        }
        .accessibilityIdentifier("watch-age")
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  /// `2 não lidas ·` / `3 trabalhando`: lines break between the counts, never inside one.
  private var legend: some View {
    ItemFlow {
      let parts = model.state?.complicationDetail == nil ? ["nada para você"] : model.state?.forYouParts ?? []
      ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
        Text(index < parts.count - 1 ? part + " ·" : part).lineLimit(1).minimumScaleFactor(0.7)
      }
    }
    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textSecondary))
  }

  /// The header already says how old the state is.
  private var offline: some View {
    Label("Mac indisponível", systemImage: "wifi.slash").font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Color.watch(.warning))
  }
}

struct ReplyRoute: Hashable {
  let attention: AgentsState.Attention
}

private struct Card: View {
  let tint: ThemeRole?
  let outlined: Bool
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    shape.fill(tint.map { Color.watch($0).opacity(0.22) } ?? Color.watch(.surfaceRaised).opacity(0.9))
      .overlay { if outlined, let tint { shape.strokeBorder(Color.watch(tint).opacity(0.7), lineWidth: 1) } }
      .padding(.vertical, 2)
  }
}

private struct AttentionRow: View {
  let item: AgentsState.Attention
  var body: some View {
    let role: ThemeRole = item.kind == .permission ? .warning : .accent
    HStack(spacing: 10) {
      Image(systemName: item.kind == .permission ? "hand.raised.fill" : "questionmark")
        .font(.system(size: 16, weight: .bold)).foregroundStyle(Color.watch(role))
        .frame(width: 32, height: 32).background(Circle().fill(Color.watch(role).opacity(0.25)))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(1).minimumScaleFactor(0.8)
        Text("\(item.kind == .permission ? "permissão" : "pergunta") · \(Text(.currentDate, format: AgentsText.ago(since: item.asked)))")
          .font(.system(size: 12)).foregroundStyle(Color.watch(.textSecondary)).lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.watch(.textSecondary))
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("watch-attention-\(item.sessionID)")
  }
}

/// A failure or an unread answer in "Precisa de você": the attention row's look, without Responder.
private struct NeedRow: View {
  let item: AgentsState.Need
  var body: some View {
    let role = item.kind.role
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(Color.watch(role).opacity(0.25))
        if let symbol = item.kind.status.watchSymbol {
          Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.watch(role))
        } else {
          Circle().fill(Color.watch(role)).frame(width: 12, height: 12)
        }
      }.frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(1).minimumScaleFactor(0.8)
        Group {
          if let date = item.date {
            Text("\(item.kind.label) · \(Text(.currentDate, format: AgentsText.ago(since: date)))")
          } else {
            Text(item.kind.label)
          }
        }
        .font(.system(size: 12)).foregroundStyle(Color.watch(.textSecondary)).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("watch-need-\(item.sessionID)")
  }
}

/// `● Trabalhando   6 ›`: the working sessions, collapsed below "Precisa de você".
private struct WorkingRow: View {
  let count: Int
  let expanded: Bool
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(Color.watch(.success)).frame(width: 10, height: 10).frame(width: 32)
      // It used to break inside the word ("Trabalhand" / "o"); on 40 mm it shrinks to fit beside the count.
      Text("Trabalhando").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
        .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
      Spacer(minLength: 0)
      Text(verbatim: "\(count)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
        .foregroundStyle(Color.watch(.textSecondary))
      Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.watch(.textSecondary))
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("watch-working")
  }
}

private struct SessionRow: View {
  let row: AgentsState.Row
  /// The backend sends `counts.unread`, so `idle` rows are unread sessions.
  let unread: Bool
  var body: some View {
    let role = row.statusRole(unread: unread)
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(Color.watch(.surface))
        if let symbol = row.status.watchSymbol {
          Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.watch(role))
        } else {
          Circle().fill(Color.watch(role)).frame(width: 12, height: 12)
        }
      }.frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(1).minimumScaleFactor(0.8)
        Text(row.statusLabel(unread: unread)).font(.system(size: 12)).foregroundStyle(Color.watch(role)).lineLimit(1)
          .monospacedDigit()
        // The item in hand of the session's Progresso (rev. 2026-10-30).
        if let now = row.progress?.now {
          Text(verbatim: "Agora: \(now)").font(.system(size: 12)).foregroundStyle(Color.watch(.textSecondary))
            .lineLimit(2).accessibilityIdentifier("watch-progress-now")
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }
}

/// Items left to right, a whole item moving to the next line when it does not fit; an item wider than a line on its
/// own gets the line's width (with `lineLimit(1)` and a scale factor it shrinks instead of breaking). Without a
/// proposed width it stacks them, so its ideal width is its widest item.
struct ItemFlow: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    let frames = arrange(width: proposal.width ?? widest, subviews)
    return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews)) {
      subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(width: CGFloat, _ subviews: Subviews) -> [CGRect] {
    var frames: [CGRect] = []
    var origin = CGPoint.zero
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let ideal = subview.sizeThatFits(.unspecified)
      let size = ideal.width <= width ? ideal : subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if origin.x > 0 && origin.x + size.width > width {
        origin = CGPoint(x: 0, y: origin.y + lineHeight)
        lineHeight = 0
      }
      frames.append(CGRect(origin: origin, size: size))
      origin.x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return frames
  }
}

struct Message: View {
  let title: String
  let text: String
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        WatchMascot().frame(width: 48)
        Text(title).font(.headline).foregroundStyle(Color.watch(.textStrong))
        Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(Color.watch(.textSecondary))
      }.padding(.top, 8)
    }
  }
}
