#if DEBUG
import OpenCodeKit
import SwiftUI

/// `-OpenCodeAgentsActivityFixture <names>` (comma separated, for example `state-mixed` or
/// `state-mixed,state-working` to show two activities and the minimal island) starts local Live Activities with
/// the contract fixtures of `plugin-app-custom/docs/live-activity/`, embedded verbatim. Excluded from Release.
enum AgentsActivityFixtures {
  static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-OpenCodeAgentsActivityFixture") }

  static var requested: [(attributes: AgentsActivityAttributes, state: AgentsState)]? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-OpenCodeAgentsActivityFixture"), arguments.indices.contains(index + 1)
    else { return nil }
    let names = arguments[index + 1].split(separator: ",").map(String.init)
    let decoder = JSONDecoder()
    guard let attributes = try? decoder.decode(AgentsActivityAttributes.self, from: Data(Self.attributes.utf8))
    else { return nil }
    return names.enumerated().compactMap { offset, name in
      guard let json = states[name], var state = try? decoder.decode(AgentsState.self, from: Data(json.utf8))
      else { return nil }
      // Keep the fixture's relative times (timer 12:04, "há 3 min") whenever the capture runs.
      let shift = (Date.now.timeIntervalSince1970 * 1000).rounded() - state.updatedAt
      state.updatedAt += shift
      state.focus?.startedAt += shift
      for index in state.attention.indices { state.attention[index].since += shift }
      let key = offset == 0 ? attributes.serverKey : "\(attributes.serverKey)-\(offset + 1)"
      return (AgentsActivityAttributes(serverKey: key, theme: attributes.theme), state)
    }
  }

  static let attributes = #"""
{
  "serverKey": "mac-principal",
  "theme": {
    "background": "#120f0eff",
    "surface": "#161313ff",
    "border": "#2e2e2dff",
    "textStrong": "#e4e0d6ff",
    "text": "#c9c5baff",
    "textSecondary": "#a29f94ff",
    "textWeak": "#6b6861ff",
    "primary": "#da7c47ff",
    "success": "#83b35fff",
    "warning": "#c67f13ff",
    "error": "#dc6e5eff",
    "accent": "#9988e5ff"
  }
}
"""#

  static let states: [String: String] = contract.merging(["state-long-rows": longRows]) { first, _ in first }

  /// Not a contract fixture: four working rows with long titles and projects, like the device report.
  static let longRows = #"""
{"v":1,"updatedAt":1793104860000,"host":"MacBook Pro de Alexandre","counts":{"working":4,"question":0,"permission":0,
"failed":0,"idle":0},"activeTotal":4,"focus":{"sessionID":"ses_long_1","title":"Revisar o acoplamento entre prompt e execução","project":"abacato-v2",
"directory":"/Users/alexandremartins/Dev/abacato-v2","startedAt":1793104136000,"activity":"Editando SessionExecutionCoordinator.swift",
"progress":{"done":1,"total":5,"unit":"subagents"}},"attention":[],"attentionTotal":0,"sessions":[
{"sessionID":"ses_long_1","title":"Revisar o acoplamento entre prompt e execução","project":"abacato-v2","directory":"/d","status":"working","progress":{"done":1,"total":5,"unit":"subagents"}},
{"sessionID":"ses_long_2","title":"Migrar a navegação das Sessões para o novo roteador","project":"opencode2","directory":"/d","status":"working"},
{"sessionID":"ses_long_3","title":"Acoplamentos prompt","project":"abacato-v2","directory":"/d","status":"working"},
{"sessionID":"ses_long_4","title":"Deploy no Swarm","project":"core-infra","directory":"/d","status":"working"}]}
"""#

  static let contract: [String: String] = [
    "state-one-question": #"""
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "MacBook Pro",
  "counts": {
    "working": 3,
    "question": 1,
    "permission": 0,
    "failed": 0,
    "idle": 3,
    "unread": 3
  },
  "activeTotal": 4,
  "focus": {
    "sessionID": "ses_01JZLIVEACTIVITY0000000001",
    "title": "Live Activity no iOS",
    "project": "ios-custom",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
    "startedAt": 1793104136000,
    "activity": "Editando ConversationStore.swift",
    "progress": {
      "done": 2,
      "total": 3,
      "unit": "subagents"
    }
  },
  "attention": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "kind": "question",
      "since": 1793104680000,
      "text": "Qual banco usar no cache?"
    }
  ],
  "attentionTotal": 1,
  "sessions": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "question"
    },
    {
      "sessionID": "ses_01JZLIVEACTIVITY0000000001",
      "title": "Live Activity no iOS",
      "project": "ios-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
      "status": "working",
      "progress": {
        "done": 2,
        "total": 3,
        "unit": "subagents"
      }
    },
    {
      "sessionID": "ses_01JZOAUTHLOGIN000000000003",
      "title": "Corrigir login OAuth",
      "project": "app-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
      "status": "working"
    },
    {
      "sessionID": "ses_01JZDEPLOYSWARM00000000005",
      "title": "Deploy no Swarm",
      "project": "core-infra",
      "directory": "/Users/alexandremartins/Dev/core-infra",
      "status": "working"
    }
  ]
}
"""#,
    "state-two-questions": #"""
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "MacBook Pro",
  "counts": {
    "working": 2,
    "question": 2,
    "permission": 0,
    "failed": 0,
    "idle": 3,
    "unread": 3
  },
  "activeTotal": 4,
  "focus": {
    "sessionID": "ses_01JZLIVEACTIVITY0000000001",
    "title": "Live Activity no iOS",
    "project": "ios-custom",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
    "startedAt": 1793104136000,
    "activity": "Editando ConversationStore.swift",
    "progress": {
      "done": 2,
      "total": 3,
      "unit": "subagents"
    }
  },
  "attention": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "kind": "question",
      "since": 1793104680000,
      "text": "Qual banco usar no cache?"
    },
    {
      "sessionID": "ses_01JZOAUTHLOGIN000000000003",
      "title": "Corrigir login OAuth",
      "project": "app-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
      "kind": "question",
      "since": 1793104800000,
      "text": "Manter o refresh token no Keychain?"
    }
  ],
  "attentionTotal": 2,
  "sessions": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "question"
    },
    {
      "sessionID": "ses_01JZOAUTHLOGIN000000000003",
      "title": "Corrigir login OAuth",
      "project": "app-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
      "status": "question"
    },
    {
      "sessionID": "ses_01JZLIVEACTIVITY0000000001",
      "title": "Live Activity no iOS",
      "project": "ios-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
      "status": "working",
      "progress": {
        "done": 2,
        "total": 3,
        "unit": "subagents"
      }
    },
    {
      "sessionID": "ses_01JZDEPLOYSWARM00000000005",
      "title": "Deploy no Swarm",
      "project": "core-infra",
      "directory": "/Users/alexandremartins/Dev/core-infra",
      "status": "working"
    }
  ]
}
"""#,
    "state-mixed": #"""
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "MacBook Pro",
  "counts": {
    "working": 1,
    "question": 1,
    "permission": 1,
    "failed": 2,
    "idle": 1,
    "unread": 1
  },
  "activeTotal": 3,
  "focus": {
    "sessionID": "ses_01JZLIVEACTIVITY0000000001",
    "title": "Live Activity no iOS",
    "project": "ios-custom",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
    "startedAt": 1793104136000,
    "activity": "Editando ConversationStore.swift",
    "progress": {
      "done": 2,
      "total": 3,
      "unit": "subagents"
    }
  },
  "attention": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "kind": "question",
      "since": 1793104680000,
      "text": "Qual banco usar no cache?"
    },
    {
      "sessionID": "ses_01JZOAUTHLOGIN000000000003",
      "title": "Corrigir login OAuth",
      "project": "app-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
      "kind": "permission",
      "since": 1793104800000,
      "text": "bash · bun test --filter oauth"
    }
  ],
  "attentionTotal": 2,
  "sessions": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "question"
    },
    {
      "sessionID": "ses_01JZOAUTHLOGIN000000000003",
      "title": "Corrigir login OAuth",
      "project": "app-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
      "status": "permission"
    },
    {
      "sessionID": "ses_01JZDEPLOYSWARM00000000005",
      "title": "Deploy no Swarm",
      "project": "core-infra",
      "directory": "/Users/alexandremartins/Dev/core-infra",
      "status": "failed"
    },
    {
      "sessionID": "ses_01JZNAVIGATIONREVIEW000004",
      "title": "Revisar navegação",
      "project": "app",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "failed"
    }
  ]
}
"""#,
    "state-working": #"""
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "MacBook Pro",
  "counts": {
    "working": 2,
    "question": 0,
    "permission": 0,
    "failed": 0,
    "idle": 1,
    "unread": 1
  },
  "activeTotal": 2,
  "focus": {
    "sessionID": "ses_01JZLIVEACTIVITY0000000001",
    "title": "Live Activity no iOS",
    "project": "ios-custom",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
    "startedAt": 1793104136000,
    "activity": "Editando ConversationStore.swift",
    "progress": {
      "done": 2,
      "total": 3,
      "unit": "subagents"
    }
  },
  "attention": [],
  "attentionTotal": 0,
  "sessions": [
    {
      "sessionID": "ses_01JZLIVEACTIVITY0000000001",
      "title": "Live Activity no iOS",
      "project": "ios-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
      "status": "working",
      "progress": {
        "done": 2,
        "total": 3,
        "unit": "subagents"
      }
    },
    {
      "sessionID": "ses_01JZDEPLOYSWARM00000000005",
      "title": "Deploy no Swarm",
      "project": "core-infra",
      "directory": "/Users/alexandremartins/Dev/core-infra",
      "status": "working"
    },
    {
      "sessionID": "ses_01JZNAVIGATIONREVIEW000004",
      "title": "Revisar navegação",
      "project": "app",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "idle"
    }
  ]
}
"""#,
    "state-failed-only": #"""
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "MacBook Pro",
  "counts": {
    "working": 0,
    "question": 0,
    "permission": 0,
    "failed": 1,
    "idle": 2,
    "unread": 2
  },
  "activeTotal": 0,
  "attention": [],
  "attentionTotal": 0,
  "sessions": [
    {
      "sessionID": "ses_01JZDEPLOYSWARM00000000005",
      "title": "Deploy no Swarm",
      "project": "core-infra",
      "directory": "/Users/alexandremartins/Dev/core-infra",
      "status": "failed"
    },
    {
      "sessionID": "ses_01JZNAVIGATIONREVIEW000004",
      "title": "Revisar navegação",
      "project": "app",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "idle"
    },
    {
      "sessionID": "ses_01JZLIVEACTIVITY0000000001",
      "title": "Live Activity no iOS",
      "project": "ios-custom",
      "directory": "/Users/alexandremartins/Worktrees/opencode2-live-activity",
      "status": "idle"
    }
  ]
}
"""#,
  ]
}
/// Keeps fixture launches off every server: no store, event stream or registration is created.
struct AgentsActivityFixtureRoot: View {
  var body: some View {
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeActivityPriorityFixture") {
      ActivityPriorityFixtureRoot()
    } else {
      ContentUnavailableView("Live Activity de exemplo", systemImage: "rectangle.badge.checkmark",
        description: Text("Bloqueie a tela ou volte ao início para ver a atividade Agentes."))
        .task { AgentsActivityAgent.shared.start() }
    }
  }
}
#endif
