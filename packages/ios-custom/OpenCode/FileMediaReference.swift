import OpenCodeKit
import SwiftUI

struct FileMediaReference: View {
  @Environment(\.openFile) private var action
  @Environment(\.appTheme) private var theme
  let source: String
  let name: String
  var body: some View {
    Button { action?.open(source) } label: {
      Label(name.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : name,
        systemImage: "play.rectangle")
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.markdownLink))
    .accessibilityIdentifier("file-media-\(name)")
  }
}
