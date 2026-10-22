import Foundation

struct ConversationReadingRequest: Equatable {
  let token = UUID()
  let messageID: String
  var offset: Double = 0
  var persist = true
}
