#if DEBUG
import OpenCodeKit
import Foundation
import SwiftUI

enum MarkdownFixtures {
  static func snapshot(_ snapshot: ScrollFixtureSnapshot) -> ScrollFixtureSnapshot {
    let source = try! String(contentsOf: Bundle.main.url(forResource: "markdown-fixture", withExtension: "md")!, encoding: .utf8)
    var user = snapshot.messages.first { $0.type == "user" }!
    user.text = "Mostre o documento de teste de formatação."
    var answer = snapshot.messages.first { $0.type == "assistant" && $0.content?.contains { $0.type == "text" } == true }!
    var part = answer.content!.first { $0.type == "text" }!
    part.text = source
    answer.content = [part]
    return ScrollFixtureSnapshot(
      messages: [user, answer], entries: snapshot.entries, projects: snapshot.projects,
      preferences: snapshot.preferences, models: snapshot.models)
  }
}

struct MarkdownFixtureCaptureDriver: UIViewRepresentable {
  func makeUIView(context: Context) -> Driver { Driver() }
  func updateUIView(_ view: Driver, context: Context) {}
  static func dismantleUIView(_ view: Driver, coordinator: Void) { view.stop() }

  final class Driver: UIView {
    private var link: CADisplayLink?
    private var started: CFTimeInterval?
    private var cancelledAnchor = false
    private var searchFrames = 0
    private var status = "Aguardando a coleção"
    private let captureText: String? = {
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.firstIndex(of: "-OpenCodeMarkdownCaptureText").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
    }()
    private let section: Int? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard arguments.contains("-OpenCodeMarkdownFixture"), let index = arguments.firstIndex(of: "-OpenCodeMarkdownSection"),
        arguments.indices.contains(index + 1), let section = Int(arguments[index + 1]), (0...16).contains(section) else { return nil }
      return section
    }()
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil, section != nil, link == nil else { if window == nil { stop() }; return }
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
      self.link = link
      link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
      if started == nil { started = link.timestamp }
      guard let section, let window else { stop(); return }
      if link.timestamp - (started ?? link.timestamp) > 60 { finish(error: status); return }
      guard link.timestamp - (started ?? link.timestamp) >= 3 else { return }
      guard let scroll = findScroll(window), scroll.accessibilityValue != "Restaurando leitura" else { return }
      if !cancelledAnchor { ScrollFixtures.scrollState?.cancelAnchor(); cancelledAnchor = true }
      let top = -scroll.adjustedContentInset.top
      let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      guard let heading = findHeading(window, section: section), heading.bounds.height > 0 else {
        status = "Aguardando a materialização do título \(section)"
        searchFrames += 1
        if searchFrames >= 4 {
          searchFrames = 0
          scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.7)), animated: false)
        }
        return
      }
      status = "Alinhando a geometria do título \(section)"
      let requestedTop = UserDefaults.standard.double(forKey: "OpenCodeMarkdownCaptureTop")
      let delta = heading.convert(heading.bounds, to: window).minY - (requestedTop > 0 ? requestedTop : 240)
      let target = min(bottom, max(top, scroll.contentOffset.y + delta))
      ScrollFixtures.scrollState?.cancelAnchor()
      scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
      scroll.layoutIfNeeded()
      finish(offset: scroll.contentOffset.y, headingTop: heading.convert(heading.bounds, to: window).minY,
        readingBottom: scroll.convert(scroll.bounds, to: window).maxY)
    }
    private func findScroll(_ view: UIView) -> UICollectionView? {
      if let scroll = view as? UICollectionView, scroll.bounds.height > 200 { return scroll }
      return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
    private func findHeading(_ view: UIView, section: Int) -> ResponseTextView? {
      if let text = view as? ResponseTextView, let block = text.sourceBlock {
        if let captureText { return block.copyText.contains(captureText) ? text : nil }
        if section == 0 && block.kind == .heading(1) && block.copyText == "✨ Formatação no OpenChamber" { return text }
        if section > 0 && block.kind == .heading(2) && block.copyText.hasPrefix("\(section). ") { return text }
      }
      return view.subviews.lazy.compactMap { self.findHeading($0, section: section) }.first
    }
    private func finish(offset: CGFloat = 0, headingTop: CGFloat? = nil, readingBottom: CGFloat? = nil, error: String? = nil) {
      struct Report: Encodable {
        let runID: String
        let section: Int
        let offset: Double
        let headingTop: Double?
        let readingBottom: Double?
        let error: String?
      }
      let arguments = ProcessInfo.processInfo.arguments
      let run = arguments.firstIndex(of: "-OpenCodeFixtureRunID").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
      let report = Report(runID: run, section: section ?? -1, offset: offset,
        headingTop: headingTop.map(Double.init), readingBottom: readingBottom.map(Double.init), error: error)
      if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        try? JSONEncoder().encode(report).write(to: url.appendingPathComponent("markdown-capture-ready.json"), options: .atomic)
      }
      stop()
    }
    func stop() { link?.invalidate(); link = nil }
  }
}
#endif
