import Foundation

/// UTF-16 positions for inline quote numbers. Decorations participate in wrapping, never in authored text.
public struct QuoteTextMap: Equatable, Sendable {
  public struct Marker: Equatable, Sendable {
    public let id: String
    public let number: Int
    public let offset: Int
    public init(id: String, number: Int, offset: Int) { self.id = id; self.number = number; self.offset = offset }
  }
  public struct Insertion: Equatable, Sendable {
    public let marker: Marker
    public let range: NSRange
  }
  public let insertions: [Insertion]
  public init(_ markers: [Marker] = []) {
    var advance = 0
    insertions = markers.sorted { $0.offset == $1.offset ? $0.number < $1.number : $0.offset < $1.offset }.map {
      let count = String($0.number).utf16.count
      defer { advance += count }
      return Insertion(marker: $0, range: NSRange(location: $0.offset + advance, length: count))
    }
  }
  public func original(_ range: NSRange) -> NSRange {
    func offset(_ value: Int) -> Int {
      value - insertions.reduce(0) { $0 + min($1.range.length, max(0, value - $1.range.location)) }
    }
    return NSRange(location: offset(range.location), length: offset(NSMaxRange(range)) - offset(range.location))
  }
  public func display(_ range: NSRange) -> NSRange {
    let start = range.location + insertions.filter { $0.marker.offset <= range.location }.reduce(0) { $0 + $1.range.length }
    let end = NSMaxRange(range) + insertions.filter { $0.marker.offset < NSMaxRange(range) }.reduce(0) { $0 + $1.range.length }
    return NSRange(location: start, length: max(0, end - start))
  }
}
