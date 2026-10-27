import Observation
import OpenCodeKit
import SwiftUI

/// What the conversation's SwiftUI chrome shows about the transcript.
@MainActor @Observable final class TranscriptState {
  /// Content continues below the viewport: ↓ **Ir para a mais recente**.
  var jumpToLatest = false
  /// Points the pinned prompt covers at the top.
  var stickyHeight: CGFloat = 0
  /// The transcript is not on screen yet: its first frame waits for the final position.
  var restoring = true
  /// The saved place is older than the history this opening reads: offer to keep paging.
  var resumeOffered = false
}

/// The conversation transcript: a non-inverted collection view whose layout keeps the reader's place in the
/// same pass as any change. It is retained with its conversation, so returning to it shows the very view that
/// was left. Growth never scrolls it: only sending a prompt, explicit navigation, ↓ and opening move it.
@MainActor final class TranscriptViewController: UIViewController, UICollectionViewDataSource,
  UICollectionViewDelegate, TranscriptLayoutDelegate
{
  let store: ConversationStore
  let context: TranscriptContext
  private let reading: ReadingPositionStore
  private var memory: TranscriptMemory { store.memory }
  private var state: TranscriptState { store.memory.state }
  private let layout = TranscriptLayout()
  private(set) var collectionView: UICollectionView!
  private(set) var items: [TranscriptItem] = []
  private let parses = TranscriptParses()
  private var rebuildScheduled = false
  private(set) var revealed = false
  /// The place to show before the first frame; nil once shown.
  private var target: ReadingPosition?
  private var restorePages = 0
  private var paging: Task<Void, Never>?
  private var captureTask: Task<Void, Never>?
  private var submitted: Int
  /// A prompt was just sent: the next new prompt rises to the top.
  private var awaitingPrompt: ContinuousClock.Instant?
  private var size = CGSize.zero
  private var category = UIContentSizeCategory.large
  private var bottomPadding: CGFloat = 12
  private(set) var mounted = false
  var canPersist: () -> Bool = { true }
  #if DEBUG
  /// The offline driver's virtual finger: programmatic offsets never report tracking.
  var simulatedTouch = false
  #endif

  init(store: ConversationStore, reading: ReadingPositionStore) {
    self.store = store
    self.reading = reading
    context = TranscriptContext(store: store)
    submitted = store.submitted
    // In this process, the exact passage last shown; otherwise the saved place (the end by default).
    target = store.memory.anchor ?? reading.position(store.id) ?? ReadingPosition(.followTail)
    super.init(nibName: nil, bundle: nil)
    layout.delegate = self
    layout.setSpacerPrompt(store.memory.spacerPrompt)
    parses.landed = { [weak self] in self?.scheduleRebuild() }
    parses.rasterized = { [weak self] in self?.context.rasterRevision += 1 }
    context.blockLookup = { [weak self] in self?.parses.blocks($0) }
    context.rasterLookup = { [weak self] in self?.parses.rasters($0) ?? [:] }
    context.loadOlder = { [weak self] in self?.loadOlder() }
    context.promptJump = UserPromptJump { [weak self] in self?.revealTurn($0) ?? false }
  }
  required init?(coder: NSCoder) { nil }

  private var touching: Bool {
    #if DEBUG
    if simulatedTouch { return true }
    #endif
    return collectionView.isTracking || collectionView.isDecelerating
  }

  // MARK: View

  override func loadView() {
    let container = UIView()
    let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collection.dataSource = self
    collection.delegate = self
    collection.register(TranscriptTextCell.self, forCellWithReuseIdentifier: "text")
    collection.register(TranscriptHostCell.self, forCellWithReuseIdentifier: "host")
    collection.contentInsetAdjustmentBehavior = .never
    collection.keyboardDismissMode = .interactive
    collection.alwaysBounceVertical = true
    collection.backgroundColor = .clear
    collection.accessibilityIdentifier = "conversation-transcript"
    collection.accessibilityValue = "Restaurando leitura"
    collection.isHidden = true
    collection.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(collection)
    NSLayoutConstraint.activate([
      collection.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      collection.topAnchor.constraint(equalTo: container.topAnchor),
      collection.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    collectionView = collection
    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observeContext()
    rebuild()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      NSLog("TRANSCRIPT %@ parent=%@", String(describing: ObjectIdentifier(self)), String(describing: parent))
    }
    #endif
    if parent != nil { mount() } else { unmount() }
  }

  /// Mounted by a conversation screen; also reported by the host, which may dismantle before UIKit reparents.
  func mount() {
    mounted = true
    memory.mount(self)
    #if DEBUG
    if ScrollFixtures.mode != nil {
      TranscriptTrajectory.shared.geometry = self
      ScrollFixtures.driving = self
    }
    #endif
  }

  func unmount() {
    mounted = false
    memory.unmount(self)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bounds = collectionView.bounds.size
    let text = traitCollection.preferredContentSizeCategory
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics"), bounds != size {
      NSLog("TRANSCRIPT layout %@ -> %@ offset=%.2f revealed=%@", NSCoder.string(for: size),
        NSCoder.string(for: bounds), collectionView.contentOffset.y, String(revealed))
    }
    #endif
    if bounds.width != size.width || text != category {
      // Every height depends on width and text size; keep the reader's place through the change.
      let anchor = revealed ? layout.anchor : nil
      size = bounds
      category = text
      relayout(anchor)
    } else if bounds.height != size.height {
      // The keyboard or composer resized the viewport: the end stays at the end, anything else stays put.
      let end = revealed && distanceToLatest <= 1
      let delta = size.height - bounds.height
      size = bounds
      layout.invalidateLayout()
      if end, delta != 0 {
        collectionView.layoutIfNeeded()
        setOffset(collectionView.contentOffset.y + delta)
      }
    }
    if !revealed { positionInitially() }
    publishState()
  }

  // MARK: Inputs from the conversation screen

  func update(
    theme: AppTheme, quotes: ConversationQuoteContext, search: ConversationSearchHighlight,
    selection: ResponseSelectionActions?, selectionChanged: ResponseSelectionObserver?,
    images: ConversationImageContext?, openFile: FileOpenAction?, openImage: ImageOpenAction?,
    revert: UserMessageRevertAction?, size: CGSize?, bottomPadding: CGFloat
  ) {
    if context.theme.id != theme.id {
      context.theme = theme
      parses.theme = theme
      parses.restyle(items.compactMap(\.part))
    }
    if context.quotes != quotes { context.quotes = quotes }
    if context.search != search { context.search = search }
    context.selection = selection
    context.selectionChanged = selectionChanged
    if context.images != images { context.images = images }
    context.openFile = openFile
    context.openImage = openImage
    if context.revert != revert { context.revert = revert }
    if let size, context.size != size { context.size = size }
    parses.scale = traitCollection.displayScale
    if isViewLoaded { collectionView.backgroundColor = theme.uiColor(.background) }
    if self.bottomPadding != bottomPadding {
      self.bottomPadding = bottomPadding
      layout.setBottomPadding(bottomPadding)
      if isViewLoaded { layout.invalidateLayout() }
    }
  }

  /// Native text cells read the context when configured; reconfigure them when what they draw changes.
  private func observeContext() {
    withObservationTracking {
      _ = (context.theme.id, context.search, context.quotes, context.rasterRevision, context.images)
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.observeContext()
        self.reconfigureVisibleText()
      }
    }
  }

  private func reconfigureVisibleText() {
    guard isViewLoaded else { return }
    for path in collectionView.indexPathsForVisibleItems where items.indices.contains(path.item) {
      guard let cell = collectionView.cellForItem(at: path) as? TranscriptTextCell,
        case .prose(let part, let prose) = items[path.item].kind else { continue }
      cell.configure(part, prose: prose, context: context)
    }
  }

  // MARK: Items

  private func scheduleRebuild() {
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.rebuildScheduled = false
      self?.rebuild()
    }
  }

  private func rebuild() {
    var stale: [TranscriptPart] = []
    let next = withObservationTracking {
      projection(stale: { stale.append($0) })
    } onChange: { [weak self] in
      Task { @MainActor in self?.scheduleRebuild() }
    }
    stale.forEach(parses.request)
    let submission = store.submitted != submitted
    if submission {
      submitted = store.submitted
      awaitingPrompt = .now
    }
    apply(next)
    requestVisibleParses()
    revealSentPrompt()
  }

  private func projection(stale: @escaping (TranscriptPart) -> Void) -> [TranscriptItem] {
    let messages = store.messages
    _ = store.submitted
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
        // Unparsed parts are requested by position (`requestVisibleParses`), nearest the reader first.
        guard let parsed = parses.parsed(part) else { return nil }
        if parsed.source != part.source { stale(part) }
        return (parsed.source, parsed.sections)
      })
    var seen = Set<String>()
    return TranscriptProjection.items(input).filter { seen.insert($0.id).inserted }
  }

  /// Applies new items without animation, restoring the reader's anchor in the same layout pass. Updates are
  /// always precise inserts, deletes and reconfigurations (never a reload once loaded): a reload leaves the
  /// visible cells' self-sizing reports attached to the index paths they had before it.
  private func apply(_ next: [TranscriptItem]) {
    guard next != items else { return }
    guard isViewLoaded else {
      items = next
      let (entries, measured) = entries(next)
      layout.replace(entries, owners: owners(next), measured: measured)
      return
    }
    let old = items
    let oldIndex = Dictionary(old.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newIndex = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    let kept = old.filter { newIndex[$0.id] != nil }.map(\.id)
    let reordered = old.isEmpty || kept != next.filter { oldIndex[$0.id] != nil }.map(\.id)
    let deleted = old.indices.filter { newIndex[old[$0].id] == nil }.map { IndexPath(item: $0, section: 0) }
    let inserted = next.indices.filter { oldIndex[next[$0].id] == nil }.map { IndexPath(item: $0, section: 0) }
    let changed = next.indices.filter { index in
      oldIndex[next[index].id].map { old[$0].kind != next[index].kind } ?? false
    }.map { IndexPath(item: $0, section: 0) }
    let anchor = revealed ? layout.anchor.flatMap { continued($0, from: old, to: next) } : nil
    let previous = Dictionary(old.indices.filter(layout.isMeasured).map {
      (old[$0].id, CGFloat(layout.geometry.entries[$0].height))
    }, uniquingKeysWith: { first, _ in first })
    layout.pendingAnchor = anchor
    UIView.performWithoutAnimation {
      let (entries, measured) = entries(next, previous: previous)
      if reordered {
        items = next
        layout.replace(entries, owners: owners(next), measured: measured)
        collectionView.reloadData()
      } else {
        collectionView.performBatchUpdates {
          items = next
          layout.replace(entries, owners: owners(next), measured: measured)
          collectionView.deleteItems(at: deleted)
          collectionView.insertItems(at: inserted)
        }
        if !changed.isEmpty { collectionView.reconfigureItems(at: changed) }
      }
      if let anchor, let offset = layout.offset(for: anchor) { setOffset(offset) }
      collectionView.layoutIfNeeded()
    }
    layout.pendingAnchor = nil
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      NSLog("TRANSCRIPT apply %d -> %d deleted=%d inserted=%d changed=%d reordered=%@ revealed=%@", old.count,
        next.count, deleted.count, inserted.count, changed.count, String(reordered), String(revealed))
    }
    #endif
    guard revealed else {
      positionInitially()
      return
    }
    collectionView.accessibilityValue = "\(store.messages.count) mensagens carregadas"
    publishState()
  }

  /// The anchor to restore after an update. When its item is replaced (a placeholder by the blocks its parse
  /// produced, a block split by a newer parse), the reader's place continues in what replaced it: the part's
  /// first new item, then the message's, then the next item that survived, each at the same screen position.
  private func continued(
    _ anchor: TranscriptGeometry.Anchor, from old: [TranscriptItem], to next: [TranscriptItem]
  ) -> TranscriptGeometry.Anchor? {
    if next.contains(where: { $0.id == anchor.id }) { return anchor }
    guard let index = old.firstIndex(where: { $0.id == anchor.id }) else { return nil }
    let item = old[index]
    if let part = item.part, let replacement = next.first(where: { $0.part?.partID == part.partID }) {
      return .init(id: replacement.id, screenY: anchor.screenY)
    }
    if let message = item.message, let replacement = next.first(where: { $0.message == message }) {
      return .init(id: replacement.id, screenY: anchor.screenY)
    }
    let survivors = Set(next.map(\.id))
    let geometry = layout.geometry
    guard let following = old.indices.dropFirst(index + 1).first(where: { survivors.contains(old[$0].id) })
    else { return nil }
    return .init(id: old[following].id,
      screenY: anchor.screenY + CGFloat(geometry.tops[following] - geometry.tops[index]))
  }

  /// Heights for the items: measured for this content and width, else the item's last measured height while
  /// its content changes (until its cell measures again), else an estimate.
  private func entries(
    _ items: [TranscriptItem], previous: [String: CGFloat] = [:]
  ) -> ([TranscriptGeometry.Entry], [Bool]) {
    var measured: [Bool] = []
    let entries = items.map { item in
      let known = memory.heights.height(item, width: size.width, category: category) ?? previous[item.id]
      measured.append(known != nil)
      return TranscriptGeometry.Entry(
        id: item.id, gap: Double(item.gap), height: Double(known ?? estimate(item)), sticky: item.sticky)
    }
    return (entries, measured)
  }

  private func owners(_ items: [TranscriptItem]) -> [TranscriptLayout.Owner] {
    var result: [TranscriptLayout.Owner] = []
    var start = 0
    for (index, item) in items.enumerated() {
      if index == 0 || item.message == nil || item.message != items[index - 1].message {
        start = index
      }
      let inset: CGFloat = items[start].sticky || items[start].message == nil ? 0 : 10
      result.append(.init(start: start, inset: inset))
    }
    return result
  }

  /// Heights before measurement. Only scrolling far and the scroll indicator ever see them: the reader's
  /// place is kept by anchoring, whatever the estimate.
  private func estimate(_ item: TranscriptItem) -> CGFloat {
    let width = max(100, size.width - AppLayout.margin * 2)
    func text(_ value: String) -> CGFloat {
      let perLine = max(10, width / 8.5)
      let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / perLine)) }
      return lines * 24
    }
    switch item.kind {
    case .older: return 32
    case .day: return 40
    case .prompt, .pending: return 92
    case .rule: return 1
    case .prose(_, let prose): return text(prose.block.text)
    case .unparsed(let part): return text(part.source)
    case .block(_, let block, _):
      switch block.kind {
      case .code: return CGFloat(block.text.components(separatedBy: "\n").count) * 20 + 60
      case .table: return CGFloat(block.table?.rows.count ?? 1) * 44 + 50
      case .image: return 220
      case .formula: return CGFloat(block.runs.first?.formula?.metrics?.height ?? 40) + 13
      default: return 60
      }
    case .activity, .shell: return 28
    case .notice, .failure, .footer: return 22
    case .permission, .question: return 160
    }
  }

  private func relayout(_ anchor: TranscriptGeometry.Anchor?) {
    let (entries, measured) = entries(items)
    layout.replace(entries, owners: owners(items), measured: measured)
    layout.invalidateLayout()
    guard let anchor else { return }
    collectionView.layoutIfNeeded()
    if let offset = layout.offset(for: anchor) { setOffset(offset) }
  }

  func layout(_ layout: TranscriptLayout, measured height: CGFloat, at index: Int) {
    guard items.indices.contains(index) else { return }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics"), revealed {
      NSLog("TRANSCRIPT measured %@ %.1f -> %.1f window=%@ offset=%.1f", items[index].id,
        memory.heights.height(items[index], width: size.width, category: category) ?? -1, height,
        String(collectionView.window != nil), collectionView.contentOffset.y)
    }
    #endif
    memory.heights.store(height, for: items[index], width: size.width, category: category)
  }

  // MARK: Data source

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let item = items[indexPath.item]
    if case .prose(let part, let prose) = item.kind {
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "text", for: indexPath) as! TranscriptTextCell
      cell.configure(part, prose: prose, context: context)
      return cell
    }
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "host", for: indexPath) as! TranscriptHostCell
    cell.configure(item, context: context)
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      NSLog("TRANSCRIPT cell %@ %@ at %d", String(describing: ObjectIdentifier(cell)), item.id, indexPath.item)
    }
    #endif
    return cell
  }

  // MARK: Opening

  /// Resolves the opening place and shows the transcript only once it is laid out there, so its first frame
  /// is the final one. Missing history pages and unparsed Markdown near the place delay it, never move it.
  private func positionInitially() {
    // Items must reflect the published transcript; a pending rebuild positions again when it lands.
    guard !revealed, isViewLoaded, store.hasTranscript, !rebuildScheduled, size.width > 0, size.height > 0,
      items.isEmpty == store.activity.messages.isEmpty else { return }
    let position = target ?? ReadingPosition(.followTail)
    let resolved = resolve(position)
    if resolved == nil, case .message = position.target {
      if store.hasOlder && restorePages < 5 {
        pageForRestoration()
        return
      }
      // Older than this opening reads: open at the end and offer to keep going.
      state.resumeOffered = store.hasOlder
    }
    var offset = resolved ?? latestOffset
    UIView.performWithoutAnimation {
      setOffset(offset)
      for _ in 0..<4 {
        collectionView.layoutIfNeeded()
        let next = resolve(position) ?? latestOffset
        guard abs(next - offset) > 0.25 else { break }
        offset = next
        setOffset(offset)
      }
    }
    requestVisibleParses()
    // Markdown near the place must be parsed and laid out before the first frame; its parse lands
    // through a rebuild that positions again.
    if unparsedNear { return }
    revealed = true
    target = nil
    collectionView.isHidden = false
    collectionView.accessibilityValue = "\(store.messages.count) mensagens carregadas"
    state.restoring = false
    memory.anchor = currentPosition()
    publishState()
  }

  /// The content offset that shows a reading position, if its item or message is loaded.
  private func resolve(_ position: ReadingPosition) -> CGFloat? {
    guard case .message(let id, let offset) = position.target else { return nil }
    let geometry = layout.geometry
    if let item = position.item, let itemOffset = position.itemOffset, let index = geometry.index(of: item) {
      let line = CGFloat(geometry.tops[index] + itemOffset)
      return visibleTop(line: line, viewportTop: position.viewportTop)
    }
    let owner = store.activity.anchors[id] ?? id
    guard let index = items.firstIndex(where: { $0.message == owner }) else { return nil }
    return visibleTop(line: layout.messageTop(index) + CGFloat(offset), viewportTop: position.viewportTop)
  }

  /// The visible top that puts the reading line at `line`, below the prompt pinned there.
  private func visibleTop(line: CGFloat, viewportTop: Double?) -> CGFloat {
    if let viewportTop { return line - CGFloat(viewportTop) }
    var top = line
    for _ in 0..<3 { top = line - CGFloat(layout.geometry.usableTop(visibleTop: Double(top))) }
    return top
  }

  private var unparsedNear: Bool {
    let top = layout.visibleTop
    let geometry = layout.geometry
    var index = geometry.firstIndex(below: Double(top - size.height))
    while index < items.count, geometry.tops[index] < Double(top + size.height * 2) {
      if case .unparsed = items[index].kind { return true }
      index += 1
    }
    return false
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
      scheduleRebuild()
      positionInitially()
    }
  }

  /// Parses unparsed parts around the viewport (or the place being opened) first.
  private func requestVisibleParses() {
    guard isViewLoaded, !items.isEmpty else { return }
    let top = layout.visibleTop
    let geometry = layout.geometry
    var index = geometry.firstIndex(below: Double(top - size.height * 2))
    while index < items.count, geometry.tops[index] < Double(top + size.height * 3) {
      if case .unparsed(let part) = items[index].kind { parses.request(part) }
      index += 1
    }
  }

  // MARK: Navigation

  /// The offset that shows the latest content: the end at the bottom edge, or a just-sent prompt at the top
  /// while its answer is shorter than the viewport.
  var latestOffset: CGFloat {
    let geometry = layout.geometry
    var offset = CGFloat(geometry.contentEnd) - collectionView.bounds.height
    if let id = layout.geometry.spacerPrompt, let index = geometry.index(of: id) {
      offset = max(offset, CGFloat(geometry.tops[index]))
    }
    return min(max(0, offset), layout.maximumOffset)
  }

  private var distanceToLatest: CGFloat { latestOffset - collectionView.contentOffset.y }

  func scrollToLatest(animated: Bool) {
    guard revealed else { return }
    scroll(to: latestOffset, animated: animated)
  }

  /// Explicit navigation to a message (search, quotes, read aloud): pages history until it is loaded.
  func reveal(messageID: String, offset: Double = 0, animated: Bool = false, persist: Bool = false) {
    let owner = store.activity.anchors[messageID] ?? messageID
    guard let index = items.firstIndex(where: { $0.message == owner }) else {
      page(until: { [weak self] in self?.items.contains { $0.message == owner } ?? true }) { [weak self] in
        guard let self, items.contains(where: { $0.message == owner }) else { return }
        reveal(messageID: messageID, offset: offset, animated: animated, persist: persist)
      }
      return
    }
    scroll(to: visibleTop(line: layout.messageTop(index) + CGFloat(offset), viewportTop: nil), animated: animated)
    if persist { capture() }
  }

  /// Opens a tool's group and shows its message, paging history until it is loaded.
  func revealTool(_ tool: String) {
    func message() -> String? { store.messages.first { $0.tools.contains { $0.id == tool } }?.id }
    guard let id = message() else {
      page(until: { message() != nil }) { [weak self] in if message() != nil { self?.revealTool(tool) } }
      return
    }
    store.revealedToolID = tool
    DispatchQueue.main.async { [weak self] in self?.reveal(messageID: id) }
  }

  /// A pinned prompt's tap: its turn's first row moves just below it. False when the prompt is not pinned.
  func revealTurn(_ prompt: String) -> Bool {
    guard let pinned = layout.pinned, items[pinned.index].id == "prompt:" + prompt,
      pinned.index + 1 < items.count else { return false }
    let geometry = layout.geometry
    let target = CGFloat(geometry.tops[pinned.index + 1] - geometry.entries[pinned.index].height)
    if abs(target - collectionView.contentOffset.y) < 1 {
      Haptics.play(.selection)
      return true
    }
    scroll(to: target, animated: true)
    return true
  }

  /// After a send, the new prompt rises to the top of the transcript; the trailing space lets it get there.
  private func revealSentPrompt() {
    guard let since = awaitingPrompt, revealed else { return }
    guard since.duration(to: .now) < .seconds(10) else { awaitingPrompt = nil; return }
    guard let last = items.lastIndex(where: \.sticky), memory.spacerPrompt != items[last].id,
      store.pendingInbox.contains(where: { "prompt:" + $0.id == items[last].id })
        || store.messages.last(where: { $0.type == "user" }).map({ "prompt:" + $0.id == items[last].id }) == true
    else { return }
    awaitingPrompt = nil
    memory.spacerPrompt = items[last].id
    layout.setSpacerPrompt(items[last].id)
    layout.invalidateLayout()
    collectionView.layoutIfNeeded()
    scroll(to: CGFloat(layout.geometry.tops[last]), animated: true)
  }

  private func scroll(to offset: CGFloat, animated: Bool) {
    let target = min(max(0, offset), layout.maximumOffset)
    collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    scheduleCapture()
  }

  private func setOffset(_ offset: CGFloat) {
    collectionView.contentOffset = CGPoint(x: 0, y: min(max(0, offset), layout.maximumOffset))
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
      guard let self, let offset = resolve(position) else { return }
      scroll(to: offset, animated: false)
    }
  }

  private func loadOlder() {
    guard revealed, store.hasOlder, !store.paging, paging == nil else { return }
    Task { await store.older() }
  }

  // MARK: Reading position

  /// The passage under the reading line, exact to the item.
  func currentPosition() -> ReadingPosition? {
    let geometry = layout.geometry
    guard !items.isEmpty else { return nil }
    let usable = layout.usableTop
    let line = layout.visibleTop + usable
    var index = geometry.firstIndex(below: Double(line))
    if index == layout.pinned?.index { index += 1 }
    index = min(index, items.count - 1)
    guard let owner = (0...index).reversed().first(where: { items[$0].message != nil }),
      let message = items[owner].message else { return nil }
    return ReadingPosition(
      .message(id: message, offset: Double(line - layout.messageTop(owner))), viewportTop: Double(usable),
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

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    store.scrolling = true
    store.mcps.close()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard revealed else { return }
    publishState()
    requestVisibleParses()
    if layout.visibleTop < size.height * 1.5 { loadOlder() }
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settled() }
  }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled() }

  private func settled() {
    store.scrolling = touching
    scheduleCapture()
  }

  private func publishState() {
    guard isViewLoaded, revealed else { return }
    let jump = distanceToLatest > 24
    if state.jumpToLatest != jump { state.jumpToLatest = jump }
    let sticky = layout.usableTop
    if state.stickyHeight != sticky { state.stickyHeight = sticky }
  }
}

#if DEBUG
extension TranscriptViewController: TranscriptGeometrySource, TranscriptDriving {
  var geometryView: UIScrollView? { isViewLoaded ? collectionView : nil }
  /// Items on screen, each a row: finer than the List's message rows, whose union of cells would change shape
  /// as its first or last block scrolls past an edge.
  var geometryRows: [String: CGRect] {
    guard isViewLoaded else { return [:] }
    let pinned = layout.pinned?.index
    var rows: [String: CGRect] = [:]
    for cell in collectionView.visibleCells {
      // UIKit keeps a few cells just outside the bounds among its visible cells.
      guard cell.frame.intersects(collectionView.bounds), let path = collectionView.indexPath(for: cell),
        items.indices.contains(path.item), path.item != pinned
      else { continue }
      rows[items[path.item].id] = cell.frame.offsetBy(dx: 0, dy: -collectionView.contentOffset.y)
    }
    return rows
  }
  func userScrollBegan() {}
}
#endif
