import { Plugin } from "@opencode/plugin/effect"
import { registerNativeApps } from "../../src/native-apps/index.js"

export default Plugin.define({
  id: "custom.native-apps-fixture",
  effect: (ctx) => registerNativeApps(ctx, { platform: "linux" }),
})
