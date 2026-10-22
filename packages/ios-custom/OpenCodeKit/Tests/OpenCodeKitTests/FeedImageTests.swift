import Foundation
import Testing
@testable import OpenCodeKit

@Test func feedImageReferencesResolveMacPathsWithoutUsingThePhonesHome() throws {
  for (source, path) in [
    ("/private/var/folders/image.png", "/private/var/folders/image.png"),
    ("/Users/mac/image with spaces.png", "/Users/mac/image with spaces.png"),
    ("~/Pictures/image.png", "/Users/mac/Pictures/image.png"),
    (".agent-artifacts/a.png", "/Users/mac/repo/.agent-artifacts/a.png"),
    ("./a/../b.png", "/Users/mac/repo/b.png"),
    ("file:///Users/mac/image%20one.png", "/Users/mac/image one.png"),
  ] {
    #expect(try FeedImageReference(source).path(directory: "/Users/mac/repo", home: "/Users/mac") == path)
  }
  #expect(throws: FeedImageFailure.homeUnavailable) {
    try FeedImageReference("~/image.png").path(directory: "/repo", home: nil)
  }
  #expect(FeedImageReference("data:image/png;base64,a") == .data("data:image/png;base64,a"))
  for source in ["https://example.com/a.png", "http://seaweedfs-svc:8333/bucket/a.png", "http://127.0.0.1:4177/a.png"] {
    #expect(FeedImageReference(source) == .remote(URL(string: source)!))
  }
  for source in ["javascript:alert(1)", "file://remote/path", "https://user:password@example.com/a"] {
    #expect(FeedImageReference(source) == .unsupported(source))
  }
}

@Test func feedImagesPreserveMarkdownOrderAltTextHTMLAndSelectionOffsets() throws {
  let blocks = MarkdownBlocks.parse("Antes ![Tela](/Users/mac/tela.png) depois.\n\n<img src='relative.png' alt='HTML'>\n\n`![não](code.png)`")
  #expect(blocks.filter { if case .image = $0.kind { true } else { false } }.count == 2)
  #expect(blocks.map(\.text) == ["Antes ", "Tela", " depois.", "HTML", "![não](code.png)"])
  #expect(blocks[1].kind == .image("/Users/mac/tela.png"))
  #expect(blocks[3].kind == .image("relative.png"))
  #expect(blocks[2].sourceRange(for: NSRange(location: 1, length: 6)) == NSRange(location: 35, length: 6))
  let html = HTMLImages.parse("<img src=\"https://a/image?x=1&amp;y=2\" alt=\"Tela\">")
  #expect(html.first?.source == "https://a/image?x=1&y=2")
}

@Test func feedImageRequestsUseParentLocationAuthAndNeverLeakCredentialsToOtherHosts() throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://opencode.example")!, password: "test-secret"))
  let request = client.imageFileRequest(path: "/private/images/ação ?#.png")
  #expect(request.url?.path == "/api/fs/read/ação ?#.png")
  #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
    URLQueryItem(name: "location[directory]", value: "/private/images")
  ])
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(Data("opencode:test-secret".utf8).base64EncodedString())")
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-33554432")
  let same = try client.imageRemoteRequest(URL(string: "https://opencode.example/api/fs/read/a.png?location%5Bdirectory%5D=%2Frepo")!)
  #expect(same.value(forHTTPHeaderField: "Authorization") != nil)
  let local = try client.imageRemoteRequest(URL(string: "http://localhost:4096/api/fs/read/a.png?location%5Bdirectory%5D=%2Frepo")!)
  #expect(local.url?.host == "opencode.example")
  #expect(local.value(forHTTPHeaderField: "Authorization") != nil)
  for source in ["http://seaweedfs-svc:8333/a.png?signature=secret", "https://example.com/a.png"] {
    let request = try client.imageRemoteRequest(URL(string: source)!)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.url?.absoluteString == source)
  }
  #expect(throws: FeedImageFailure.loopbackUnavailable) {
    try client.imageRemoteRequest(URL(string: "http://localhost:3000/a.png")!)
  }
  #expect(FeedImageReference.display("http://seaweedfs-svc/a?signature=secret") == "http://seaweedfs-svc/a")
}

@Test func feedImageFilePartsUseURIAndOmittedMediaNeedsHydration() {
  #expect(FeedImage.attachment(.object(["type": .string("file"), "mime": .string("image/png"),
    "uri": .string("data:image/png;base64,abc"), "name": .string("Tela")])) == FeedImage(source: "data:image/png;base64,abc", name: "Tela"))
  #expect(FeedImage.attachment(.object(["mime": .string("image/png"), "data": .string("abc")]))?.source == "data:image/png;base64,abc")
  #expect(FeedImage.attachment(.object(["type": .string("file"), "mime": .string("image/png"),
    "uri": .string("data:image/png;base64,")])) == nil)
}

