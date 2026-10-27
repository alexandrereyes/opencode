import OpenCodeKit
import SwiftUI

/// One text part of a response, as its items refer to it.
struct TranscriptPart: Equatable {
  let messageID: String
  let partID: String
  let source: String
  /// The response finished: file links may be resolved.
  let stable: Bool
}

/// One row of the transcript layout. Responses are split at semantic blocks (prose of a part, code, table,
/// media, activity, footer) so a long message is laid out, measured and materialized piece by piece, and a
/// streamed answer only changes its last block. Prose stays one item per run, keeping selection across
/// paragraphs. The kind carries everything that affects the item's geometry, so equal kinds share a height.
struct TranscriptItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case older(loading: Bool)
    case day(Double)
    case prompt(ConversationMessage, expanded: Bool)
    case pending(InboxItem, expanded: Bool)
    case prose(TranscriptPart, MarkdownProse)
    case block(TranscriptPart, MarkdownBlock, notesHeader: Bool)
    /// A text part whose Markdown has not been parsed yet: an estimated, empty placeholder.
    case unparsed(TranscriptPart)
    case rule
    case activity(ConversationActivityRow, messageID: String, expansion: [String: Bool])
    case shell(ConversationMessage, expansion: [String: Bool])
    case notice(ConversationMessage)
    case failure(String, warning: Bool)
    case footer(ConversationMessage)
    case permission(PermissionRequest)
    case question(PendingForm)
  }
  let id: String
  let kind: Kind
  /// Space above the item, outside its frame.
  let gap: CGFloat
  /// The message a reading position names for this item; nil for controls and request cards.
  let message: String?

  var sticky: Bool {
    switch kind {
    case .prompt, .pending: true
    default: false
    }
  }
  var part: TranscriptPart? {
    switch kind {
    case .prose(let part, _), .block(let part, _, _), .unparsed(let part): part
    default: nil
    }
  }
  /// Rendered natively as a text view instead of hosted SwiftUI.
  var native: Bool {
    if case .prose = kind { return true }
    return false
  }
}

/// Builds transcript items from the conversation's projections. Pure apart from reading the parse results it
/// is given, so equal inputs give equal items.
enum TranscriptProjection {
  struct Input {
    var messages: [ConversationActivityMessage]
    var marks: TranscriptMarks
    var dividers: Set<String>
    var pending: [InboxItem]
    var permissions: [PermissionRequest]
    var questions: [PendingForm]
    var hasOlder: Bool
    var paging: Bool
    var expansion: [String: Bool]
    var bubbles: (String) -> Bool
    /// The part's latest landed parse, as sections, and the text it came from.
    var blocks: (TranscriptPart) -> (source: String, sections: [MarkdownSection])?
  }

