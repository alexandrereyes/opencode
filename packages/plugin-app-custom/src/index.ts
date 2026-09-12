import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { registerAppMentions } from "./app-mentions/index.js"
import { registerSubscriptions } from "./subscriptions/index.js"

export default Plugin.define({
  id: "custom.app-mentions",
  effect: (ctx) =>
    Effect.gen(function* () {
      yield* registerAppMentions(ctx)
      yield* registerSubscriptions(ctx)
    }),
})
