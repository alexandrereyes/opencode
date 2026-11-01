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

  /// A table that scrolls back gets its own cell views from the shared pool (already styled and laid out) and
  /// its cached geometry, another table reuses the pooled views instead of creating them, and another text size or
  /// wrapping measures again.
  func testTablesReuseCellViewsAndMeasureAgainForTextSizeAndWrap() async throws {
    let source = "| Coluna | Valor |\n| --- | ---: |\n| Uma descrição com várias palavras para quebrar | R$ 1.234,56 |"
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first { $0.kind == .table })
    let table = try XCTUnwrap(block.table)
    let suite = "table-pool-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    @MainActor func content(_ message: String, size: DynamicTypeSize = .large) -> AnyView {
      AnyView(ResponseTable(block: block, table: table, source: source, messageID: message, partID: "pool-part",
        rasters: [:], openNote: { _ in })
        .environment(ToastCenter()).environment(\.transcriptMemory, TranscriptMemory())
        .environment(\.dynamicTypeSize, size).defaultAppStorage(defaults).frame(width: 300))
    }
    let host = UIHostingController(rootView: content("pool-a"))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    @MainActor func show(_ root: AnyView) throws -> ResponseTableView {
      host.rootView = root
      window.layoutIfNeeded()
      return try XCTUnwrap(find(host.view))
    }
    window.layoutIfNeeded()
    let first = try XCTUnwrap(find(host.view))
    let views = first.cells.joined().map(ObjectIdentifier.init)
    let height = first.measure(first.bounds.width).height
    // Scrolled away (dismantled) and back: the same views, the same geometry.
    host.rootView = AnyView(Color.clear.frame(width: 300, height: 10))
    window.layoutIfNeeded()
    XCTAssertNil(find(host.view))
    let back = try show(content("pool-a"))
    XCTAssertFalse(back === first)
    XCTAssertEqual(back.cells.joined().map(ObjectIdentifier.init), views)
    XCTAssertEqual(back.measure(back.bounds.width).height, height, accuracy: 0.5)
    // A reused representable showing another table takes pooled views instead of creating new ones.
    let created = TranscriptCounters.created.load(ordering: .relaxed)
    _ = try show(content("pool-b"))
    _ = try show(content("pool-a"))
    XCTAssertEqual(TranscriptCounters.created.load(ordering: .relaxed), created)
    let larger = try show(content("pool-a", size: .accessibility3))
    XCTAssertGreaterThan(larger.measure(larger.bounds.width).height, height + 20)
    defaults.set(false, forKey: "OpenCodeMarkdownTableWrap")
    let unwrapped = try show(content("pool-a"))
    let layout = unwrapped.measure(unwrapped.bounds.width)
    XCTAssertGreaterThan(layout.width, unwrapped.bounds.width)
    XCTAssertLessThan(layout.height, height)
  }

  private func find(_ view: UIView) -> ResponseTableView? {
    if let table = view as? ResponseTableView { return table }
    return view.subviews.lazy.compactMap { self.find($0) }.first
  }
}
