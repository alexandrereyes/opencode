import XCTest

/// A test install never reaches the real server (`TestInstall`). Run first on a fresh simulator: before any sandbox
/// launch the app has nothing to fall back to and must show the notice instead of connecting.
@MainActor final class ServerIsolationTests: XCTestCase {
  func testLaunchWithoutArgumentsNeverConnectsAndARelaunchKeepsTheSandbox() throws {
    let app = XCUIApplication()
    // Nothing from the test or the xctestrun: like a relaunch by the system or a reinstall.
    app.launchArguments = []
    app.launchEnvironment = [:]
    app.launch()
    let notice = app.descendants(matching: .any)["test-without-sandbox"].firstMatch
    let marker = app.staticTexts["debug-server-url"]
    XCTAssertTrue(notice.waitForExistence(timeout: 20), "sem argumentos o app deve mostrar o aviso")
    XCTAssertFalse(marker.exists, "sem argumentos o app não pode se conectar: \(marker.exists ? marker.label : "")")
    screenshot("isolation-without-sandbox")
    app.terminate()

    // A normal test launch connects to its sandbox.
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url]
    app.launchEnvironment = ["OPENCODE_SERVER_PASSWORD": ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"] ?? ""]
    app.launch()
    try app.requireSandbox()
    app.terminate()

    // Reopened without arguments (`activate()` on a closed app), it returns to that sandbox, never elsewhere.
    app.activate()
    try app.requireSandbox()
    XCTAssertFalse(notice.exists)
    screenshot("isolation-relaunch")
    app.terminate()
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
