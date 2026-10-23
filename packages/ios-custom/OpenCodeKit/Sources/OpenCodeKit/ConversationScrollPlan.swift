/// One owner consumes a burst only after two matching native layout measurements.
public struct ConversationScrollPlan: Sendable {
  public enum Action: Sendable, Equatable { case tail(animated: Bool), reading }
  public struct Viewport: Sendable, Equatable {
    public let height: Double
    public let offset: Double
    public let viewport: Double
    public init(height: Double, offset: Double, viewport: Double) {
      self.height = height
      self.offset = offset
      self.viewport = viewport
    }
    public var overflow: Bool { height - viewport > 1 }
    public var distance: Double { height - viewport - offset }
    public var jumpToLatest: Bool { overflow && distance > max(400, viewport) }
    public var atEnd: Bool { !overflow || distance <= 0.5 }
    public func arrivedAtEnd(from previous: Self) -> Bool {
      atEnd && (!overflow || offset > previous.offset + 0.5
        || height - viewport < previous.height - previous.viewport)
    }
  }
  public struct Layout: Sendable, Equatable {
    public let height: Double
    public let width: Double
    public let viewport: Double
    public let bottom: Double
    public init(height: Double, width: Double, viewport: Double, bottom: Double) {
      self.height = height
      self.width = width
      self.viewport = viewport
      self.bottom = bottom
    }
  }
  public private(set) var following = false
  public private(set) var pending = false
  private var animated = false
  private var layout: Layout?

  public init() {}
  public mutating func follow(animated: Bool = false) {
    if !following { layout = nil }
    following = true
    self.animated = self.animated || animated
    invalidate()
  }
  public mutating func invalidate() {
    if !pending { layout = nil }
    pending = true
  }
  public mutating func cancel() {
    following = false
    pending = false
    animated = false
    layout = nil
  }
  public mutating func consume(_ next: Layout, interacting: Bool) -> Action? {
    if interacting { cancel(); return nil }
    guard pending else { return nil }
    guard layout == next else { layout = next; return nil }
    pending = false
    defer { animated = false }
    return following ? .tail(animated: animated) : .reading
  }
}
