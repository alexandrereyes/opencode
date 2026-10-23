import Foundation
import Observation

public enum GPTLiveVoice: String, CaseIterable, Codable, Sendable, Identifiable {
  case rio, viola
  case cove, juniper, maple, spruce, ember, vale, breeze, arbor, sol, aube, bubbie
  case haetsal, hanul, himari, leher, miko, neer, porto, rindo, rivage, selva, sonna, tinta

  public static let defaultVoice = Self.rio
  public var id: String { rawValue }
  public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
  public var brazilian: Bool { self == .rio || self == .viola }
  public static var brazilian: [Self] { allCases.filter(\.brazilian) }
  public static var others: [Self] { allCases.filter { !$0.brazilian } }
}

@MainActor @Observable public final class VoicePreferences {
  public static let key = "OpenCodeVoice"
  public var voice: GPTLiveVoice {
    didSet { defaults.set(voice.rawValue, forKey: Self.key) }
  }
  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    voice = defaults.string(forKey: Self.key).flatMap(GPTLiveVoice.init(rawValue:)) ?? .defaultVoice
  }
}
