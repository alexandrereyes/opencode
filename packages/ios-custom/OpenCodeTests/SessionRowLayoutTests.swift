import SwiftUI
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class SessionRowLayoutTests: XCTestCase {
  func testSharedTimelineTicksOncePerMinuteOnlyWhileVisible() {
    let start = Date(timeIntervalSince1970: 1_792_684_800)
    XCTAssertEqual(
      Array(SessionRowSchedule(active: true).entries(from: start, mode: .normal).prefix(3)),
      [start, start.addingTimeInterval(60), start.addingTimeInterval(120)])
    XCTAssertEqual(
      Array(SessionRowSchedule(active: false).entries(from: start, mode: .normal)), [start])
  }

  private func row(_ title: String, directory: String, message: Double? = nil) throws -> SessionRow
  {
    let entry = try JSONDecoder().decode(
      NavigationEntry.self,
      from: Data(
        """
        {"session":{"id":"ses_\(title)","title":"\(title)","projectID":"repo",
        "location":{"directory":"\(directory)"},"time":{"created":1792584000000,"updated":1792684000000}}
        \(message.map { ",\"messageAt\":\($0)" } ?? "")}
        """.utf8))
    return try XCTUnwrap(
      SessionList.rows(
        entries: [entry], projects: [], active: [], pins: [], notify: [], autoApprove: false,
        ranks: [:], chatRoot: nil
      ).first)
  }

  func testLongDirectoryAndBranchStayOnOneLineAndCaptureRealRows() async throws {
    let directory = "/home/server/Worktrees/projeto-com-um-caminho-bastante-longo/checkout-final"
    let long = SessionDirectoryLabel(
      path: SessionDirectoryLabel.abbreviate(directory, home: "/home/server"),
      branch: "feat/uma-branch-com-um-nome-bastante-longo-para-conferir-truncamento")
    let short = SessionDirectoryLabel(path: "~/repo", branch: "main")
    for mode in ["dark", "light"] {
      let theme = AppTheme.load("openchamber-" + mode)
      for width in [240.0, 340.0] {
        let heights = [short, long].map { label in
          let host = UIHostingController(
            rootView: SessionDirectoryLine(label: label).environment(\.appTheme, theme))
          return host.sizeThatFits(in: CGSize(width: width, height: 1000)).height
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5)
        XCTAssertLessThan(heights[1], 24)
      }
    }
    let outside = "/private/var/folders/tmp/repos/ios-conversation"
    try await capture(
      [
        (try row("Diretório principal", directory: "/home/server/repo"), short),
        (
          try row("Checkout da worktree", directory: "/home/server/Worktrees/feat-x"),
          SessionDirectoryLabel(path: "~/Worktrees/feat-x", branch: "feat/x")
        ),
        (try row("Conversa sem repositório", directory: "/chats/pessoal"), nil),
        (try row("Caminho e branch longos", directory: directory), long),
        (
          try row("Fora da pasta pessoal", directory: outside),
          SessionDirectoryLabel(
            path: SessionDirectoryLabel.abbreviate(outside, home: "/home/server"),
            branch: "neon-mountain")
        ),
      ], name: "rows-root-worktree-chat-long")
  }

  func testProductionLikeHomePaths() async throws {
    // Actual directory samples from the GET-only audit; branch labels are local fixture values.
    let paths = [
      ("Abacato", "/Users/alexandremartins/Dev/Abacato", "main"),
      ("Abacato v2", "/Users/alexandremartins/Dev/abacato-v2", "main"),
      (
        "Compromissos", "/Users/alexandremartins/Worktrees/abacato-v2-feat-compromissos",
        "feat/compromissos"
      ),
      (
        "Telemetria", "/Users/alexandremartins/Worktrees/abacato-v2-feat-telemetria",
        "feat/telemetria"
      ),
    ]
    try await capture(
      paths.map { title, path, branch in
        let display = SessionDirectoryLabel.abbreviate(path, home: "/Users/alexandremartins")
        XCTAssertTrue(display.hasPrefix("~/"))
        return (
          try row(title, directory: path), SessionDirectoryLabel(path: display, branch: branch)
        )
      }, name: "rows-production-home-paths")
  }

  private func capture(_ rows: [(row: SessionRow, directory: SessionDirectoryLabel?)], name: String)
    async throws
  {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    UIView.setAnimationsEnabled(false)
    defer {
      UIView.setAnimationsEnabled(true)
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    for mode in ["dark", "light"] {
      let theme = AppTheme.load("openchamber-" + mode)
      window.rootViewController = UIHostingController(
        rootView:
          NavigationStack {
            List(rows, id: \.row.id) { item in
              SessionRowView(row: item.row, preview: SessionPreview(), directory: item.directory)
                .listRowBackground(theme.color(.background))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(theme.color(.background)).navigationTitle("Sessões")
          }
          .background(ThemeChrome(theme: theme))
          .environment(\.appTheme, theme)
          .environment(\.sessionRowDate, Date(timeIntervalSince1970: 1_792_684_800))
          .preferredColorScheme(mode == "dark" ? .dark : .light))
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      await Task.yield()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = name + "-" + mode
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
}
