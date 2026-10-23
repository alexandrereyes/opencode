import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ConversationMenuTests: XCTestCase {
  func testUnrelatedUpdatesRetainMenuAndUseLatestActions() throws {
    let button = UIButton(type: .system)
    let coordinator = ConversationOptionsMenu.Coordinator()
    var selected = ""
    func menu(child: Bool, title: String) -> ConversationOptionsMenu {
      ConversationOptionsMenu(sessionID: "synthetic", available: true, canArchive: !child,
        archiving: false, theme: .selected, actions: .init(search: {}, rename: {},
          details: { selected = title }, archive: {}))
    }
    menu(child: false, title: "old").update(button, coordinator: coordinator)
    let original = try XCTUnwrap(button.menu)
    for _ in 0..<20 { menu(child: false, title: "latest").update(button, coordinator: coordinator) }
    XCTAssertTrue(button.menu === original)
    coordinator.actions?.details()
    XCTAssertEqual(selected, "latest")
    XCTAssertEqual(button.menu?.children.count, 4)
    menu(child: true, title: "child").update(button, coordinator: coordinator)
    XCTAssertFalse(button.menu === original)
    XCTAssertEqual(button.menu?.children.count, 3)
    ConversationOptionsMenu.dismantleUIView(button, coordinator: coordinator)
    XCTAssertNil(button.menu)
    XCTAssertNil(coordinator.actions)
    XCTAssertNil(coordinator.signature)
  }

  func testUnavailableCommandsAndArchiveKeepNativeSemantics() throws {
    let button = UIButton(type: .system)
    let coordinator = ConversationOptionsMenu.Coordinator()
    ConversationOptionsMenu(sessionID: "synthetic", available: false, canArchive: true,
      archiving: true, theme: .load("openchamber-light"),
      actions: .init(search: {}, rename: {}, details: {}, archive: {})).update(button, coordinator: coordinator)
    let children = try XCTUnwrap(button.menu?.children)
    XCTAssertFalse(try XCTUnwrap(children[0] as? UIAction).attributes.contains(.disabled))
    XCTAssertTrue(try XCTUnwrap(children[1] as? UIAction).attributes.contains(.disabled))
    XCTAssertTrue(try XCTUnwrap(children[2] as? UIAction).attributes.contains(.disabled))
    XCTAssertEqual(try XCTUnwrap(children[2] as? UIAction).image?.renderingMode, .alwaysOriginal)
    let archive = try XCTUnwrap((children[3] as? UIMenu)?.children.first as? UIAction)
    XCTAssertTrue(archive.attributes.contains(.disabled))
    XCTAssertTrue(archive.attributes.contains(.destructive))
  }
}