  /// Message rows keep the old List geometry: 10 points of padding above and below each message, 16 between
  /// its rows, 12 between a final-answer divider and its text; prompts carry their own vertical padding.
  static func items(_ input: Input) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    // Padding the previous message left below it, folded into the next gap.
    var trailing: CGFloat = 0
    if input.hasOlder { items.append(.init(id: "older", kind: .older(loading: input.paging), gap: 0, message: nil)) }
    for entry in input.messages {
      let message = entry.message
      if message.type == "user" {
        if input.marks.days.contains(message.id) {
          items.append(.init(id: "day:" + message.id, kind: .day(message.time.created), gap: trailing, message: message.id))
          trailing = 0
        }
        items.append(.init(
          id: "prompt:" + message.id, kind: .prompt(message, expanded: input.bubbles(message.id)), gap: trailing,
          message: message.id))
        trailing = 0
        continue
      }
      var content: [TranscriptItem] = []
      let gap: CGFloat = trailing + 10
      // A day chip carries 6 points of padding on each side, inside its frame.
      var chip: CGFloat = 0
      func add(_ id: String, _ kind: TranscriptItem.Kind, spacing: CGFloat = 16) {
        content.append(.init(id: id, kind: kind, gap: (content.isEmpty ? gap : spacing) - chip, message: message.id))
        chip = 0
      }
      if input.marks.days.contains(message.id) {
        chip = 6
        add("day:" + message.id, .day(message.time.created))
        chip = 6
      }
      if message.type == "assistant" || !entry.rows.isEmpty {
        for row in entry.rows {
          switch row.kind {
          case .text:
            guard let text = row.parts.first else { continue }
            let completed = text.messageID == message.id
              ? message.time.completed != nil
              : input.messages.first { $0.message.id == text.messageID }?.message.time.completed != nil
            let part = TranscriptPart(
              messageID: text.messageID, partID: text.id, source: text.part.text ?? "", stable: completed)
            var spacing: CGFloat = 16
            if input.dividers.contains(text.id) {
              add("rule:" + text.id, .rule)
              spacing = 12
            }
            guard let parsed = input.blocks(part) else {
              add("text:" + text.id, .unparsed(part), spacing: spacing)
              continue
            }
            // Items show the text their blocks came from: a newer streamed text changes nothing until it parses.
            let shown = TranscriptPart(
              messageID: part.messageID, partID: part.partID, source: parsed.source, stable: part.stable)
            var first = true
            var previous: MarkdownBlock?
            for section in parsed.sections {
              switch section {
              case .prose(let prose):
                add("text:\(text.id):\(prose.id)", .prose(shown, prose),
                  spacing: first ? spacing : CGFloat(prose.spacing.first ?? 0))
                previous = prose.segments.last
              case .block(let block):
                let notes = Self.footnote(block) && !(previous.map(Self.footnote) ?? false)
                add("text:\(text.id):\(block.id)", .block(shown, block, notesHeader: notes),
                  spacing: first ? spacing : CGFloat(MarkdownBlocks.spacing(block, after: previous)))
                previous = block
              }
              first = false
            }
          case .divider:
            add("rule:" + row.id, .rule)
          default:
            guard !row.parts.isEmpty else { continue }
            let keys = [row.id] + row.parts.map { "activity:detail:" + $0.id }
            add("row:" + row.id, .activity(row, messageID: message.id,
              expansion: input.expansion.filter { keys.contains($0.key) }))
          }
        }
        if let error = message.error {
          add("error:" + message.id, .failure(error.object?["message"]?.string ?? error.formatted, warning: false))
        }
        if let retry = message.retry {
          add("retry:" + message.id,
            .failure("Nova tentativa \(Int(retry.object?["attempt"]?.number ?? 0)) agendada", warning: true))
        }
        if message.type == "assistant", input.marks.footers.contains(message.id), message.time.completed != nil,
          message.error == nil, message.retry == nil, !message.responseText.isEmpty
        {
          add("footer:" + message.id, .footer(message))
        }
      } else if message.type == "shell" {
        let keys = [message.id] + message.tools.compactMap(\.id).map { "activity:detail:" + $0 }
        add("shell:" + message.id, .shell(message, expansion: input.expansion.filter { keys.contains($0.key) }))
      } else if message.type != "idle" || message.outcome == "interrupted" || message.outcome == "failed" {
        add("notice:" + message.id, .notice(message))
      }
      if content.isEmpty { continue }
      items += content
      trailing = 10
    }
    // Like delivered prompts, each pending one starts a section, so delivery swaps it in place.
    for item in input.pending {
      items.append(.init(
        id: "prompt:" + item.id, kind: .pending(item, expanded: input.bubbles(item.id)), gap: trailing, message: nil))
      trailing = 0
    }
    for request in input.permissions {
      items.append(.init(id: "permission:" + request.id, kind: .permission(request), gap: trailing + 10, message: nil))
      trailing = 10
    }
    for form in input.questions {
      items.append(.init(id: "question:" + form.id, kind: .question(form), gap: trailing + 10, message: nil))
      trailing = 10
    }
    return items
  }

  private static func footnote(_ block: MarkdownBlock) -> Bool {
    if case .footnote = block.kind { return true }
    return false
  }
}
