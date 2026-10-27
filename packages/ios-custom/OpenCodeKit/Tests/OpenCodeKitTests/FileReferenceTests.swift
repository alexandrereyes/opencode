import Foundation
import Testing
@testable import OpenCodeKit

@Test func fileReferenceInlineCandidatesMatchWebAndIgnoreIncompletePaths() {
  for path in ["/private/tmp/video.mp4", "~/Pictures/a.png", "./docs/a.md", "docs/a.md", "README", "Makefile:12", "src/file.ts:12:4-18:2:", "app/(auth)/[id]/page.tsx", " console.log "] {
    #expect(FileReference.inline(path) != nil, "\(path)")
  }
  for text in ["value", "readme", "1.2.3", "127.0.0.1:8080", "foo(bar)", "a*.png", "a{b}.png", "x = y.ts", "//host/file.png", "\\\\host\\file.png", "…/image.png", ".../image.png", "https://example.com/a.png", "data:image/png;base64,abc"] {
    #expect(FileReference.inline(text) == nil, "\(text)")
  }
  #expect(FileReference.local("~/Pictures/a.png") == "~/Pictures/a.png")
  #expect(FileReference.local("docs/a.swift#L12C4-L18C2") == "docs/a.swift")
  #expect(FileReference.local("docs/a.swift:12:4-18:2:") == "docs/a.swift")
  #expect(FileReference.local("file:///Users/mac/image%20one.png") == "/Users/mac/image one.png")
  #expect(FileReference.local("…/final-dark.mp4") == nil)
  #expect(FileReference.local("https://example.com/a.png") == nil)
  #expect(FileReference.inlineURL(" https://example.com/a.png. ")?.absoluteString == "https://example.com/a.png")
  #expect(FileReference.inlineURL("HTTPS://example.com") == nil)
  #expect(FileReference.inlineURL("http://example.com/a b") == nil)
  #expect(FileReference.path(FileReference.link("/Users/mac/ação #one.png")) == "/Users/mac/ação #one.png")
}

@Test func fileViewerRoutesTypesAndRequiresConsentBeforeLargeDownloads() {
  for ext in ["png", "JPEG", "heic", "webp"] { #expect(FileViewerKind(path: "a.\(ext)") == .image) }
  for ext in ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac"] { #expect(FileViewerKind(path: "a.\(ext)") == .audiovisual) }
  for ext in ["pdf", "txt", "swift", "ts", "md", "json", "csv", "docx"] { #expect(FileViewerKind(path: "a.\(ext)") == .preview) }
  #expect(FileViewerKind(path: "file.opaque") == .unknown)
  #expect(FileViewerKind(path: "/repo/Dockerfile") == .preview)
  #expect(FileViewerKind(path: "/repo/.gitignore") == .preview)
  #expect(FileViewerKind(path: "/repo/source.ts", mime: "video/mp2t") == .preview)
  #expect(FileViewerKind(path: "/repo/icon.svg", mime: "image/svg+xml") == .preview)
  #expect(FileViewerKind(path: "/repo/icon", mime: "image/svg+xml") == .preview)
  #expect(FileViewerKind(path: "no-extension", mime: "video/mp4") == .audiovisual)
  #expect(!FileViewerKind.requiresConfirmation(nil))
  #expect(!FileViewerKind.requiresConfirmation(50 * 1024 * 1024))
  #expect(FileViewerKind.requiresConfirmation(50 * 1024 * 1024 + 1))
}

@Test func fileRequestsReuseAuthenticationAndParentDirectoryWithoutTheImageRangeLimit() {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://server.test")!, password: "fixture"))
  let request = client.fileRequest(path: "/private/tmp/outside/video ?#.mp4")
  #expect(request.url?.path == "/api/fs/read/video ?#.mp4")
  #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
    URLQueryItem(name: "location[directory]", value: "/private/tmp/outside")
  ])
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(Data("opencode:fixture".utf8).base64EncodedString())")
  #expect(request.value(forHTTPHeaderField: "Range") == nil)
  #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
  #expect(client.fileRequest(path: "/repo/video.mp4", metadata: true).value(forHTTPHeaderField: "Range") == "bytes=0-0")
  let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
    headerFields: ["Content-Range": "bytes 0-0/60000000", "Content-Length": "1", "Content-Type": "video/mp4"])!
  #expect(FileMetadata(response: response).size == 60_000_000)
  #expect(FileMetadata(response: response).mime == "video/mp4")
  #expect(FileTransferFailure.map(ClientError.http(404)) == .notFound)
  #expect(FileTransferFailure.map(URLError(.notConnectedToInternet)) == .connection)
}

