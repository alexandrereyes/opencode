import Foundation
import LocalAuthentication
import Testing
@testable import OpenCodeKit

/// Face ID as the tests drive it: each prompt waits until the test answers it (or `cancel` ends it).
@MainActor private final class Face: BiometricAuthenticator {
  var unavailable: BiometricFailure?
  private(set) var prompts: [String] = []
  private(set) var cancels = 0
  private var pending: CheckedContinuation<BiometricFailure?, Never>?

  func unavailability() -> BiometricFailure? { unavailable }
  func authenticate(reason: String) async -> BiometricFailure? {
    prompts.append(reason)
    return await withCheckedContinuation { pending = $0 }
  }
  func cancel() {
    cancels += 1
    answer(.cancelled)
  }
  /// Answers the prompt on screen; nil is Face ID recognizing him.
  func answer(_ failure: BiometricFailure?) {
    pending?.resume(returning: failure)
    pending = nil
  }
  /// Lets the app's task reach the prompt.
  func waitForPrompt(_ count: Int) async {
    while prompts.count < count || pending == nil { await Task.yield() }
  }
}

@MainActor private func lock(_ face: Face, enabled: Bool) throws -> (AppLock, UserDefaults) {
  let defaults = try #require(UserDefaults(suiteName: "app-lock-" + UUID().uuidString))
  if enabled { defaults.set(true, forKey: AppLock.key) }
  return (AppLock(authenticator: face, defaults: defaults), defaults)
}

@MainActor @Test func turningOnNeedsFaceIDAndTheNextLaunchStartsLocked() async throws {
  let face = Face()
  let (lock, defaults) = try lock(face, enabled: false)
  #expect(!lock.enabled && lock.phase == .open)

  async let refused = lock.setEnabled(true)
  await face.waitForPrompt(1)
  face.answer(.cancelled)
  #expect(await refused == .cancelled)
  #expect(!lock.enabled && !defaults.bool(forKey: AppLock.key))

  async let granted = lock.setEnabled(true)
  await face.waitForPrompt(2)
  #expect(lock.prompting)
  face.answer(nil)
  #expect(await granted == nil)
  #expect(lock.enabled && defaults.bool(forKey: AppLock.key))
  // Turning it on does not lock what he is looking at.
  #expect(lock.phase == .open)

  let relaunched = AppLock(authenticator: face, defaults: defaults)
  #expect(relaunched.enabled && relaunched.phase == .locked)
}

@MainActor @Test func unavailableFaceIDNeverTurnsOnAndNeverPrompts() async throws {
  for failure in [BiometricFailure.notEnrolled, .unavailable, .passcodeNotSet, .lockout] {
    let face = Face()
    face.unavailable = failure
    let (lock, defaults) = try lock(face, enabled: false)
    #expect(await lock.setEnabled(true) == failure)
    #expect(!lock.enabled && !defaults.bool(forKey: AppLock.key) && face.prompts.isEmpty)
  }
}

@MainActor @Test func turningOffNeedsFaceIDToo() async throws {
  let face = Face()
  let (lock, defaults) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  face.answer(nil)
  await opening.value

  async let refused = lock.setEnabled(false)
  await face.waitForPrompt(2)
  face.answer(.notRecognized)
  #expect(await refused == .notRecognized)
  #expect(lock.enabled && defaults.bool(forKey: AppLock.key))

  async let granted = lock.setEnabled(false)
  await face.waitForPrompt(3)
  face.answer(nil)
  #expect(await granted == nil)
  #expect(!lock.enabled && !defaults.bool(forKey: AppLock.key) && lock.phase == .open)
  // Off: losing focus no longer locks or prompts.
  lock.sceneWillDeactivate()
  lock.sceneDidEnterBackground()
  #expect(lock.phase == .open && lock.sceneDidActivate() == nil)
}

@MainActor @Test func everyLossOfFocusLocksAndTheNextActivationAsksOnce() async throws {
  let face = Face()
  let (lock, _) = try lock(face, enabled: true)
  // Cold start: locked before anything is shown, and the first activation asks.
  #expect(lock.locked)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  #expect(lock.phase == .checking)
  face.answer(nil)
  await opening.value
  #expect(lock.phase == .open)

  // Inactive only (Control Center, the app switcher): locked at once, no time allowance.
  lock.sceneWillDeactivate()
  #expect(lock.phase == .locked)
  let back = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(2)
  face.answer(nil)
  await back.value
  #expect(lock.phase == .open)

  // Background: locked too.
  lock.sceneWillDeactivate()
  lock.sceneDidEnterBackground()
  #expect(lock.phase == .locked)
  let returned = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(3)
  face.answer(nil)
  await returned.value
  #expect(lock.phase == .open && face.prompts.count == 3)
}

@MainActor @Test func theOwnPromptNeitherRelocksNorLoopsAfterACancel() async throws {
  let face = Face()
  let (lock, _) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  // The system prompt takes the focus and gives it back.
  lock.sceneWillDeactivate()
  face.answer(.cancelled)
  await opening.value
  #expect(lock.phase == .failed(.cancelled))
  #expect(lock.sceneDidActivate() == nil)
  #expect(face.prompts.count == 1)

  // Tentar novamente asks again; that prompt's own focus cycle does not undo the success.
  async let retry: Void = lock.unlock()
  await face.waitForPrompt(2)
  lock.sceneWillDeactivate()
  face.answer(nil)
  await retry
  #expect(lock.sceneDidActivate() == nil)
  #expect(lock.phase == .open && face.prompts.count == 2)
}

