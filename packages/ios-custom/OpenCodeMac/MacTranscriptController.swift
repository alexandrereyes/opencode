import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// The Mac transcript: the iPhone's model (`TranscriptProjection` items, `TranscriptGeometry` positions, the pinned
/// prompt, reading anchors, the trailing space under a sent prompt) on an `NSScrollView` with its own flipped
/// document. Only the items near the viewport have views; each is measured at the column's width when it first
/// appears, and the reader's place is kept in the same pass in which anything above it changes size.
///
/// Platform differences, parametrized here: the wheel or trackpad instead of touch (no pull), the keyboard
/// (Page Up/Down, space, ⌘↑/⌘↓, Home/End), window resizing, and following the end while an answer arrives:
/// the Mac keeps the end in view while the reader is there and stops as soon as they scroll up.
@MainActor final class MacTranscriptController: NSViewController {
  let store: ConversationStore
  let context: MacTranscriptContext
  private let reading: ReadingPositionStore
  private let memory: TranscriptMemory
  private var state: TranscriptState { memory.state }
  private let scrollView = MacTranscriptScrollView()
  private let document = MacTranscriptDocument()
  private(set) var items: [TranscriptItem] = []
  private(set) var geometry = TranscriptGeometry(topPadding: 16, bottomPadding: 16)
  private var measured: [Bool] = []
  private var owners: [TranscriptOwner] = []
  private var cells: [String: MacTranscriptCell] = [:]
  private var spareHosts: [MacHostCell] = []
  private var spareProse: [MacProseCell] = []
  private let parses = MacTranscriptParses()
  private var rebuildScheduled = false
  private(set) var revealed = false
  private var target: ReadingPosition?
  private var restorePages = 0
  private var paging: Task<Void, Never>?
  private var captureTask: Task<Void, Never>?
  private var submitted: Int
  private var awaitingPrompt: ContinuousClock.Instant?
  private var width: CGFloat = 0
  private var height: CGFloat = 0
  private(set) var mounted = false
  private var collapsible = UserDefaults.standard.object(forKey: "OpenCodeCollapsibleUserMessages") as? Bool ?? true
  /// Following the end as content grows (scrolling up stops it, scrolling back to the end resumes it) and
  /// whether the reader's wheel, trackpad or scroller owns the offset.
  private var follow = TranscriptFollow()
  var following: Bool { follow.following }
  private var interacting: Bool { follow.interacting }
  private var interactionEnd: Task<Void, Never>?
  private var animating: (() -> CGFloat)?
  private var tiling = false
  private var contentFloor: CGFloat = 0
  private var readingToken: UUID?
  var canPersist: () -> Bool = { true }
  #if DEBUG
  var tiled: () -> Void = {}
  #endif

  init(store: ConversationStore, memory: TranscriptMemory, reading: ReadingPositionStore, client: OpenCodeClient) {
    self.store = store
    self.memory = memory
    self.reading = reading
    context = MacTranscriptContext(store: store, memory: memory, client: client)
    submitted = store.submitted
    target = memory.anchor ?? reading.position(store.id) ?? ReadingPosition(.followTail)
    super.init(nibName: nil, bundle: nil)
    geometry.spacerPrompt = memory.spacerPrompt
    parses.landed = { [weak self] in self?.scheduleRebuild() }
    parses.rasterized = { [weak self] in self?.context.rasterRevision += 1 }
    context.blockLookup = { [weak self] in self?.parses.blocks($0) }
    context.rasterLookup = { [weak self] in self?.parses.rasters($0) ?? [:] }
    context.loadOlder = { [weak self] in self?.loadOlder() }
    context.revealTurn = { [weak self] in self?.revealTurn($0) ?? false }
    context.scrollKey = { [weak self] in self?.scrollKey($0) ?? false }
  }
  required init?(coder: NSCoder) { nil }

  // MARK: View

