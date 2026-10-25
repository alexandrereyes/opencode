import Foundation
import Testing

@testable import OpenCodeKit

private let hubResource = #"""
  {"id":"ios-simulator:77441AC7-5092-422F-8223-B53AC7973439","kind":"ios-simulator","label":"iPhone 17 · OpenCode Recursos",
  "owner":{"sessionID":"ses_child","rootSessionID":"ses_root","agent":"explore"},"state":"agent",
  "control":{"holder":"user","since":1,"expiresAt":120001},
  "meta":{"kind":"ios-simulator","udid":"77441AC7-5092-422F-8223-B53AC7973439","name":"OpenCode Recursos","device":"iPhone 17","runtime":"iOS 27.0"},
  "discoveredAt":1,"lastUsedAt":2,"updatedAt":3,"live":{"stream":false,"input":false}}
  """#

@Test func resourcesDecodeTheHubShapeAndTolerateUnknownKindsAndStates() throws {
  let resource = try JSONDecoder().decode(SessionResource.self, from: Data(hubResource.utf8))
  #expect(resource.kind == .iosSimulator)
  #expect(resource.state == .agent)
  #expect(resource.via == "ses_child")
  #expect(resource.meta.udid == "77441AC7-5092-422F-8223-B53AC7973439")
  #expect(resource.control?.expiresAt == 120_001)
  let future = hubResource.replacingOccurrences(of: #""kind":"ios-simulator","label""#, with: #""kind":"tv","label""#)
    .replacingOccurrences(of: #""state":"agent""#, with: #""state":"sleeping""#)
  let unknown = try JSONDecoder().decode(SessionResource.self, from: Data(future.utf8))
  #expect(unknown.kind == .unknown("tv"))
  #expect(unknown.state == .idle)
}

@Test func ticketsResolveToTheServerOriginOrTheHubLoopbackPort() throws {
  let ticket = ResourceTicket(ticket: "a.b", expiresAt: 0, path: "/resources/chrome%3Alogin", loopbackPort: 4179)
  let remote = OpenCodeClient(configuration: .init(url: URL(string: "http://opencode2-mac.alexandrem.com.br")!))
  #expect(remote.resourceURL(ticket, "stream", websocket: true)?.absoluteString
    == "ws://opencode2-mac.alexandrem.com.br/resources/chrome%3Alogin/stream?ticket=a.b")
  #expect(remote.resourceURL(ticket, "snapshot")?.absoluteString
    == "http://opencode2-mac.alexandrem.com.br/resources/chrome%3Alogin/snapshot?ticket=a.b")
  let local = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4185")!))
  #expect(local.resourceURL(ticket, "stream", websocket: true)?.absoluteString
    == "ws://127.0.0.1:4179/resources/chrome%3Alogin/stream?ticket=a.b")
}

@Test func inputsEncodeTheWireProtocolClampedToTheFrame() throws {
  func json(_ input: ResourceInput) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
  }
  let touch = try json(.touch(.began, x: 1.2, y: 0.25))
  #expect(touch["type"] as? String == "touch")
  #expect(touch["phase"] as? String == "began")
  #expect(touch["x"] as? Double == 1)
  #expect(touch["pointer"] == nil)
  #expect(try json(.text("segredo"))["text"] as? String == "segredo")
  #expect(try json(.button("home"))["button"] as? String == "home")
  #expect(try json(.navigate("url", url: "https://example.com"))["url"] as? String == "https://example.com")
  #expect(try json(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 40))["dy"] as? Double == 10)
}

@Test func framesAndServerMessagesDecode() throws {
  var data = Data([1, 1])
  withUnsafeBytes(of: (1234.5).bitPattern.bigEndian) { data.append(contentsOf: $0) }
  data.append(contentsOf: [7, 8])
  let frame = try #require(ResourceFrame(data))
  #expect(frame.keyframe)
  #expect(frame.capturedAt == 1234.5)
  #expect(frame.payload == Data([7, 8]))
  #expect(ResourceFrame(Data([2, 0, 0])) == nil)
  let decode = { (text: String) in try JSONDecoder().decode(ResourceServerMessage.self, from: Data(text.utf8)) }
  #expect(try decode(#"{"type":"hello","format":"jpeg","width":828,"height":1792}"#)
    == .hello(format: "jpeg", width: 828, height: 1792, scale: nil, codec: nil))
  #expect(try decode(#"{"type":"control","holder":"user","expiresAt":5,"mine":true}"#)
    == .control(holder: "user", expiresAt: 5, mine: true))
  #expect(try decode(#"{"type":"control","holder":null,"mine":false}"#) == .control(holder: nil, expiresAt: nil, mine: false))
  #expect(try decode(#"{"type":"future"}"#) == .unknown("future"))
}

@Test func resourceLinksRoundTrip() throws {
  let url = try #require(ResourceLink.url(for: "ios-simulator:77441AC7"))
  #expect(ResourceLink.id(from: url) == "ios-simulator:77441AC7")
  #expect(ResourceLink.id(from: URL(string: "opencode-resource:chrome%3Alogin")!) == "chrome:login")
  #expect(ResourceLink.id(from: URL(string: "https://example.com")!) == nil)
}
