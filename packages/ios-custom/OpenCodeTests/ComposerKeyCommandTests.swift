import AppIntents
import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ComposerKeyCommandTests: XCTestCase {
  func testShiftReturnUsesSubmitExactlyOnce() throws {
    let view = ComposerInputView(frame: .zero, textContainer: nil)
    let window = UIWindow(
      windowScene: try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = UIViewController()
    window.rootViewController?.view.addSubview(view)
    view.frame = CGRect(x: 20, y: 100, width: 350, height: 100)
    window.makeKeyAndVisible()
    defer {
      view.resignFirstResponder()
      window.isHidden = true
    }
    XCTAssertTrue(view.becomeFirstResponder())
    var calls = 0
    view.submit = { calls += 1 }
    view.canSubmit = true
    let command = try XCTUnwrap(
      view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift })
    XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
    XCTAssertFalse(
      view.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags.isEmpty } == true)
    let action = try XCTUnwrap(command.action)
    XCTAssertTrue(view.canPerformAction(action, withSender: command))
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    XCTAssertEqual(calls, 1)
  }

  func testBlockedEditorsNeverSubmit() throws {
    let view = ComposerInputView(frame: .zero, textContainer: nil)
    let window = UIWindow(
      windowScene: try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = UIViewController()
    window.rootViewController?.view.addSubview(view)
    view.frame = CGRect(x: 20, y: 100, width: 350, height: 100)
    window.makeKeyAndVisible()
    defer {
      view.resignFirstResponder()
      window.isHidden = true
    }
    XCTAssertTrue(view.becomeFirstResponder())
    var calls = 0
    view.submit = { calls += 1 }
    view.canSubmit = true
    let command = try XCTUnwrap(
      view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .shift })
    let action = try XCTUnwrap(command.action)
    view.canSubmit = false  // The main button's shared predicate includes sending/importing/model/readiness.
    XCTAssertFalse(view.canPerformAction(action, withSender: command))
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    view.canSubmit = true
    view.querying = true
    XCTAssertTrue(view.isFirstResponder)
    XCTAssertFalse(view.canPerformAction(action, withSender: command))
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    view.querying = false
    view.isEditable = false
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    view.isEditable = true
    XCTAssertTrue(view.becomeFirstResponder())
    view.setMarkedText("compondo", selectedRange: NSRange(location: 8, length: 0))
    XCTAssertNotNil(view.markedTextRange)
    XCTAssertTrue(view.isFirstResponder)
    XCTAssertFalse(view.canPerformAction(action, withSender: command))
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    view.unmarkText()
    view.submit = nil  // Comment and auxiliary editors have no submit callback.
    XCTAssertFalse(
      view.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags == .shift } == true)
    UIApplication.shared.sendAction(action, to: view, from: command, for: nil)
    XCTAssertEqual(calls, 0)
  }
}
