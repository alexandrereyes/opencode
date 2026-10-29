import SwiftUI
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class ResponseTableMemoryTests: XCTestCase {
  func testGridAndCellsScrollTogetherAndRebuiltTableRestoresItsColumns() async throws {
    let source = "| First long column | Second long column | Third long column |\n| --- | --- | --- |\n| abcdefghijklmnopqrstuvwxyz | abcdefghijklmnopqrstuvwxyz | abcdefghijklmnopqrstuvwxyz |"
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first { $0.kind == .table })
    let table = try XCTUnwrap(block.table)
    let memory = TranscriptMemory()
    let suite = "table-memory-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: "OpenCodeMarkdownTableWrap")
    defer { defaults.removePersistentDomain(forName: suite) }
    @MainActor func content(_ version: Int) -> some View {
      ResponseTable(block: block, table: table, source: source, messageID: "message", partID: "part",
        rasters: [:], openNote: { _ in })
        .environment(ToastCenter()).environment(\.transcriptMemory, memory)
        .defaultAppStorage(defaults).frame(width: 300).id(version)
    }
    let host = UIHostingController(rootView: content(0))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    window.layoutIfNeeded()
    let first = try XCTUnwrap(find(host.view))
    XCTAssertGreaterThan(first.contentSize.width - first.bounds.width, 80)
    let gridBefore = first.grid.convert(.zero, to: host.view).x
    let cellBefore = first.cells[0][0].convert(.zero, to: host.view).x
    first.contentOffset.x = 80
    first.layoutIfNeeded()
    XCTAssertEqual(first.grid.convert(.zero, to: host.view).x, gridBefore - 80, accuracy: 0.5)
    XCTAssertEqual(first.cells[0][0].convert(.zero, to: host.view).x, cellBefore - 80, accuracy: 0.5)
    XCTAssertEqual(memory.tableOffset(first.identity), 80, accuracy: 0.5)
    host.rootView = content(1)
    let start = ContinuousClock.now
    while find(host.view) === first, start.duration(to: .now) < .seconds(3) {
      try await Task.sleep(for: .milliseconds(10))
      window.layoutIfNeeded()
    }
    let rebuilt = try XCTUnwrap(find(host.view))
    XCTAssertFalse(rebuilt === first)
    XCTAssertEqual(rebuilt.contentOffset.x, 80, accuracy: 0.5)
    XCTAssertTrue(rebuilt.grid.superview === rebuilt)
    XCTAssertEqual(rebuilt.grid.frame.size, rebuilt.contentSize)
  }

  private func find(_ view: UIView) -> ResponseTableView? {
    if let table = view as? ResponseTableView { return table }
    return view.subviews.lazy.compactMap { self.find($0) }.first
  }
}