@Test func fileLinkExistenceUsesListingsAndWebExactSuffixAmbiguityRules() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://server.test")!)) { request in
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    let directory = query.first { $0.name == "location[directory]" }?.value
    if request.url?.path == "/api/fs/list" {
      #expect(directory == "/private/tmp")
      return (Data(#"{"data":[{"path":"video.mp4","type":"file"},{"path":"folder","type":"directory"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(request.url?.path == "/api/fs/find")
    #expect(directory == "/repo")
    #expect(query.contains(URLQueryItem(name: "limit", value: "200")))
    #expect(query.contains(URLQueryItem(name: "type", value: "file")))
    return (Data(#"{"data":[{"path":"docs/a.md","type":"file"},{"path":"other/docs/a.md","type":"file"},{"path":"docs","type":"directory"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.fileLinkMatches("/private/tmp/video.mp4", directory: "/repo") == ["/private/tmp/video.mp4"])
  #expect(try await client.fileLinkMatches("/private/tmp/missing.mp4", directory: "/repo").isEmpty)
  #expect(try await client.fileLinkMatches("docs/a.md", directory: "/repo") == ["/repo/docs/a.md"])
  #expect(try await client.fileLinkMatches("a.md", directory: "/repo") == ["/repo/docs/a.md", "/repo/other/docs/a.md"])
}

@Test func fileSiblingsKeepServerOrderSkipFoldersAndUnviewableKindsInsideOrOutsideTheSession() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://server.test")!)) { request in
    #expect(request.url?.path == "/api/fs/list")
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.contains(URLQueryItem(name: "location[directory]", value: "/repo")))
    let folder = query.first { $0.name == "path" }!.value!
    let prefix = folder == "/repo/shots" ? "shots/" : "../tmp/"
    // fs.list order: directories first, then localeCompare; paths stay relative to the Session Location.
    return (Data(#"{"location":{"directory":"/repo"},"data":[{"path":"\#(prefix)nested/","type":"directory"},{"path":"\#(prefix)a.png","type":"file"},{"path":"\#(prefix).DS_Store","type":"file"},{"path":"\#(prefix)B.md","type":"file"},{"path":"\#(prefix)blob.opaque","type":"file"},{"path":"\#(prefix)c.mp4","type":"file"}]}"#.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.fileSiblings(of: "/repo/shots/B.md", location: "/repo")
    == ["/repo/shots/a.png", "/repo/shots/B.md", "/repo/shots/c.mp4"])
  #expect(try await client.fileSiblings(of: "/repo/shots/blob.opaque", location: "/repo")
    == ["/repo/shots/a.png", "/repo/shots/B.md", "/repo/shots/blob.opaque", "/repo/shots/c.mp4"])
  #expect(try await client.fileSiblings(of: "/repo/shots/gone.png", location: "/repo") == nil)
  #expect(try await client.fileSiblings(of: "/tmp/c.mp4", location: "/repo")
    == ["/tmp/a.png", "/tmp/B.md", "/tmp/c.mp4"])
}

@Test func fileLinkTargetsDistinguishFoldersFilesAndMissingPaths() async throws {
  // Server tree: /repo/{docs/, docs/screens/, docs/notes.md, app/docs/screens/}, /tmp/{shots/, a.png}
  let tree: [String: [(String, String)]] = [
    "/repo": [("docs", "directory"), ("app", "directory"), ("README.md", "file")],
    "/repo/docs": [("screens", "directory"), ("notes.md", "file")],
    "/repo/app": [("docs", "directory")],
    "/repo/app/docs": [("screens", "directory")],
    "/tmp": [("shots", "directory"), ("a.png", "file")],
  ]
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://server.test")!)) { request in
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
    let value = { (name: String) in query.first { $0.name == name }?.value }
    let ok = { (body: String) in (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
    if request.url?.path == "/api/fs/list" {
      // The resolver lists with `path` in the Session Location; the file matcher lists the parent as Location.
      let location = value("location[directory]")!
      let folder = value("path") ?? location
      guard let entries = tree[folder] else {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
      }
      let items = entries.map { name, type in
        let absolute = folder + "/" + name
        let relative = absolute.hasPrefix(location + "/") ? String(absolute.dropFirst(location.count + 1))
          : "../" + absolute.dropFirst(1)
        return #"{"path":"\#(relative)\#(type == "directory" ? "/" : "")","type":"\#(type)"}"#
      }
      return ok(#"{"location":{"directory":"\#(location)"},"data":[\#(items.joined(separator: ","))]}"#)
    }
    #expect(request.url?.path == "/api/fs/find")
    #expect(value("location[directory]") == "/repo")
    let all = [("docs/", "directory"), ("docs/screens/", "directory"), ("app/docs/screens/", "directory"),
      ("app/", "directory"), ("app/docs/", "directory"), ("docs/notes.md", "file"), ("README.md", "file")]
    let items = all.filter { $0.1 == value("type") }.map { #"{"path":"\#($0.0)","type":"\#($0.1)"}"# }
    return ok(#"{"location":{"directory":"/repo"},"data":[\#(items.joined(separator: ","))]}"#)
  }
  #expect(try await client.fileLinkTarget("docs/screens/", directory: "/repo") == .directory("/repo/docs/screens"))
  #expect(try await client.fileLinkTarget("docs/screens", directory: "/repo") == .directory("/repo/docs/screens"))
  #expect(try await client.fileLinkTarget("./docs", directory: "/repo") == .directory("/repo/docs"))
  #expect(try await client.fileLinkTarget("/tmp/shots/", directory: "/repo") == .directory("/tmp/shots"))
  #expect(try await client.fileLinkTarget("../tmp/shots", directory: "/repo") == .directory("/tmp/shots"))
  // A unique folder ending with the path, like files; an ambiguous suffix is not guessed.
  #expect(try await client.fileLinkTarget("app/docs/screens", directory: "/repo") == .directory("/repo/app/docs/screens"))
  #expect(try await client.fileLinkTarget("screens/", directory: "/repo") == nil)
  #expect(try await client.fileLinkTarget("docs/notes.md", directory: "/repo") == .file)
  #expect(try await client.fileLinkTarget("/tmp/a.png", directory: "/repo") == .file)
  #expect(try await client.fileLinkTarget("docs/missing/", directory: "/repo") == nil)
  #expect(try await client.fileLinkTarget("https://github.com/o/r/tree/main/docs", directory: "/repo") == nil)
}

@Test func filePreviewStorageKeepsOriginalNameAndDeletesOnlyOwnedFiles() throws {
  let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("fixture".utf8).write(to: source)
  let stored = try FilePreviewStorage.store(source, name: "example.txt")
  #expect(stored.lastPathComponent == "example.txt")
  #expect(try String(contentsOf: stored, encoding: .utf8) == "fixture")
  FilePreviewStorage.remove(stored)
  #expect(!FileManager.default.fileExists(atPath: stored.path))
}

@Test func htmlFilesHaveTheirOwnViewerKindAndALowerDownloadConfirmation() {
  for path in ["a.html", "b.HTM", "/repo/report/index.html"] { #expect(FileViewerKind(path: path) == .html, "\(path)") }
  #expect(FileViewerKind(path: "page", mime: "text/html") == .html)
  #expect(FileViewerKind(path: "notes.txt", mime: "text/html") == .preview)
  #expect(FileViewerKind(path: "a.md") == .preview)
  #expect(FileViewerKind.html.confirmationBytes == 25 * 1024 * 1024)
  #expect(!FileViewerKind.html.requiresConfirmation(25 * 1024 * 1024))
  #expect(FileViewerKind.html.requiresConfirmation(25 * 1024 * 1024 + 1))
  #expect(!FileViewerKind.preview.requiresConfirmation(25 * 1024 * 1024 + 1))
  #expect(FileViewerKind.image.requiresConfirmation(50 * 1024 * 1024 + 1))
  #expect(FileSiblings.ordered([DirectoryEntry(name: "a.html", absolute: "/r/a.html", kind: .file),
    DirectoryEntry(name: "b.htm", absolute: "/r/b.htm", kind: .file)], current: "/r/a.html") == ["/r/a.html", "/r/b.htm"])
}

@Test func htmlPreviewAllowsOnlyItsDocumentAndOpensTappedLinksOutside() {
  func decide(_ link: String?, main: Bool = true, link activated: Bool = false, touch: Bool = false) -> HTMLPreviewPolicy.Decision {
    HTMLPreviewPolicy.decide(link.flatMap(URL.init(string:)), mainFrame: main, linkActivated: activated, recentTouch: touch)
  }
  // The initial `loadHTMLString(_, baseURL: nil)` document and its in-page anchors.
  #expect(decide("about:blank") == .allow)
  #expect(decide("about:blank#resultados", link: true, touch: true) == .allow)
  #expect(decide("about:srcdoc", main: false) == .allow)
  #expect(decide("about:srcdoc") == .cancel)
  // A tapped link leaves for the system browser; the same link clicked by script without a touch does not.
  #expect(decide("https://example.com/docs", link: true, touch: true) == .openExternally(URL(string: "https://example.com/docs")!))
  #expect(decide("mailto:a@example.com", link: true, touch: true) == .openExternally(URL(string: "mailto:a@example.com")!))
  #expect(decide("https://example.com/docs", link: true, touch: false) == .cancel)
  // Script navigation of the page (`location =`, form posts, reloads) and local or app schemes.
  #expect(decide("https://example.com/escape") == .cancel)
  #expect(decide("https://example.com/escape", touch: true) == .cancel)
  #expect(decide("file:///etc/hosts", link: true, touch: true) == .cancel)
  #expect(decide("opencode-file://open?path=/etc/hosts", link: true, touch: true) == .cancel)
  #expect(decide("javascript:alert(1)", link: true, touch: true) == .cancel)
  #expect(decide(nil) == .cancel)
  // Embedded frames may load web content, like the web app's sandboxed iframe; not local files.
  #expect(decide("https://example.com/embed", main: false) == .allow)
  #expect(decide("data:text/html,oi", main: false) == .allow)
  #expect(decide("file:///etc/hosts", main: false) == .cancel)
}

@Test func htmlPreviewScopeServesOnlyThePageFolderAndItsSession() {
  // Outside the Session (the reported temporary folder): only the page's folder and below.
  let outside = HTMLPreviewScope(file: "/tmp/live/index.html", sessionDirectory: "/repo", token: "t")
  #expect(outside.roots == ["/tmp/live"])
  #expect(outside.pageURL.absoluteString == "opencode-preview://t/tmp/live/index.html")
  func resolve(_ scope: HTMLPreviewScope, _ link: String) -> String? {
    URL(string: link, relativeTo: scope.pageURL).flatMap { scope.resolve($0.absoluteURL) }.map { $0.root + " | " + $0.relative }
  }
  #expect(resolve(outside, "t3code/real-lockscreen-detail.png") == "/tmp/live | t3code/real-lockscreen-detail.png")
  #expect(resolve(outside, "./css/estilo%20novo.css") == "/tmp/live | css/estilo novo.css")
  #expect(resolve(outside, "a/../b/c.js") == "/tmp/live | b/c.js")
  #expect(resolve(outside, "../segredo.txt") == nil)
  #expect(resolve(outside, "../../../etc/hosts") == nil)
  #expect(resolve(outside, "/etc/hosts") == nil)
  #expect(resolve(outside, "/tmp/livedata/x.png") == nil, "a sibling sharing the prefix")
  #expect(resolve(outside, "pasta/") == nil)
  #expect(resolve(outside, "opencode-preview://outro/tmp/live/a.png") == nil, "another page's origin")
  #expect(resolve(outside, "https://example.com/a.png") == nil)
  #expect(resolve(outside, "file:///tmp/live/a.png") == nil)
  // Inside the Session: the page's folder first (the innermost Location), then the Session directory.
  let inside = HTMLPreviewScope(file: "/repo/docs/report/index.html", sessionDirectory: "/repo/", token: "t")
  #expect(inside.roots == ["/repo/docs/report", "/repo"])
  #expect(resolve(inside, "img/a.png") == "/repo/docs/report | img/a.png")
  #expect(resolve(inside, "../../assets/base.css") == "/repo | assets/base.css")
  #expect(resolve(inside, "../../../etc/hosts") == nil)
  #expect(inside.isPage(URL(string: "opencode-preview://t/repo/docs/other.html")!))
  #expect(!inside.isPage(URL(string: "opencode-preview://t/repo/docs/a.png")!))
  #expect(HTMLPreviewScope(file: "/repo/index.html", sessionDirectory: "/repo", token: "t").roots == ["/repo"])
}

@Test func htmlPreviewResourcesHaveTheirWebTypes() {
  for (path, mime) in [("a.html", "text/html"), ("a.HTM", "text/html"), ("s.css", "text/css"), ("m.mjs", "text/javascript"),
    ("a.js", "text/javascript"), ("f.woff2", "font/woff2"), ("i.svg", "image/svg+xml"), ("p.png", "image/png"),
    ("j.JPG", "image/jpeg"), ("d.json", "application/json"), ("x.wasm", "application/wasm"), ("blob", "application/octet-stream")] {
    #expect(HTMLPreviewScope.mime(path) == mime, "\(path)")
  }
  #expect(HTMLPreviewScope.contentSecurityPolicy.contains("connect-src 'self' data: blob:"))
  #expect(HTMLPreviewScope.contentSecurityPolicy.contains("form-action 'none'"))
  #expect(HTMLPreviewScope.contentSecurityPolicy.contains("frame-src 'self' blob:"))
}

@Test func htmlPreviewResourcesReadWithTheScopeRootAsLocationAndALimit() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "https://server.test")!, password: "fixture")) { request in
    #expect(request.url?.path(percentEncoded: false) == "/api/fs/read/t3code/a b.png")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      == [URLQueryItem(name: "location[directory]", value: "/tmp/live")])
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(HTMLPreviewScope.resourceLimit)")
    return (Data("png".utf8), HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.previewResource("t3code/a b.png", root: "/tmp/live") == Data("png".utf8))
}

