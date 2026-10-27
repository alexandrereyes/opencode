import OpenCodeKit
import SwiftUI

struct AgentPixels: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let color: Color
  var size: CGFloat = 18
  var running = true
  var body: some View {
    if running {
      TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
        Canvas { canvas, bounds in
          let tick = Int(context.date.timeIntervalSince1970 * 7)
          for row in 0..<5 {
            for column in 0..<5 {
              let alpha = reduceMotion ? 1.0 : Double((row * 3 + column + tick) % 5 + 1) / 5
              let rect = CGRect(
                x: CGFloat(column) * bounds.width / 5, y: CGFloat(row) * bounds.height / 5,
                width: bounds.width / 7, height: bounds.height / 7)
              canvas.fill(Path(rect), with: .color(color.opacity(alpha)))
            }
          }
        }
      }.frame(width: size, height: size)
    } else {
      RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1.2)
        .overlay { Rectangle().fill(color).padding(4) }.frame(width: size, height: size)
    }
  }
}

extension AppTheme {
  func agentRole(_ agent: AgentInfo?, id: String) -> ThemeRole {
    switch agent?.color {
    case "primary": return .agentPrimary
    case "secondary": return .agentSecondary
    case "accent": return .agentAccent
    case "success": return .agentStateSuccess
    case "warning": return .agentStateWarning
    case "error": return .agentError
    case "info": return .agentStateInfo
    default: break
    }
    switch id {
    case "build": return .agentBuild
    case "explore": return .agentExplore
    case "plan": return .agentPlan
    case "review": return .agentReview
    case "writer": return .agentWriter
    default:
      let palette: [ThemeRole] = [
        .agentAsk, .agentLegacyBuild, .agentDocs, .agentLegacyPlan, .agentInfo, .agentSuccess,
        .agentWarning, .agentProperty, .agentConstant, .agentAdded, .agentDeleted,
        .agentLegacyWarning,
      ]
      let hash = id.lowercased().utf16.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
      return palette[Int(hash) % palette.count]
    }
  }
}
