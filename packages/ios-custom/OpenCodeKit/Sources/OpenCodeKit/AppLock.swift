#if !os(watchOS)
import Foundation
import LocalAuthentication
import Observation

/// Why Face ID did not let him in; each case tells him what to do. The lock stays closed on every one.
public enum BiometricFailure: Error, Equatable, Sendable {
  /// He, the system or the app closed the prompt.
  case cancelled
  /// The prompt's password button, hidden by `FaceIDAuthenticator`; should it ever answer, the lock stays closed.
  case fallback
  case notRecognized
  /// Too many failed tries: iOS wants the iPhone's passcode first.
  case lockout
  case notEnrolled
  /// No Face ID on this iPhone, or Face ID turned off for the app.
  case unavailable
  case passcodeNotSet
  case other(String)

  public init(_ error: any Error) {
    guard let error = error as? LAError else {
      self = .other(error.localizedDescription)
      return
    }
    self = switch error.code {
    case .userCancel, .systemCancel, .appCancel, .notInteractive: .cancelled
    case .userFallback: .fallback
    case .authenticationFailed: .notRecognized
    case .biometryLockout: .lockout
    case .biometryNotEnrolled: .notEnrolled
    case .biometryNotAvailable: .unavailable
    case .passcodeNotSet: .passcodeNotSet
    default: .other(error.localizedDescription)
    }
  }

  public var message: String {
    switch self {
    case .cancelled: "O Face ID foi cancelado."
    case .fallback: "O MyAgents só desbloqueia com o Face ID."
    case .notRecognized: "O Face ID não reconheceu você."
    case .lockout:
      "O Face ID foi bloqueado depois de várias tentativas. Bloqueie o iPhone e desbloqueie-o com o código; depois volte e tente de novo."
    case .notEnrolled: "Nenhum rosto cadastrado. Cadastre o Face ID em Ajustes › Face ID e Código."
    case .unavailable: "O Face ID não está disponível para o MyAgents. Verifique em Ajustes › MyAgents › Face ID."
    case .passcodeNotSet: "O iPhone está sem código. Defina um código e cadastre o Face ID em Ajustes › Face ID e Código."
    case .other(let detail): "O Face ID falhou: \(detail)"
    }
  }
}

/// The boundary to LocalAuthentication, so `AppLock` runs in tests without a face.
@MainActor public protocol BiometricAuthenticator: AnyObject {
  /// Why Face ID cannot be asked now; nil when it can.
  func unavailability() -> BiometricFailure?
  /// Shows the system prompt; nil when Face ID recognized him.
  func authenticate(reason: String) async -> BiometricFailure?
  /// Ends a prompt in flight; its `authenticate` returns `.cancelled`.
  func cancel()
}

/// Face ID only (`.deviceOwnerAuthenticationWithBiometrics`): never the passcode, never an app PIN.
@MainActor public final class FaceIDAuthenticator: BiometricAuthenticator {
  private var context: LAContext?
  public init() {}

  public func unavailability() -> BiometricFailure? {
    let context = LAContext()
    var error: NSError?
    // biometryType is meaningful only after canEvaluatePolicy.
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return error.map(BiometricFailure.init) ?? .unavailable
    }
    return context.biometryType == .faceID ? nil : .unavailable
  }

  public func authenticate(reason: String) async -> BiometricFailure? {
    let context = LAContext()
    // No "Digitar senha" button: it could only fail, since this lock takes Face ID alone.
    context.localizedFallbackTitle = ""
    self.context = context
    defer { if self.context === context { self.context = nil } }
    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        ? nil : .notRecognized
    } catch {
      return BiometricFailure(error)
    }
  }

  public func cancel() {
    context?.invalidate()
    context = nil
  }
}