@Test func htmlPreviewLocalModeNavigatesOnlyInsideItsOrigin() {
  let scope = HTMLPreviewScope(file: "/tmp/cov/index.html", sessionDirectory: "/repo", token: "t")
  let page = scope.pageURL
  func decide(_ link: String, main: Bool = true, link activated: Bool = false, touch: Bool = false, initial: Bool = false,
    back: Bool = false) -> HTMLPreviewPolicy.Decision {
    HTMLPreviewPolicy.decide(URL(string: link, relativeTo: page)?.absoluteURL, mainFrame: main, linkActivated: activated,
      recentTouch: touch, scope: scope, current: page, initial: initial, backForward: back)
  }
  #expect(decide(page.absoluteString, initial: true) == .allow)
  #expect(decide("src/file.ts.html", link: true, touch: true) == .allow, "a tapped link to another page of the report")
  #expect(decide("src/file.ts.html") == .cancel, "script navigation")
  #expect(decide("src/file.ts.html", link: true) == .cancel, "script click")
  #expect(decide("img/a.png", link: true, touch: true) == .cancel, "not a page")
  #expect(decide("#?testId=1") == .allow, "hash routing on the same page")
  #expect(decide("src/file.ts.html", back: true) == .allow)
  #expect(decide("../fora.html", link: true, touch: true) == .cancel)
  #expect(decide("frame.html", main: false) == .allow)
  #expect(decide("opencode-preview://outro/tmp/cov/index.html", main: false) == .cancel)
  // No network in this mode: web frames are refused; a tapped link still leaves for Safari.
  #expect(decide("https://example.com/embed", main: false) == .cancel)
  #expect(decide("data:text/html,oi", main: false) == .cancel)
  #expect(decide("https://example.com/", link: true, touch: true) == .openExternally(URL(string: "https://example.com/")!))
  #expect(decide("https://example.com/") == .cancel)
}
