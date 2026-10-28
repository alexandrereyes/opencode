import Observation
import OpenCodeKit
import SwiftUI

/// The small amount of presentation state shared by the two native Lists. Rows keep live data; only their
/// order and section wait for the end of the gesture. No scroll offsets or view controllers are retained.
@MainActor @Observable final class SessionListPresentation {
  private(set) var order: SessionListOrder?
  private(set) var scrolling = false
  @ObservationIgnored private var desired: SessionListOrder?
  @ObservationIgnored private var available: Set<String>?
  #if DEBUG
  private(set) var fixtureHeld = false
  private(set) var fixtureApplied = false
  var fixtureShift: CGFloat?
  @ObservationIgnored var fixtureOffsets: [String: CGFloat] = [:]
  #endif

  func update(_ value: SessionListOrder, reset: Bool = false, available: Set<String>? = nil) {
    desired = value
    if let available { self.available = available }
    let next = order?.updating(to: value, idle: reset || !scrolling, available: self.available) ?? value
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeSessionListUpdates"),
      scrolling, !reset, let order, order != value { fixtureHeld = next == order }
    #endif
    guard next != order else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { order = next }
  }

  func phase(_ phase: ScrollPhase) {
    scrolling = phase != .idle
    if !scrolling, let desired {
      update(desired)
      #if DEBUG
      if fixtureHeld { fixtureApplied = order == desired }
      #endif
    }
  }
}

extension View {
  func sessionListScrolling(_ presentation: SessionListPresentation, store: SessionStore) -> some View {
    modifier(SessionListScrolling(presentation: presentation, store: store))
  }
}

private struct SessionListScrolling: ViewModifier {
  let presentation: SessionListPresentation
  let store: SessionStore
  #if DEBUG
  @State private var fixtureStarted = false
  #endif

  func body(content: Content) -> some View {
    content.onScrollPhaseChange { _, phase in
      presentation.phase(phase)
      #if DEBUG
      if phase == .interacting, !fixtureStarted,
        ProcessInfo.processInfo.arguments.contains("-OpenCodeSessionListUpdates") {
        fixtureStarted = true
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(350))
          let before = presentation.fixtureOffsets
          store.finishSessionListFixture()
          try? await Task.sleep(for: .milliseconds(150))
          presentation.fixtureShift = before.compactMap { id, y in
            presentation.fixtureOffsets[id].map { abs($0 - y) }
          }.max() ?? 0
        }
      }
      #endif
    }
    #if DEBUG
    .overlay(alignment: .bottomLeading) {
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeSessionListUpdates") {
        Text("held=\(presentation.fixtureHeld) applied=\(presentation.fixtureApplied) running=\(store.active.contains("ses_scroll_0000")) shift=\(presentation.fixtureShift.map { String(format: "%.1f", $0) } ?? "pending")")
          .font(.system(size: 1)).accessibilityIdentifier("session-list-fixture-report")
      }
    }
    #endif
  }
}

struct SessionListRowProbe: ViewModifier {
  let id: String
  let presentation: SessionListPresentation

  func body(content: Content) -> some View {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeSessionListUpdates") {
      content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
        presentation.fixtureOffsets[id] = $0
      }
    } else { content }
    #else
    content
    #endif
  }
}
