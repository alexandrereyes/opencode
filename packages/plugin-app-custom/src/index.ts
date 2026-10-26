import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { registerAppMentions } from "./app-mentions/index.js"
import { registerNativeApps } from "./native-apps/index.js"
import { registerDirectories } from "./directories/index.js"
import { registerSubscriptions } from "./subscriptions/index.js"
import { registerSessionRead } from "./session-read/index.js"
import { registerSnippets } from "./snippets/index.js"
import { registerWorktrees } from "./worktrees/index.js"
import { registerNavigation } from "./navigation/index.js"
import { registerArchive } from "./archive/index.js"
import { registerPreferences } from "./preferences/index.js"
import { registerChats } from "./chats/index.js"
import { registerRequests } from "./requests/index.js"
import { registerCodexSearch } from "./codex-search/index.js"
import { registerTranscript } from "./transcript/index.js"
import { registerMaster } from "./master/index.js"
import { registerVoice } from "./voice/index.js"
import { registerSpeech } from "./speech/index.js"
import { registerMacData } from "./mac-data/index.js"
import { registerDevice } from "./device/index.js"
import { registerResources } from "./resources/index.js"
import { registerQuotes } from "./quotes/index.js"

import { registerFamily } from "./session-family/index.js"

export default Plugin.define({
  id: "custom.app-mentions",
  effect: (ctx) =>
    Effect.gen(function* () {
      yield* registerAppMentions(ctx)
      yield* registerNativeApps(ctx)
      yield* registerDirectories(ctx)
      yield* registerSubscriptions(ctx)
      yield* registerCodexSearch(ctx)
      yield* registerSessionRead(ctx)
      yield* registerSnippets(ctx)
      yield* registerWorktrees(ctx)
      yield* registerNavigation(ctx)
      yield* registerArchive(ctx)
      yield* registerPreferences(ctx)
      yield* registerChats(ctx)
      yield* registerRequests(ctx)
      yield* registerFamily(ctx)
      yield* registerTranscript(ctx)
      yield* registerMaster(ctx)
      yield* registerVoice(ctx)
      yield* registerSpeech(ctx)
      yield* registerMacData(ctx)
      yield* registerDevice(ctx)
      yield* registerResources(ctx)
      yield* registerQuotes(ctx)
    }),
})
