import { expect, test } from "bun:test"
import { Effect, Exit } from "effect"
import { before, evaluate, refusal } from "../src/browse-guard/index"

const cases: ReadonlyArray<readonly [string, string, unknown, boolean]> = [
  ["stop that stores a profile", "browse_network", { action: "stop", secrets: "github" }, true],
  ["stop with a HAR and a profile", "browse_network", { action: "stop", outputPath: "a.har", secrets: "x" }, true],
  ["the dotted path", "browse.network", { action: "stop", secrets: "x" }, true],
  ["an empty profile name", "browse_network", { action: "stop", secrets: "" }, true],
  ["secrets on any action", "browse_network", { action: "start", secrets: "x" }, true],
  ["start", "browse_network", { action: "start" }, false],
  ["stop with only a redacted HAR", "browse_network", { action: "stop", outputPath: "a.har" }, false],
  ["secrets left undefined", "browse_network", { action: "stop", outputPath: "a.har", secrets: undefined }, false],
  ["no input", "browse_network", undefined, false],
  ["browse execute", "browse_execute", { code: "return 1", secrets: "x" }, false],
  ["another server's network", "other_network", { action: "stop", secrets: "x" }, false],
  ["running a stored profile", "browse_secrets_run", { name: "x", command: "true" }, false],
]

test.each(cases)(
  "%s: denied by permission and refused before the call only when it stores credentials",
  (_, tool, input, blocked) => {
    const event: { action: string; metadata?: Record<string, unknown>; effect: string; message?: string } = {
      action: tool,
      metadata: { input },
      effect: "allow",
    }
    Effect.runSync(evaluate(event))
    expect(event).toEqual({
      action: tool,
      metadata: { input },
      effect: blocked ? "deny" : "allow",
      ...(blocked ? { message: refusal } : {}),
    })

    const exit = Effect.runSyncExit(before({ tool, input }))
    if (!blocked) return expect(Exit.isSuccess(exit)).toBe(true)
    expect(Exit.isFailure(exit) && exit.cause.toString()).toContain("não pode gravar credenciais em disco")
  },
)