/// Você ▸ Segurança ▸ Exigir Face ID: when on, the app opens locked and locks again on every loss of focus (the scene
/// going inactive or to the background); the next activation asks for Face ID. It fails closed: a cancelled, failed,
/// locked-out or unavailable Face ID keeps it locked, with Tentar novamente.
///
/// The Face ID prompt itself makes the scene inactive and then active again: those transitions neither lock again
/// nor prompt again, so a cancelled prompt never loops. Going to the background ends the prompt in flight, and its
/// late answer is ignored. Only the scene's UI is covered; voice, Live Activities and background work go on.
///
/// Needing Face ID (`locked`) and hiding the content (`covered`) differ: with the lock on, the content is also hidden
/// while the scene is not active or a prompt is up, as during the one that turns the lock off.
@MainActor @Observable public final class AppLock {
  public enum Phase: Equatable, Sendable {
    case open
    case locked
    case checking
    case failed(BiometricFailure)
  }

  public static let key = "OpenCodeFaceIDLock"

  public private(set) var enabled: Bool
  public private(set) var phase: Phase
  /// A Face ID prompt (to unlock, or to turn the lock on or off) is on screen.
  public private(set) var prompting = false
  /// The scene is active (between `sceneDidActivate` and the next deactivation).
  public private(set) var active = false
  public var locked: Bool { phase != .open }
  /// What the screen must hide: locked, or the lock on while inactive or during its own prompt.
  public var covered: Bool { locked || (enabled && (!active || prompting)) }

  @ObservationIgnored private let authenticator: any BiometricAuthenticator
  @ObservationIgnored private let defaults: UserDefaults
  /// Bumped by every prompt and by every trip to the background: an answer for an older value is stale.
  @ObservationIgnored private var attempt = 0
  /// A real loss of focus happened since the last prompt: the next activation asks for Face ID by itself.
  @ObservationIgnored private var promptOnActive: Bool

  public init(authenticator: any BiometricAuthenticator, defaults: UserDefaults = .standard) {
    self.authenticator = authenticator
    self.defaults = defaults
    let enabled = defaults.bool(forKey: Self.key)
    self.enabled = enabled
    phase = enabled ? .locked : .open
    promptOnActive = enabled
  }

  /// The scene stops being active: a system sheet, Control Center, the app switcher, or our own prompt.
  public func sceneWillDeactivate() {
    active = false
    guard enabled, !prompting else { return }
    if phase == .open { phase = .locked }
    promptOnActive = true
  }

  /// The scene left the screen: lock, end any prompt and refuse its late answer.
  public func sceneDidEnterBackground() {
    active = false
    attempt += 1
    if prompting {
      prompting = false
      authenticator.cancel()
    }
    guard enabled else { return }
    phase = .locked
    promptOnActive = true
  }

  /// The scene is active again: prompt once after a real loss of focus, never after our own prompt.
  @discardableResult public func sceneDidActivate() -> Task<Void, Never>? {
    active = true
    guard enabled, locked, promptOnActive, !prompting else { return nil }
    promptOnActive = false
    return Task { await unlock() }
  }

  /// Asks for Face ID to open the app (also Tentar novamente).
  public func unlock() async {
    guard enabled, locked, !prompting else { return }
    phase = .checking
    switch await ask("Desbloquear o MyAgents") {
    case .granted: phase = .open
    case .refused(let failure): phase = .failed(failure)
    case .stale: break
    }
  }

  /// Turns the lock on or off, only after Face ID recognizes him; returns why it stayed as it was.
  public func setEnabled(_ on: Bool) async -> BiometricFailure? {
    guard on != enabled else { return nil }
    guard !prompting else { return .cancelled }
    switch await ask(on ? "Exigir Face ID para abrir o MyAgents" : "Deixar de exigir Face ID no MyAgents") {
    case .granted:
      enabled = on
      defaults.set(on, forKey: Self.key)
      return nil
    case .refused(let failure): return failure
    case .stale: return .cancelled
    }
  }

  private enum Answer { case granted, refused(BiometricFailure), stale }

  private func ask(_ reason: String) async -> Answer {
    if let failure = authenticator.unavailability() { return .refused(failure) }
    attempt += 1
    let mine = attempt
    prompting = true
    let failure = await authenticator.authenticate(reason: reason)
    guard mine == attempt else { return .stale }
    prompting = false
    return failure.map(Answer.refused) ?? .granted
  }
}
#endif
