import Foundation
#if os(watchOS) || os(iOS)
  import AVFAudio
#endif

/// The audio route of a watch voice call, from the session's port types (`AVAudioSession.Port` raw values), as the
/// diagnostics the watch posts to the gateway describe it.
public struct WatchAudioRoute: Equatable, Sendable {
  public let inputs: [String]
  public let outputs: [String]

  public init(inputs: [String], outputs: [String]) {
    self.inputs = inputs
    self.outputs = outputs
  }

  /// Headphones over Bluetooth: HFP carries the AirPods microphone too, A2DP and LE only the sound.
  public var bluetooth: Bool { outputs.contains { Self.bluetoothPorts.contains($0) } }

  public var summary: String {
    "saída " + (outputs.isEmpty ? "nenhuma" : outputs.joined(separator: "+"))
      + " · microfone " + (inputs.isEmpty ? "nenhum" : inputs.joined(separator: "+"))
  }

  static let bluetoothPorts: Set<String> = ["BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE"]
}

#if os(watchOS) || os(iOS)
  /// The session of a watch voice call. CallKit activates it (TN3135), so the app only sets the category in
  /// `CXStartCallAction`; watchOS has no `setPreferredInput` nor route picker for calls, so these options are what lets
  /// the system put the call on AirPods: HFP for their microphone and speakers, A2DP for headphones that only play (the
  /// watch's microphone stays), and neither when none is connected, the watch's speaker. Leaving Bluetooth out kept the
  /// call on the watch's speaker even with AirPods connected (30/10).
  public enum WatchCallAudio {
    public static let category = AVAudioSession.Category.playAndRecord
    public static let mode = AVAudioSession.Mode.voiceChat
    public static let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]

    public static func configure(_ session: AVAudioSession = .sharedInstance()) throws {
      try session.setCategory(category, mode: mode, policy: .default, options: options)
    }

    /// The configuration in force, for diagnostics: `playAndRecord/voiceChat hfp a2dp`.
    public static func note(_ session: AVAudioSession = .sharedInstance()) -> String {
      let flags = [(AVAudioSession.CategoryOptions.allowBluetoothHFP, "hfp"), (.allowBluetoothA2DP, "a2dp")]
        .compactMap { session.categoryOptions.contains($0.0) ? $0.1 : nil }
      return ([session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        + "/" + session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")] + flags)
        .joined(separator: " ")
    }
  }

  extension WatchAudioRoute {
    public init(_ route: AVAudioSessionRouteDescription) {
      self.init(inputs: route.inputs.map(\.portType.rawValue), outputs: route.outputs.map(\.portType.rawValue))
    }
  }
#endif
