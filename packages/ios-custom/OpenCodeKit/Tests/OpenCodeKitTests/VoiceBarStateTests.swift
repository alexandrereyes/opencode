import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceBarStateTests {
  @Test func mapsEngineWithoutConfusingProgressAndSpeech() {
    var voice = VoiceState()
    voice.apply(.start)
    #expect(VoiceBarState(voice: voice, elapsed: 0).phase == .connecting)
    voice.apply(.connected)
    #expect(VoiceBarState(voice: voice, elapsed: 1).label == "Ouvindo")
    voice.masterWorking = true
    let thinking = VoiceBarState(voice: voice, elapsed: 134, transcript: "Vou conferir.", masterProgress: "lendo 3 sessões…")
    #expect(thinking.phase == .thinking)
    #expect(thinking.spokenLine == "Vou conferir.")
    #expect(thinking.progressLine == "Sessão mestra · lendo 3 sessões…")
    voice.apply(.speech)
    #expect(VoiceBarState(voice: voice, elapsed: 1).phase == .speaking)
    voice.apply(.reconnect)
    #expect(VoiceBarState(voice: voice, elapsed: 1).phase == .reconnecting)
    voice.apply(.interruption)
    #expect(VoiceBarState(voice: voice, elapsed: 1).phase == .interrupted)
    voice.apply(.failure("Sem rede"))
    #expect(VoiceBarState(voice: voice, elapsed: 1).spokenLine == "Sem rede")
  }
  @Test func idleMasterHasNoProgressAndMuteFlattensWaveform() {
    var voice = VoiceState()
    voice.apply(.start); voice.apply(.connected)
    #expect(VoiceBarState(voice: voice, elapsed: 0, masterProgress: "antigo").progressLine == nil)
    voice.muted = true
    let value = VoiceBarState(voice: voice, elapsed: 134)
    #expect(value.label == "Microfone desligado")
    #expect(!value.animatesWaveform)
    #expect(value.muteEnabled)
    #expect(value.accessibilityLabel == "Conversa por voz, microfone desligado, 2 minutos e 14 segundos")
  }
  @Test(arguments: [(0.0, "0:00", "0 segundos"), (1, "0:01", "1 segundo"),
    (59.9, "0:59", "59 segundos"), (60, "1:00", "1 minuto"), (134, "2:14", "2 minutos e 14 segundos"),
    (3601, "1:00:01", "1 hora e 1 segundo"), (-1, "0:00", "0 segundos"),
    (.infinity, "0:00", "0 segundos")])
  func formatsTime(_ sample: (Double, String, String)) {
    let state = VoiceBarState(phase: .listening, elapsed: sample.0)
    #expect(state.time == sample.1)
    #expect(state.spokenTime == sample.2)
  }
}