@Test func feedImageCacheReusesDiskAndScopesCredentialsAndDirectory() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let data = try Data(contentsOf: Bundle.module.url(forResource: "message-full-tool-image", withExtension: "json", subdirectory: "Conversation")!)
  let message = try JSONDecoder().decode(DataResponse<ConversationMessage>.self, from: data).data
  let image = try #require(message.content?.flatMap { $0.state?.object?["content"]?.array ?? [] }.compactMap(FeedImage.attachment).first)
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://sandbox.test")!, password: "one"))
  let first = FeedImageLoader(directory: root)
  let thumb = try await first.load(image.source, client: client, directory: "/repo", maxPixelSize: 32)
  #expect(max(thumb.width, thumb.height) == 32)
  let second = FeedImageLoader(directory: root)
  #expect(try await second.load(image.source, client: client, directory: "/repo", maxPixelSize: 64).width <= 64)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
  #expect(FeedImageLoader.cacheKey(image.source, configuration: client.configuration, directory: "/repo") != FeedImageLoader.cacheKey(image.source,
    configuration: ServerConfiguration(url: client.configuration.url, password: "two"), directory: "/repo"))
  #expect(FeedImageLoader.cacheKey(image.source, configuration: client.configuration, directory: "/repo") != FeedImageLoader.cacheKey(image.source,
    configuration: client.configuration, directory: "/other"))
  await #expect(throws: FeedImageFailure.invalidImage) {
    try await first.load("data:image/png;base64,bm90LWFuLWltYWdl", client: client, directory: "/repo", maxPixelSize: 32)
  }
  #expect(FeedImageFailure.map(ClientError.http(401)) == .authentication)
  #expect(FeedImageFailure.map(ClientError.http(403)) == .outsideDirectory)
  #expect(FeedImageFailure.map(URLError(.cannotFindHost)) == .network)
}

private actor ImageRequestCounter {
  var count = 0
  func increment() { count += 1 }
}

@Test func feedImageCacheJoinsRequestsAndEvictsAtItsLimits() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let message = try JSONDecoder().decode(DataResponse<ConversationMessage>.self, from:
    Data(contentsOf: Bundle.module.url(forResource: "message-full-tool-image", withExtension: "json", subdirectory: "Conversation")!)).data
  let image = try #require(message.content?.flatMap { $0.state?.object?["content"]?.array ?? [] }.compactMap(FeedImage.attachment).first)
  let comma = try #require(image.source.firstIndex(of: ","))
  let data = try #require(Data(base64Encoded: String(image.source[image.source.index(after: comma)...])))
  let counter = ImageRequestCounter()
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://sandbox.test")!, password: "fixture")) { request in
    await counter.increment()
    #expect(request.url?.path == "/api/fs/read/a.png")
    #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
    return (data, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
  }
  let loader = FeedImageLoader(directory: root)
  async let first = loader.load("/repo/a.png", client: client, directory: "/repo", maxPixelSize: 32)
  async let second = loader.load("/repo/a.png", client: client, directory: "/repo", maxPixelSize: 32)
  _ = try await (first, second)
  #expect(await counter.count == 1)
  let bounded = FeedImageLoader(directory: root, memoryLimit: 1, diskLimit: 0)
  _ = try await bounded.load("/repo/b.png", client: OpenCodeClient(configuration: client.configuration) { request in
    (data, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
  }, directory: "/repo", maxPixelSize: 32)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func feedImageRealTemasReadOnlyAudit() throws {
  guard let path = ProcessInfo.processInfo.environment["OPENCODE_IMAGE_AUDIT_PATH"] else { return }
  let page = try JSONDecoder().decode(ConversationPage.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  let directory = "/Users/alexandremartins/Worktrees/playful-falcon"
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!))
  let markdown = page.data.flatMap { ($0.content ?? []).filter { $0.type == "text" }.flatMap {
    MarkdownBlocks.parse($0.text ?? "").compactMap { block -> FeedImage? in
      guard case .image(let source) = block.kind else { return nil }
      return FeedImage(source: source, name: block.text)
    }
  } }
  let files = page.data.flatMap { ($0.content ?? []).flatMap {
    $0.state?.object?["content"]?.array?.compactMap(FeedImage.attachment) ?? []
  } }
  #expect(page.data.count >= 55)
  #expect(markdown.count == 6)
  #expect(files.count == 20)
  for image in markdown {
    let request = client.imageFileRequest(path: try FeedImageReference(image.source).path(directory: directory, home: nil))
    #expect(request.url?.path.hasPrefix("/api/fs/read/") == true)
  }
  for image in files {
    let comma = try #require(image.source.firstIndex(of: ","))
    let data = try #require(Data(base64Encoded: String(image.source[image.source.index(after: comma)...])))
    #expect(AttachmentImage.thumbnail(data, maxPixelSize: 160) != nil)
  }
}
