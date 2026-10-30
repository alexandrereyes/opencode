import { expect } from "bun:test"
import { Effect, Schema } from "effect"
import { Agent } from "@opencode/core/agent"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { Tool } from "@opencode/core/tool"
import { SessionMessage } from "@opencode/schema/session-message"
import { Session } from "@opencode/schema/session"
import { testEffect } from "./lib/effect"
import { codeModeListings } from "./lib/tool"
import { PluginTestLayer } from "./plugin/fixture"
import { agentID, controlNames, registerMaster } from "../../plugin-app-custom/src/master"
import { registerSessionRead } from "../../plugin-app-custom/src/session-read"

testEffect(PluginTestLayer).live(
  "only Mestra resolves master controls in Code Mode, including late configured agents and subagents",
  () =>
    Effect.gen(function* () {
      const plugins = yield* Plugin.Service
      const agents = yield* Agent.Service
      const registry = yield* Tool.Service
      const ctx = yield* PluginHost.make(plugins)
      yield* ctx.agent.transform((editor) => {
        editor.update("build", () => {})
        editor.update("explore", (agent) => {
          agent.mode = "subagent"
        })
      })
      yield* registerSessionRead(ctx)
      yield* registerMaster(ctx)
      // Configuration contributes agents after external plugins, and session rules may allow all tools.
      yield* ctx.agent.transform((editor) => editor.update("configured-later", () => {}))
      const output = Schema.Struct({ output: Schema.String })
      for (const id of [
        agentID,
        Agent.ID.make("build"),
        Agent.ID.make("explore"),
        Agent.ID.make("configured-later"),
        agentID,
      ]) {
        const agent = yield* agents.get(id)
        if (!agent) throw new Error("Missing agent")
        const snapshot = yield* registry.snapshot(
          [...agent.permissions, { action: "*", resource: "*", effect: "allow" }],
          id,
        )
        const paths = snapshot.codeModeCatalog
          ? codeModeListings(snapshot.codeModeCatalog).map((tool) => tool.path)
          : []
        expect(paths.filter((path) => controlNames.some((name) => path === `opencode.${name}`)).toSorted()).toEqual(
          id === agentID ? controlNames.map((name) => `opencode.${name}`).toSorted() : [],
        )
        expect(paths).toContain("opencode.session_read")
        const search = yield* snapshot.execute({
          sessionID: Session.ID.make("ses_visibility"),
          agent: id,
          messageID: SessionMessage.ID.make("msg_visibility"),
          call: {
            type: "tool-call",
            id: "catalog",
            name: "execute",
            input: { code: 'return search({namespace:"opencode",limit:100})' },
          },
        })
        const catalog = Schema.decodeUnknownSync(
          Schema.fromJsonString(Schema.Struct({ items: Schema.Array(Schema.Struct({ path: Schema.String })) })),
        )(Schema.decodeUnknownSync(output)(search.output).output)
        expect(
          catalog.items
            .filter((tool) => controlNames.some((name) => tool.path === `tools.opencode.${name}`))
            .map((tool) => tool.path)
            .toSorted(),
        ).toEqual(id === agentID ? controlNames.map((name) => `tools.opencode.${name}`).toSorted() : [])
      }
    }),
)