@MainActor @Test func failuresKeepItLocked() async throws {
  for failure in [BiometricFailure.cancelled, .fallback, .notRecognized, .lockout, .unavailable, .other("x")] {
    let face = Face()
    let (lock, _) = try lock(face, enabled: true)
    let opening = try #require(lock.sceneDidActivate())
    await face.waitForPrompt(1)
    face.answer(failure)
    await opening.value
    #expect(lock.phase == .failed(failure) && lock.locked)
  }
  // Face ID gone after the lock was turned on: still locked, no prompt.
  let face = Face()
  face.unavailable = .notEnrolled
  let (lock, _) = try lock(face, enabled: true)
  await lock.sceneDidActivate()?.value
  #expect(lock.phase == .failed(.notEnrolled) && face.prompts.isEmpty)
}

@MainActor @Test func backgroundDuringAPromptCancelsItAndRefusesItsLateAnswer() async throws {
  let face = Face()
  let (lock, _) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  lock.sceneWillDeactivate()
  lock.sceneDidEnterBackground()
  await opening.value
  #expect(face.cancels == 1 && lock.phase == .locked && !lock.prompting)

  // The next activation asks again; a success from the abandoned prompt could not have opened it.
  let back = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(2)
  face.answer(nil)
  await back.value
  #expect(lock.phase == .open)
}

@MainActor @Test func backgroundWhileTurningOffKeepsItOnAndLocked() async throws {
  let face = Face()
  let (lock, defaults) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  face.answer(nil)
  await opening.value

  async let off = lock.setEnabled(false)
  await face.waitForPrompt(2)
  lock.sceneWillDeactivate()
  #expect(lock.phase == .open)
  lock.sceneDidEnterBackground()
  #expect(await off == .cancelled)
  #expect(lock.enabled && defaults.bool(forKey: AppLock.key) && lock.phase == .locked)
}

/// Opens a lock that starts on, as the scene's first activation does.
@MainActor private func opened(_ face: Face) async throws -> (AppLock, UserDefaults) {
  let (lock, defaults) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(face.prompts.count + 1)
  face.answer(nil)
  await opening.value
  #expect(lock.phase == .open && !lock.covered)
  return (lock, defaults)
}

@MainActor @Test func cancellingTurnOffAnsweredBeforeActiveStaysCoveredUntilActive() async throws {
  let face = Face()
  let (lock, _) = try await opened(face)
  async let off = lock.setEnabled(false)
  await face.waitForPrompt(2)
  // Covered from the moment its prompt is up, and through the inactive scene it causes.
  #expect(lock.covered && lock.phase == .open)
  lock.sceneWillDeactivate()
  #expect(lock.covered && lock.phase == .open)
  face.answer(.cancelled)
  #expect(await off == .cancelled)
  // The answer came first: still inactive, so still covered, yet nothing to unlock.
  #expect(lock.covered && !lock.locked && lock.enabled)
  #expect(lock.sceneDidActivate() == nil)
  #expect(!lock.covered && lock.phase == .open && face.prompts.count == 2)
}

@MainActor @Test func cancellingTurnOffActiveBeforeTheAnswerStaysCoveredUntilTheAnswer() async throws {
  let face = Face()
  let (lock, _) = try await opened(face)
  async let off = lock.setEnabled(false)
  await face.waitForPrompt(2)
  lock.sceneWillDeactivate()
  #expect(lock.sceneDidActivate() == nil)
  #expect(lock.covered && lock.phase == .open)
  face.answer(.cancelled)
  #expect(await off == .cancelled)
  #expect(!lock.covered && lock.phase == .open && lock.enabled && face.prompts.count == 2)
}

@MainActor @Test func turningOffUncoversOnlyWhenDone() async throws {
  let face = Face()
  let (lock, _) = try await opened(face)
  async let off = lock.setEnabled(false)
  await face.waitForPrompt(2)
  lock.sceneWillDeactivate()
  face.answer(nil)
  #expect(await off == nil)
  // Off: nothing left to hide, even before the scene is active again.
  #expect(!lock.enabled && !lock.covered)
  #expect(lock.sceneDidActivate() == nil && face.prompts.count == 2)
}

@MainActor @Test func unlockAnsweredBeforeActiveStaysCoveredUntilActive() async throws {
  let face = Face()
  let (lock, _) = try lock(face, enabled: true)
  let opening = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(1)
  lock.sceneWillDeactivate()
  face.answer(nil)
  await opening.value
  #expect(lock.phase == .open && lock.covered)
  #expect(lock.sceneDidActivate() == nil)
  #expect(!lock.covered && face.prompts.count == 1)
}

@MainActor @Test func backgroundWhileTurningOffStillCancelsAndLocks() async throws {
  let face = Face()
  let (lock, _) = try await opened(face)
  async let off = lock.setEnabled(false)
  await face.waitForPrompt(2)
  lock.sceneWillDeactivate()
  lock.sceneDidEnterBackground()
  #expect(await off == .cancelled)
  #expect(face.cancels == 1 && lock.phase == .locked && lock.covered)
  let back = try #require(lock.sceneDidActivate())
  await face.waitForPrompt(3)
  face.answer(nil)
  await back.value
  #expect(lock.phase == .open && !lock.covered && lock.enabled)
}

@Test func laErrorsMapToWhatHeCanDo() {
  let cases: [(LAError.Code, BiometricFailure)] = [
    (.userCancel, .cancelled), (.systemCancel, .cancelled), (.appCancel, .cancelled), (.userFallback, .fallback),
    (.authenticationFailed, .notRecognized), (.biometryLockout, .lockout), (.biometryNotEnrolled, .notEnrolled),
    (.biometryNotAvailable, .unavailable), (.passcodeNotSet, .passcodeNotSet),
  ]
  for (code, failure) in cases { #expect(BiometricFailure(LAError(code)) == failure) }
  #expect(BiometricFailure.lockout.message.contains("código"))
}
