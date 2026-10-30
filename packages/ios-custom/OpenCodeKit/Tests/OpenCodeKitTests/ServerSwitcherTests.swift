import Foundation
import Testing

@testable import OpenCodeKit

@Test func serverInitialsSkipJoiningWordsAndFollowTheMonogram() {
  #expect(ServerSwitcher.initials("Mac de Alexandre") == "MA")
  #expect(ServerSwitcher.initials("host-6 · produção") == "H6")
  #expect(ServerSwitcher.initials("Sandbox") == "SA")
  #expect(ServerSwitcher.initials("Servidor do escritório") == "SE")
  #expect(ServerSwitcher.initials("ônibus elétrico") == "ÔE")
  // A name made only of joining words keeps them.
  #expect(ServerSwitcher.initials("de") == "DE")
  #expect(ServerSwitcher.initials("mac.example.com") == "ME")
}

@Test func serverEntriesKeepAjustesOrderWithShortcutsUpToNine() throws {
  let servers = (0..<11).map { index in
    SavedServer(id: index == 0 ? "builtin" : "id-\(index)", name: index == 0 ? "Mac de Alexandre" : "Servidor \(index)",
      url: URL(string: "http://127.0.0.1:\(4100 + index)")!)
  }
  let entries = ServerSwitcher.entries(servers, activeID: "id-2")
  #expect(entries.map(\.id) == servers.map(\.id))
  #expect(entries.map(\.shortcut) == (1...9).map(Optional.some) + [nil, nil])
  #expect(entries.filter(\.active).map(\.id) == ["id-2"])
  #expect(entries[0].initials == "MA" && entries[3].initials == "S3")
  #expect(entries[1].address == "127.0.0.1:4101")
  // The color depends on the ID alone, from the project avatars' palette.
  let again = ServerSwitcher.entries(servers.reversed(), activeID: "builtin")
  for entry in entries {
    #expect(again.first { $0.id == entry.id }?.color == entry.color)
    #expect(["lime", "orange", "purple", "cyan", "pink", "mint"].contains(entry.color))
  }
  #expect(Set(entries.map(\.color)).count > 1)
}

@Test func serverSwitcherShowsOnlyWithAChoice() {
  let builtin = SavedServer(id: "builtin", name: "Mac de Alexandre", url: URL(string: "http://127.0.0.1:4096")!)
  let other = SavedServer(id: "other", name: "", url: URL(string: "https://mac.example.com/opencode")!)
  #expect(!ServerSwitcher.visible([builtin]))
  #expect(ServerSwitcher.visible([builtin, other]))
  #expect(ServerSwitcher.entries([builtin, other], activeID: "builtin").map(\.initials) == ["MA", "ME"])
}

@Test func serverAddressesShowHostPortAndPath() {
  #expect(ServerSwitcher.address(URL(string: "http://127.0.0.1:4096")!) == "127.0.0.1:4096")
  #expect(ServerSwitcher.address(URL(string: "https://mac.example.com")!) == "mac.example.com")
  #expect(ServerSwitcher.address(URL(string: "https://mac.example.com/opencode")!) == "mac.example.com/opencode")
  #expect(ServerSwitcher.address(ServerAddress.parse("host-6.interno:4096/")!) == "host-6.interno:4096")
}

@Test func serverConnectionReadsLikeAjustes() {
  #expect(ServerSwitcher.Connection(connected: true, failed: true) == .connected)
  #expect(ServerSwitcher.Connection(connected: false, failed: false) == .connecting)
  #expect(ServerSwitcher.Connection(connected: false, failed: true) == .disconnected)
  #expect([ServerSwitcher.Connection.connected, .connecting, .disconnected].map(\.label)
    == ["Conectado", "Conectando…", "Desconectado"])
}
