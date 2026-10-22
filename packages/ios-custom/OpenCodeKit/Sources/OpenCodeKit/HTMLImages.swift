import Foundation

enum HTMLImages {
  static func parse(_ html: String) -> [FeedImage] {
    guard let tags = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]),
      let attributes = try? NSRegularExpression(
        pattern: #"\s(src|alt)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive]) else { return [] }
    let source = html as NSString
    return tags.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
      let tag = source.substring(with: match.range) as NSString
      let values = attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length))
        .reduce(into: [String: String]()) { result, attribute in
          guard let range = (2...4).map({ attribute.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return }
          result[tag.substring(with: attribute.range(at: 1)).lowercased()] = tag.substring(with: range)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        }
      guard let src = values["src"], !src.isEmpty else { return nil }
      return FeedImage(source: src, name: values["alt"] ?? "Imagem")
    }
  }
}
