import XCTest
import SwiftUI
@testable import OpenCodeKit
@testable import OpenCode

@MainActor final class AppTypographyTests: XCTestCase {
  func testSharedScaleHasAccessibleUIKitFontsAndBoundedChrome() {
    let standard = UITraitCollection(preferredContentSizeCategory: .large)
    let accessible = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    for style in AppTextStyle.allCases {
      let base = AppTypography.font(style, compatibleWith: standard)
      let large = AppTypography.font(style, compatibleWith: accessible)
      // UIFontMetrics rounds the base to whole points even in the default category.
      XCTAssertEqual(base.pointSize, style.size.rounded(), accuracy: 0.01)
      if style.maximumSize == nil { XCTAssertGreaterThan(large.pointSize, base.pointSize) }
      else { XCTAssertEqual(large.pointSize, base.pointSize) }
      XCTAssertGreaterThanOrEqual(AppTypography.lineHeight(style, compatibleWith: accessible), large.lineHeight)
    }
  }

  func testBodyAndUserMessageHaveOneConsistentScale() {
    XCTAssertEqual(AppTextStyle.body.size, 17)
    XCTAssertEqual(AppTextStyle.body.lineHeight, 22.5)
    XCTAssertEqual(AppTextStyle.message.size, 17)
    XCTAssertEqual(AppTextStyle.message.lineHeight, 22.5)
    XCTAssertEqual(AppTextStyle.largeTitle.size, 34)
    XCTAssertEqual(AppTextStyle.title.size, 20)
    XCTAssertEqual(AppTextStyle.heading.size, 17)
    XCTAssertEqual(AppTextStyle.path.size, 13)
    XCTAssertEqual(AppTextStyle.preview.size, 15)
    XCTAssertEqual(AppTextStyle.secondary.size, 15)
    XCTAssertEqual(AppTextStyle.navigation.size, 17)
    XCTAssertEqual(AppTextStyle.chrome.size, 12)
    XCTAssertEqual(AppTextStyle.bubbleMeta.size, 12)
    XCTAssertEqual(AppTextStyle.mcp.size, 11)
    XCTAssertEqual(AppTextStyle.metrics.size, 11)
    XCTAssertEqual(AppLayout.margin, 16)
    XCTAssertEqual(AppLayout.composerMargin, 12)
    XCTAssertEqual(AppLayout.avatar, 44)
    XCTAssertEqual(AppLayout.rowTextInset, 56)
  }

  func testChromeCapsAtDefaultWhileReadingTextKeepsGrowing() {
    for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
      let traits = UITraitCollection(preferredContentSizeCategory: size.uiCategory)
      for style in [AppTextStyle.navigation, .chrome, .bubbleMeta, .mcp, .metrics] {
        XCTAssertEqual(AppTypography.font(style, compatibleWith: traits).pointSize, style.size)
        XCTAssertEqual(AppTypography.lineHeight(style, compatibleWith: traits), style.lineHeight, accuracy: 0.34)
      }
      if size != .large {
        XCTAssertGreaterThan(AppTypography.font(.body, compatibleWith: traits).pointSize, 17)
      }
    }
  }

  func testSessionRowsReflowAtAccessibilitySizes() throws {
    let entry = try JSONDecoder().decode(NavigationEntry.self, from: Data("""
      {"session":{"id":"ses_typography","title":"Uma sessão com um título longo para conferir a leitura",
      "projectID":"repo","location":{"directory":"/Projetos/exemplo"},
      "time":{"created":1792584000000,"updated":1792684000000}}}
      """.utf8))
    let row = try XCTUnwrap(SessionList.rows(entries: [entry], projects: [], active: [], pins: [],
      muted: [], autoApprove: false, ranks: [:], chatRoot: nil).first)
    let sizes: [DynamicTypeSize] = [.large, .accessibility5]
    let heights = sizes.map { size in
      let host = UIHostingController(rootView: SessionRowView(row: row, preview: SessionPreview(),
        directory: SessionDirectoryLabel(path: "~/Projetos/exemplo", branch: "main"))
        .environment(\.dynamicTypeSize, size))
      return host.sizeThatFits(in: CGSize(width: 340, height: 2000)).height
    }
    XCTAssertGreaterThan(heights[1], heights[0] * 2)
    XCTAssertLessThan(heights[1], 2000)
  }
}