  override func loadView() {
    let container = NSView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = MacThinScroller()
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.verticalScrollElasticity = .allowed
    scrollView.horizontalScrollElasticity = .none
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.documentView = document
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alphaValue = 0
    scrollView.setAccessibilityIdentifier("conversation-transcript")
    scrollView.userScrolled = { [weak self] in self?.userScrolled($0) }
    document.keyHandler = { [weak self] in self?.scrollKey($0) ?? false }
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
    center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification,
      object: scrollView)
    center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeContext()
    rebuild()
  }

  func mount() {
    mounted = true
    memory.mount(self)
  }

  func unmount() {
    mounted = false
    memory.unmount(self)
    capture()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let size = scrollView.contentView.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    if size.width != width {
      // Every height depends on the width; keep the reader's place (or the end) through the change.
      let anchor = revealed ? stableAnchor() : nil
      let end = revealed && (following || distanceToLatest <= 1)
      width = size.width
      height = size.height
      context.inset = max(MacTranscriptContext.minimumInset, (width - MacTranscriptContext.column) / 2)
      context.width = width
      context.viewport = height
      relayout()
      if end { setOffset(latestOffset) } else if let anchor { restore(anchor) }
    } else if size.height != height {
      // The composer or the suggestion panel resized the viewport: the end stays at the end, anything else stays.
      let end = revealed && (follow.keepsLatest || distanceToLatest <= 1)
      height = size.height
      context.viewport = height
      tile()
      if end { setOffset(latestOffset) }
    }
    if !revealed { positionInitially() }
    tile()
    publishState()
  }

  func update(theme: AppTheme, quotes: ConversationQuoteContext, search: ConversationSearchHighlight,
    bottomPadding: CGFloat, collapsible: Bool)
  {
    if self.collapsible != collapsible {
      // Every prompt changes height: measure again, keeping the reader's place. Turning folding off also forgets
      // the bubbles opened by hand, like the iPhone.
      self.collapsible = collapsible
      if !collapsible {
        for item in items { if case .prompt(let message, true) = item.kind { memory.setBubble(message.id, expanded: false) } }
      }
      memory.heights.removeAll()
      for cell in cells.values { cell.invalidate() }
      if isViewLoaded { invalidateAll() }
    }
    if context.theme.id != theme.id {
      context.theme = theme
      parses.theme = theme
      parses.restyle(items.compactMap(\.part))
      for cell in cells.values { cell.invalidate() }
      if isViewLoaded { invalidateAll() }
    }
    if context.quotes != quotes { context.quotes = quotes }
    if context.search != search { context.search = search }
    parses.scale = view.window?.backingScaleFactor ?? 2
    if geometry.bottomPadding != Double(bottomPadding) {
      geometry.bottomPadding = Double(bottomPadding)
      if isViewLoaded { tile() }
    }
  }

  /// Native text cells read the context when configured; reconfigure them when what they draw changes.
  private func observeContext() {
    withObservationTracking {
      _ = (context.theme.id, context.search, context.quotes, context.rasterRevision)
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observeContext()
        for (id, cell) in self.cells {
          guard let prose = cell as? MacProseCell, let item = self.items.first(where: { $0.id == id }),
            case .prose(let part, let value) = item.kind else { continue }
          prose.configure(part, prose: value, context: self.context)
        }
        self.invalidateAll()
      }
    }
  }

  private func invalidateAll() {
    for index in measured.indices { measured[index] = false }
    tile()
  }

  // MARK: Items

  private var lastRebuild: CFTimeInterval = 0
  /// At most one rebuild per display frame: a streamed delta and the parse it causes land together.
  private func scheduleRebuild() {
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    let wait = max(0, lastRebuild + 1.0 / 60 - CACurrentMediaTime())
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      self?.rebuildScheduled = false
      self?.rebuild()
    }
  }

  private func rebuild() {
    lastRebuild = CACurrentMediaTime()
    var stale: [TranscriptPart] = []
    let next = withObservationTracking {
      projection(stale: { stale.append($0) })
    } onChange: { [weak self] in
      Task { @MainActor in self?.scheduleRebuild() }
    }
    stale.forEach(parses.request)
    if store.submitted != submitted {
      submitted = store.submitted
      awaitingPrompt = .now
    }
    apply(next)
    requestVisibleParses()
    revealSentPrompt()
    if let request = store.readingRequest, request.token != readingToken {
      readingToken = request.token
      reveal(messageID: request.messageID, offset: request.offset, animated: true, persist: request.persist)
    }
  }

  private func projection(stale: @escaping (TranscriptPart) -> Void) -> [TranscriptItem] {
    let messages = store.messages
    _ = (store.submitted, store.error, store.readingRequest)
    let input = TranscriptProjection.Input(
      messages: store.activity.messages,
      marks: TranscriptMarks(messages, working: store.working),
      dividers: ConversationProjection.finalAnswerDividers(messages),
      pending: store.pendingSteers,
      permissions: store.family?.permissions ?? [],
      questions: (store.family?.forms ?? []).filter { $0.metadata?["kind"]?.string == "question" },
      hasOlder: store.hasOlder && store.hasTranscript, paging: store.paging,
      expansion: store.expansionValues,
      bubbles: { [memory] in memory.bubble($0) },
      blocks: { [parses] part in
        guard let parsed = parses.parsed(part) else { return nil }
        if parsed.source != part.source { stale(part) }
        return (parsed.source, parsed.sections)
      })
    var seen = Set<String>()
    return TranscriptProjection.items(input).filter { seen.insert($0.id).inserted }
  }

  /// New items keep the reader's anchor (or the end, while following) in the same pass.
  private func apply(_ next: [TranscriptItem]) {
    guard next != items else { return }
    let old = items
    if let spacer = memory.spacerPrompt, !next.contains(where: { $0.id == spacer }), old.contains(where: { $0.id == spacer }) {
      memory.spacerPrompt = next.last(where: \.sticky)?.id
      geometry.spacerPrompt = memory.spacerPrompt
    }
    let anchor = revealed ? stableAnchor().flatMap { geometry.continued($0, from: old.map(\.identity), to: next.map(\.identity)) } : nil
    let previous = Dictionary(old.indices.filter { measured.indices.contains($0) && measured[$0] }.map {
      (old[$0].id, geometry.entries[$0].height)
    }, uniquingKeysWith: { first, _ in first })
    items = next
    let starts = MacTranscriptContext.responseStarts(next)
    if starts != context.responseStarts {
      let changed = starts.symmetricDifference(context.responseStarts)
      context.responseStarts = starts
      // Native prose draws its icon itself; hosted items read the context.
      for id in changed { if let prose = cells[id] as? MacProseCell, let item = prose.item { prose.configure(item, context: context) } }
    }
    replaceGeometry(previous: previous)
    let ids = Set(next.map(\.id))
    for (id, cell) in cells where !ids.contains(id) { recycle(id, cell) }
    if isViewLoaded {
      tile(anchor: anchor)
      if follow.keepsLatest { setOffset(latestOffset) }
    }
    guard revealed else {
      positionInitially()
      return
    }
    publishState()
  }

  private func replaceGeometry(previous: [String: Double] = [:]) {
    var flags: [Bool] = []
    let entries = items.map { item in
      let known = memory.heights.height(item, width: width).map(Double.init)
      flags.append(known != nil)
      let height = known ?? previous[item.id] ?? memory.heights.last(item.id, width: width).map(Double.init)
        ?? Double(estimate(item))
      return TranscriptGeometry.Entry(id: item.id, gap: Double(item.gap), height: height, sticky: item.sticky)
    }
    geometry.replace(entries)
    measured = flags
    owners = TranscriptGeometry.owners(items.map(\.identity))
  }

  private func relayout() {
    replaceGeometry()
    for cell in cells.values { cell.invalidate() }
  }

  /// Heights before measurement; only far scrolling and the scroller ever see them.
  private func estimate(_ item: TranscriptItem) -> CGFloat {
    let column = max(200, width - context.inset * 2 - MacTranscriptContext.gutter)
    func text(_ value: String) -> CGFloat {
      let perLine = max(10, column / 7.2)
      return value.split(separator: "\n", omittingEmptySubsequences: false)
        .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / perLine)) } * 20
    }
    switch item.kind {
    case .older: return 32
    case .day: return 36
    case .prompt, .pending: return 76
    case .rule: return 1
    case .prose(_, let prose): return text(prose.block.text)
    case .unparsed(let part): return text(part.source)
    case .block(_, let block, _):
      switch block.kind {
      case .code: return CGFloat(block.text.components(separatedBy: "\n").count) * 17 + 44
      case .table: return CGFloat(block.table?.rows.count ?? 1) * 30 + 40
      case .image: return 220
      case .formula: return CGFloat(block.runs.first?.formula?.metrics?.height ?? 40) + 13
      default: return 60
      }
    case .activity, .shell: return 40
    case .notice, .failure, .footer: return 20
    case .permission, .question: return 140
    }
  }

  func messageTop(_ index: Int) -> CGFloat { CGFloat(geometry.messageTop(index, owners: owners)) }

  // MARK: Tiling

  private var visibleTop: CGFloat { scrollView.contentView.bounds.minY }
  private var viewport: CGFloat { scrollView.contentView.bounds.height }

  /// The reader's place for the next change: the first measured item under the reading line, so rows measured
  /// while scrolling into history keep what was already on screen still.
  private func stableAnchor() -> TranscriptGeometry.Anchor? {
    geometry.stableAnchor(visibleTop: Double(visibleTop), viewport: Double(viewport), measured: measured, control: "older")
  }

  private func restore(_ anchor: TranscriptGeometry.Anchor) {
    guard let top = geometry.visibleTop(for: anchor) else { return }
    setOffset(CGFloat(top))
  }

  /// Materializes, measures and places the items around the viewport; heights measured above the reader's
  /// place move the offset with them, so nothing on screen moves.
  func tile(anchor explicit: TranscriptGeometry.Anchor? = nil) {
    guard isViewLoaded, width > 0, !tiling else { return }
    tiling = true
    defer { tiling = false }
    var anchor = explicit ?? (revealed ? stableAnchor() : nil)
    if let explicit { restore(explicit) }
    for _ in 0..<4 {
      var changed = false
      let top = visibleTop - viewport
      let bottom = visibleTop + viewport * 2
      var indices: [Int] = []
      var index = geometry.firstIndex(below: Double(max(0, top)))
      while index < items.count, geometry.tops[index] < Double(bottom) {
        indices.append(index)
        index += 1
      }
      if let pinned = geometry.pinned(visibleTop: Double(visibleTop)), !indices.contains(pinned.index) {
        indices.append(pinned.index)
      }
      for index in indices {
        let cell = materialize(index)
        guard !measured[index] else { continue }
        let value = Double(cell.measure(width: width, context: context))
        measured[index] = true
        memory.heights.store(CGFloat(value), for: items[index], width: width)
        if abs(geometry.entries[index].height - value) > 0.25 {
          geometry.setHeight(value, at: index)
          changed = true
        }
      }
      updateDocumentSize()
      guard changed else { break }
      if follow.keepsLatest && revealed {
        setOffset(latestOffset)
      } else if let current = anchor {
        restore(current)
        anchor = current
      }
    }
    place()
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics"), !ProcessInfo.processInfo.arguments.contains("-OpenCodeMacScrollReport") {
      macTrace(String(format: "tile items=%d cells=%d top=%.1f viewport=%.1f content=%.1f doc=%.1f following=%@",
        items.count, cells.count, visibleTop, viewport, geometry.contentEnd, document.frame.height, String(following)))
      for (id, cell) in cells {
        guard let index = geometry.index(of: id) else { continue }
        macTrace(String(format: "  cell %@ top=%.1f h=%.1f measured=%@ frame=%@", id, geometry.tops[index],
          geometry.entries[index].height, String(measured[index]), NSStringFromRect(cell.frame)))
      }
    }
    tiled()
    #endif
  }

  private func materialize(_ index: Int) -> MacTranscriptCell {
    let item = items[index]
    if let cell = cells[item.id] {
      if cell.item != item {
        cell.configure(item, context: context)
        measured[index] = false
      } else if !cell.valid {
        measured[index] = false
      }
      return cell
    }
    let cell: MacTranscriptCell
    if item.native {
      cell = spareProse.popLast() ?? MacProseCell()
    } else {
      let host = spareHosts.popLast() ?? MacHostCell()
      host.resized = { [weak self] id in self?.cellResized(id) }
      cell = host
    }
    cell.configure(item, context: context)
    cells[item.id] = cell
    document.addSubview(cell)
    if !cell.valid { measured[index] = false }
    return cell
  }

  private func recycle(_ id: String, _ cell: MacTranscriptCell) {
    cells[id] = nil
    cell.removeFromSuperview()
    if let host = cell as? MacHostCell, spareHosts.count < 24 {
      spareHosts.append(host)
    } else if let prose = cell as? MacProseCell, spareProse.count < 24 {
      prose.reset()
      spareProse.append(prose)
    }
  }

  /// A hosted item's SwiftUI content changed size by itself (an expansion, an image that loaded).
  private func cellResized(_ id: String) {
    guard let index = geometry.index(of: id) else { return }
    measured[index] = false
    // A report from inside a tiling pass (SwiftUI laying the cell out) is measured on the next turn.
    if tiling {
      DispatchQueue.main.async { [weak self] in self?.tile() }
      return
    }
    tile()
    publishState()
  }

  private func place() {
    let top = visibleTop - viewport
    let bottom = visibleTop + viewport * 2
    let pinned = geometry.pinned(visibleTop: Double(visibleTop))
    context.pinned = pinned.map { items[$0.index].id }
    for (id, cell) in cells {
      guard let index = geometry.index(of: id) else {
        recycle(id, cell)
        continue
      }
      let frame = geometry.frame(index)
      let isPinned = pinned?.index == index
      if !isPinned && (frame.bottom < Double(top) || frame.top > Double(bottom)) {
        recycle(id, cell)
        continue
      }
      let y = isPinned ? CGFloat(pinned!.y) : CGFloat(frame.top)
      let rect = CGRect(x: 0, y: y, width: width, height: CGFloat(geometry.entries[index].height))
      if cell.frame != rect { cell.frame = rect }
      cell.setPinned(isPinned && CGFloat(pinned!.y) > CGFloat(frame.top) + 0.5)
      cell.layer?.zPosition = isPinned ? 20 : items[index].sticky ? 10 : 0
    }
    // The pinned prompt draws above the content passing under it.
    if let pinned, let cell = cells[items[pinned.index].id], document.subviews.last !== cell {
      document.addSubview(cell, positioned: .above, relativeTo: nil)
    }
  }

  private func updateDocumentSize() {
    let content = max(CGFloat(geometry.contentHeight(viewport: Double(viewport))), contentFloor, viewport)
    let size = CGSize(width: width, height: ceil(content))
    if document.frame.size != size { document.setFrameSize(size) }
  }

  // MARK: Opening

  /// Shows the transcript only once it is laid out at its opening place: the first frame is the final one.
  private func positionInitially() {
    guard !revealed, isViewLoaded, width > 0, height > 0 else { return }
    guard store.hasTranscript else {
      if store.error != nil { show() }
      return
    }
    armRevealDeadline()
    guard !rebuildScheduled, items.isEmpty == store.activity.messages.isEmpty else { return }
    guard !items.isEmpty else { return show() }
    let position = target ?? ReadingPosition(.followTail)
    let resolved = resolve(position)
    if resolved == nil, case .message = position.target {
      if store.hasOlder && restorePages < 5 {
        pageForRestoration()
        return
      }
      state.resumeOffered = store.hasOlder
    }
    if case .followTail = position.target { follow.opened(atEnd: true) }
    for _ in 0..<4 {
      let offset = clamp(resolve(position) ?? latestOffset)
      setOffset(offset)
      tile()
      if parseNear(visibleTop) { rebuild() }
      let settled = clamp(resolve(position) ?? latestOffset)
      if abs(settled - visibleTop) <= 0.5 { break }
    }
    if following { setOffset(latestOffset) }
    requestVisibleParses()
    show()
  }

  private var revealDeadline: Task<Void, Never>?
  private func armRevealDeadline() {
    guard revealDeadline == nil else { return }
    revealDeadline = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard let self, !revealed else { return }
      if !items.isEmpty {
        let position = target ?? ReadingPosition(.followTail)
        if case .message = position.target, resolve(position) == nil { state.resumeOffered = true }
        setOffset(resolve(position) ?? latestOffset)
        tile()
        setOffset(resolve(position) ?? latestOffset)
      }
      show()
    }
  }

  private func show() {
    revealed = true
    target = nil
    revealDeadline?.cancel()
    revealDeadline = nil
    scrollView.alphaValue = 1
    contentFloor = visibleTop + viewport
    state.restoring = false
    memory.anchor = currentPosition()
    tile()
    publishState()
    #if DEBUG
    if ScrollFixtures.mode != nil { MacScrollDriver.start(self) }
    #endif
  }

  private func resolve(_ position: ReadingPosition) -> CGFloat? {
    guard case .message(let id, let offset) = position.target else { return nil }
    if let item = position.item, let itemOffset = position.itemOffset, let index = geometry.index(of: item) {
      return visibleTop(line: CGFloat(geometry.tops[index] + itemOffset), viewportTop: position.viewportTop)
    }
    let owner = store.activity.anchors[id] ?? id
    guard let index = items.firstIndex(where: { $0.message == owner }) else { return nil }
    return visibleTop(line: messageTop(index) + CGFloat(offset), viewportTop: position.viewportTop)
  }

  private func visibleTop(line: CGFloat, viewportTop: Double?) -> CGFloat {
    if let viewportTop { return line - CGFloat(viewportTop) }
    var top = line
    for _ in 0..<3 { top = line - CGFloat(geometry.usableTop(visibleTop: Double(top))) }
    return top
  }

  /// Parses now, without highlighting, the text near `top` that has no parse yet. True when anything parsed.
  private func parseNear(_ top: CGFloat) -> Bool {
    var index = geometry.firstIndex(below: Double(top - viewport))
    var parsed = false
    while index < items.count, geometry.tops[index] < Double(top + viewport * 2) {
      if case .unparsed(let part) = items[index].kind, parses.parseNow(part) { parsed = true }
      index += 1
    }
    return parsed
  }

  private func pageForRestoration() {
    guard paging == nil else { return }
    paging = Task { [weak self] in
      guard let self else { return }
      let count = store.messages.count
      await store.older()
      restorePages += 1
      paging = nil
      if store.messages.count == count && store.error != nil { state.resumeOffered = true; restorePages = 5 }
      rebuild()
      positionInitially()
    }
  }

  private func requestVisibleParses() {
    guard isViewLoaded, !items.isEmpty else { return }
    var index = geometry.firstIndex(below: Double(visibleTop - viewport * 2))
    while index < items.count, geometry.tops[index] < Double(visibleTop + viewport * 3) {
      if case .unparsed(let part) = items[index].kind { parses.request(part) }
      index += 1
    }
  }

  // MARK: Navigation

  /// The end at the bottom edge, or a just-sent prompt at the top while its answer is shorter than the viewport.
  var latestOffset: CGFloat {
    CGFloat(geometry.latestOffset(viewport: Double(viewport), maximum: Double(maximumOffset)))
  }

  private var maximumOffset: CGFloat {
    max(0, max(CGFloat(geometry.contentHeight(viewport: Double(viewport))), contentFloor) - viewport)
  }

  var distanceToLatest: CGFloat { latestOffset - visibleTop }

  func scrollToLatest(animated: Bool) {
    guard revealed else { return }
    follow.navigated(toLatest: true)
    scroll(to: { [unowned self] in latestOffset }, animated: animated)
  }

  /// Explicit navigation to a message (search, quotes): pages history until it is loaded.
  func reveal(messageID: String, offset: Double = 0, animated: Bool = false, persist: Bool = false) {
    let owner = store.activity.anchors[messageID] ?? messageID
    guard items.contains(where: { $0.message == owner }) else {
      page(until: { [weak self] in self?.items.contains { $0.message == owner } ?? true }) { [weak self] in
        guard let self, items.contains(where: { $0.message == owner }) else { return }
        reveal(messageID: messageID, offset: offset, animated: animated, persist: persist)
      }
      return
    }
    follow.navigated(toLatest: false)
    scroll(to: { [unowned self] in
      let index = items.firstIndex { $0.message == owner } ?? 0
      return visibleTop(line: messageTop(index) + CGFloat(offset), viewportTop: nil)
    }, animated: animated)
    if persist { capture() }
  }

  /// A pinned prompt's click: its turn's first row moves just below it. False when the prompt is not pinned.
  func revealQuote(_ quote: ChatQuote) async -> Bool {
    for page in 0...5 {
      guard !Task.isCancelled else { return false }
      if store.messages.contains(where: { $0.id == quote.messageID }) { break }
      guard page < 5, store.hasOlder else {
        store.toast.show(store.hasOlder ? "Trecho ainda não carregado. Toque novamente para buscar mais mensagens." : "O trecho citado não está disponível.", kind: .error)
        return false
      }
      await store.older()
    }
    guard let message = store.messages.first(where: { $0.id == quote.messageID }),
      let entry = (message.content ?? []).enumerated().first(where: { message.partID(at: $0.offset) == quote.partID }),
      let source = entry.element.text else {
      store.toast.show("O trecho citado não está disponível.", kind: .error)
      return false
    }
    let blocks = await ResponseMarkdownCache.shared.parse(source)
    guard !Task.isCancelled else { return false }
    let ranges = ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: blocks)
    guard !ranges.isEmpty else {
      store.toast.show("O trecho citado mudou e não pôde ser localizado.", kind: .error)
      return false
    }
    context.quotes.revealing = context.quotes.index.marks(messageID: quote.messageID, partID: quote.partID)
      .first { $0.quote.id == quote.id }?.id ?? ChatQuoteMark(quote: quote, number: 1).id
    rebuild()
    let index = items.firstIndex { item in
      guard item.part?.partID == quote.partID else { return false }
      switch item.kind {
      case .prose(_, let prose): return ranges.contains { !ConversationSearch.renderedRanges($0, block: prose.block).isEmpty }
      case .block(_, let block, _): return ranges.contains { !ConversationSearch.renderedRanges($0, block: block).isEmpty }
      default: return false
      }
    }
    guard let index else {
      reveal(messageID: quote.messageID, animated: true)
      return true
    }
    let cell = materialize(index)
    cell.configure(items[index], context: context)
    geometry.setHeight(Double(cell.measure(width: width, context: context)), at: index)
    measured[index] = true
    follow.navigated(toLatest: false)
    let id = items[index].id
    scroll(to: { [unowned self] in
      guard let index = geometry.index(of: id) else { return visibleTop }
      let offset = cells[id]?.quoteTop(quote.id) ?? 0
      return visibleTop(line: CGFloat(geometry.tops[index]) + offset, viewportTop: nil)
    }, animated: true)
    return true
  }

  func revealTurn(_ prompt: String) -> Bool {
    guard let pinned = geometry.pinned(visibleTop: Double(visibleTop)), items[pinned.index].id == "prompt:" + prompt,
      pinned.index + 1 < items.count else { return false }
    let id = items[pinned.index].id
    let first = items[pinned.index + 1].message
    follow.navigated(toLatest: false)
    scroll(to: { [unowned self] in
      guard let prompt = geometry.index(of: id) else { return visibleTop }
      let start = items.indices.dropFirst(prompt + 1).first { first == nil || items[$0].message == first } ?? prompt + 1
      return messageTop(min(start, items.count - 1)) - CGFloat(geometry.entries[prompt].height)
    }, animated: true)
    return true
  }

  /// After a send the view stays at the end, like a chat: the new prompt appears at the bottom and the answer
  /// follows it. Unlike the iPhone, the prompt does not rise to the top, so there is no trailing space and no
  /// long animated scroll.
  private func revealSentPrompt() {
    guard let since = awaitingPrompt, revealed else { return }
    guard since.duration(to: .now) < .seconds(10) else { awaitingPrompt = nil; return }
    guard let last = items.lastIndex(where: \.sticky),
      store.pendingInbox.contains(where: { "prompt:" + $0.id == items[last].id })
        || store.messages.last(where: { $0.type == "user" }).map({ "prompt:" + $0.id == items[last].id }) == true
    else { return }
    awaitingPrompt = nil
    scrollToLatest(animated: false)
  }

  /// The destination is laid out first, in this pass, until its rows are measured and it stops moving; a
  /// distant one is then approached from one viewport away, so the animation crosses only measured rows.
  private func scroll(to target: @escaping () -> CGFloat, animated: Bool) {
    let origin = visibleTop
    var destination = clamp(target())
    for _ in 0..<4 {
      setOffset(destination)
      tile()
      if parseNear(visibleTop) { rebuild() }
      destination = clamp(target())
      if abs(destination - visibleTop) <= 0.5 { break }
    }
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard animated, !reduce, abs(origin - destination) > 1 else {
      setOffset(destination)
      tile()
      scheduleCapture()
      return
    }
    let start = destination + min(viewport, max(-viewport, origin - destination))
    setOffset(start)
    tile()
    destination = clamp(target())
    animating = target
    NSAnimationContext.runAnimationGroup { animation in
      animation.duration = 0.3
      animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: destination))
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let target = self.animating else { return }
        self.animating = nil
        let final = self.clamp(target())
        if abs(final - self.visibleTop) > 0.5 { self.setOffset(final) }
        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        self.tile()
        self.scheduleCapture()
      }
    }
  }

  private func clamp(_ offset: CGFloat) -> CGFloat { min(max(0, offset), maximumOffset) }

  private func setOffset(_ offset: CGFloat) {
    updateDocumentSize()
    let value = min(max(0, offset), maximumOffset)
    guard abs(value - visibleTop) > 0.01 else { return }
    scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: value))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func page(until found: @escaping () -> Bool, then: @escaping () -> Void) {
    guard paging == nil else { return }
    paging = Task { [weak self] in
      guard let self else { return }
      var pages = 0
      while !found(), store.hasOlder, pages < 20, !Task.isCancelled {
        let count = store.messages.count
        await store.older()
        pages += 1
        if store.messages.count == count { break }
        rebuild()
      }
      paging = nil
      rebuild()
      then()
    }
  }

  /// Continues paging toward a saved place older than the first five pages.
  func resume() {
    guard let position = memory.anchor ?? reading.position(store.id), case .message(let id, _) = position.target
    else { return }
    state.resumeOffered = false
    page(until: { [weak self] in self?.items.contains { $0.message == id } ?? true }) { [weak self] in
      guard let self, resolve(position) != nil else { return }
      follow.navigated(toLatest: false)
      scroll(to: { [unowned self] in resolve(position) ?? visibleTop }, animated: false)
    }
  }

  private func loadOlder() {
    guard revealed, store.hasOlder, !store.paging, paging == nil else { return }
    Task { await store.older() }
  }

  // MARK: Reading position

  func currentPosition() -> ReadingPosition? {
    guard !items.isEmpty else { return nil }
    let usable = CGFloat(geometry.usableTop(visibleTop: Double(visibleTop)))
    let line = visibleTop + usable
    var index = geometry.firstIndex(below: Double(line))
    if index == geometry.pinned(visibleTop: Double(visibleTop))?.index { index += 1 }
    index = min(index, items.count - 1)
    guard let owner = (0...index).reversed().first(where: { items[$0].message != nil }),
      let message = items[owner].message else { return nil }
    return ReadingPosition(
      .message(id: message, offset: Double(line - messageTop(owner))), viewportTop: Double(usable),
      item: items[index].id, itemOffset: Double(line) - geometry.tops[index])
  }

  /// Keeps the exact passage in memory and saves it (the end as `followTail`).
  func capture() {
    guard revealed, let position = currentPosition() else { return }
    memory.anchor = position
    guard canPersist() else { return }
    reading.set(distanceToLatest <= 1 ? ReadingPosition(.followTail) : position, sessionID: store.id)
    do { try reading.flush() } catch {
      store.toast.show("Não foi possível guardar a posição de leitura.", kind: .error)
    }
  }

  private func scheduleCapture() {
    captureTask?.cancel()
    captureTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      self?.capture()
    }
  }

  // MARK: Scrolling

  @objc private func boundsChanged() {
    guard revealed else { return }
    if !interacting { contentFloor = max(contentFloor, visibleTop + viewport) }
    tile()
    publishState()
    requestVisibleParses()
    if visibleTop < viewport * 1.5 { loadOlder() }
  }

  @objc private func liveScrollStarted() { began() }
  @objc private func liveScrollEnded() { settle() }

  /// A wheel or trackpad event: the reader owns the offset until it settles.
  private func userScrolled(_ event: NSEvent) {
    guard event.scrollingDeltaY != 0 || event.phase == .began || event.momentumPhase == .began else { return }
    began()
    // A plain mouse wheel sends no live-scroll notifications: settle once its clicks stop.
    interactionEnd?.cancel()
    interactionEnd = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      self?.settle()
    }
  }

  private func began() {
    animating = nil
    if !interacting {
      contentFloor = 0
      store.scrolling = true
    }
    follow.began()
  }

  private func settle() {
    guard interacting else { return }
    store.scrolling = false
    contentFloor = visibleTop + viewport
    // Scrolling back to the end follows it again.
    follow.settled(distance: Double(distanceToLatest))
    publishState()
    scheduleCapture()
  }

  /// Page Up/Down, space and Shift-space, ⌘↑/⌘↓, Home/End and the arrows, from the transcript or a text in it.
  func scrollKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let plain = flags.isDisjoint(with: [.command, .option, .control, .shift])
    let key: TranscriptScrollKey? = switch event.keyCode {
    case 116: .pageUp
    case 121: .pageDown
    case 49 where flags.isEmpty: .pageDown
    case 49 where flags == .shift: .pageUp
    case 115: .top
    case 119: .latest
    case 126 where flags.contains(.command): .top
    case 125 where flags.contains(.command): .latest
    case 126 where plain: .lineUp
    case 125 where plain: .lineDown
    default: nil
    }
    guard let key else { return false }
    let target = CGFloat(key.target(visibleTop: Double(visibleTop), viewport: Double(viewport),
      latest: Double(latestOffset)))
    if key == .latest || target >= latestOffset - 0.5 {
      scrollToLatest(animated: true)
      return true
    }
    follow.navigated(toLatest: false)
    scroll(to: { target }, animated: abs(target - visibleTop) > 50)
    if target <= 0 { loadOlder() }
    return true
  }

  private func publishState() {
    guard isViewLoaded, revealed else { return }
    let jump = distanceToLatest > 24
    if state.jumpToLatest != jump { state.jumpToLatest = jump }
    let sticky = CGFloat(geometry.usableTop(visibleTop: Double(visibleTop)))
    if state.stickyHeight != sticky { state.stickyHeight = sticky }
  }

  /// Gives the transcript the keyboard (Page Up/Down, space) without a click in it.
  func focus() {
    view.window?.makeFirstResponder(document)
  }

  #if DEBUG
  var scrollViewForDriver: NSScrollView { scrollView }
  /// The driver's virtual trackpad: it owns the offset like the reader's own scrolling.
  func simulateScroll(by delta: CGFloat) {
    began()
    let target = min(max(0, visibleTop + delta), maximumOffset)
    lastSimulatedDelta = target - visibleTop
    scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
  func simulateRest() {
    lastSimulatedDelta = 0
    settle()
  }
  private(set) var lastSimulatedDelta: CGFloat = 0
  /// Items on screen and where, for the frame driver.
  var visibleRows: [String: CGRect] {
    let pinned = geometry.pinned(visibleTop: Double(visibleTop))?.index
    var rows: [String: CGRect] = [:]
    for (id, cell) in cells {
      guard let index = geometry.index(of: id), index != pinned else { continue }
      let frame = cell.frame.offsetBy(dx: 0, dy: -visibleTop)
      if frame.maxY > 0 && frame.minY < viewport { rows[id] = frame }
    }
    return rows
  }
  #endif
}

extension TranscriptItem {
  /// The item as the shared reading rules (`TranscriptGeometry.continued`, `owners`) see it.
  var identity: TranscriptItemIdentity {
    TranscriptItemIdentity(id: id, partID: part?.partID, message: message, sticky: sticky)
  }
}

/// The flipped document: the transcript's coordinates grow downward, like the geometry's.
final class MacTranscriptDocument: NSView {
  var keyHandler: ((NSEvent) -> Bool)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if keyHandler?(event) == true { return }
    super.keyDown(with: event)
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }
}

final class MacTranscriptScrollView: NSScrollView {
  var userScrolled: ((NSEvent) -> Void)?
  override func scrollWheel(with event: NSEvent) {
    userScrolled?(event)
    super.scrollWheel(with: event)
  }
}

#if DEBUG
/// Diagnostics on standard error (`-OpenCodeScrollDiagnostics`): `NSLog` from a GUI app goes to the unified log only.
func macTrace(_ text: String) {
  fputs("MACTRANSCRIPT " + text + "\n", stderr)
}
#endif
