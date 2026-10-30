import Testing

@testable import OpenCodeKit

#if os(watchOS) || os(iOS)
  import AVFAudio
#endif

struct WatchCallAudioTests {
  @Test func airPodsOverHFPCarryTheMicrophoneToo() {
    let route = WatchAudioRoute(inputs: ["BluetoothHFP"], outputs: ["BluetoothHFP"])
    #expect(route.bluetooth)
    #expect(route.summary == "saída BluetoothHFP · microfone BluetoothHFP")
  }

  @Test func playOnlyHeadphonesKeepTheWatchMicrophone() {
    let route = WatchAudioRoute(inputs: ["MicrophoneBuiltIn"], outputs: ["BluetoothA2DPOutput"])
    #expect(route.bluetooth)
    #expect(route.summary == "saída BluetoothA2DPOutput · microfone MicrophoneBuiltIn")
  }

  /// Without headphones, or after the AirPods leave mid-call, the watch's speaker is the route.
  @Test func theWatchSpeakerIsNotBluetooth() {
    #expect(!WatchAudioRoute(inputs: ["MicrophoneBuiltIn"], outputs: ["Speaker"]).bluetooth)
    #expect(WatchAudioRoute(inputs: [], outputs: []).summary == "saída nenhuma · microfone nenhum")
  }

  #if os(watchOS) || os(iOS)
    @Test func portNamesMatchTheSystemOnes() {
      #expect(WatchAudioRoute.bluetoothPorts
        == [AVAudioSession.Port.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].map(\.rawValue).reduce(into: []) { $0.insert($1) })
      #expect(!WatchAudioRoute.bluetoothPorts.contains(AVAudioSession.Port.builtInSpeaker.rawValue))
    }

    /// The call's category lets the system route to Bluetooth headphones and keeps voice processing (echo cancellation).
    @Test func callSessionAllowsBluetoothWithVoiceChat() throws {
      let session = AVAudioSession.sharedInstance()
      try WatchCallAudio.configure(session)
      #expect(session.category == .playAndRecord)
      #expect(session.mode == .voiceChat)
      #expect(session.routeSharingPolicy == .default)
      #expect(session.categoryOptions.contains(.allowBluetoothHFP))
      #expect(session.categoryOptions.contains(.allowBluetoothA2DP))
      #expect(WatchCallAudio.note(session) == "PlayAndRecord/VoiceChat hfp a2dp")
    }
  #endif
}
