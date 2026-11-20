import fs from "node:fs/promises"
import path from "node:path"
import { Tool } from "@opencode/schema/tool"
import type { ToolHooks } from "@opencode/plugin/effect/tool"
import { Effect } from "effect"
import type { Context } from "../context.js"
import { shellCommand, shellWorkdir } from "../resources/index.js"
import type { BancadaClient } from "./client.js"
import { inspect, reserved, touchesDevices } from "./commands.js"
import { parseContract } from "./contract.js"
import { runGit } from "./daemon/git.js"
import { familyOf } from "./tools.js"

/**
 * The Bancada's hook on shell commands (`docs/bancada.md`, "Hook"). Step 1 here: a command the session's repository
 * reserves to the Bancada (`fora`) is refused. The rest goes to the process only when the command may touch a device:
 * it decides on phones, other sessions' devices and slots, and asks for a slot when the command starts an emulator or
 * simulator. A process that does not answer in 3 s lets the command pass with a warning, except a start (it cannot
 * be given a slot then).
 */
export function makeBancadaHook(ctx: Pick<Context, "session">, client: BancadaClient) {
  /** Calls that passed without the process: their result carries a warning. */
  const unchecked = new Set<string>()
  /** Each folder's repository root (`null`: none), and each root's `.bancada.toml` by modification time. */
  const roots = new Map<string, string | null>()
  const contracts = new Map<string, { readonly at: number; readonly outside: string[]; readonly tests: string[] }>()

  const repository = async (directory: string) => {
    if (roots.has(directory)) return roots.get(directory) ?? undefined
    const top = await runGit(["rev-parse", "--show-toplevel"], { cwd: directory }).catch(() => undefined)
    const root = top?.code === 0 ? top.stdout.trim() : null
    roots.set(directory, root)
    return root ?? undefined
  }
  const contract = async (root: string) => {
    const file = path.join(root, ".bancada.toml")
    const at = await fs
      .stat(file)
      .then((stat) => stat.mtimeMs)
      .catch(() => undefined)
    if (at === undefined) return undefined
    const known = contracts.get(root)
    if (known?.at === at) return known
    const parsed = parseContract(await Bun.file(file).text(), { project: path.basename(root) })
    const read = parsed.ok
      ? { at, outside: [...parsed.contract.outside], tests: Object.keys(parsed.contract.tests) }
      : { at, outside: [], tests: [] }
    contracts.set(root, read)
    return read
  }

  return {
    before: (event: ToolHooks["execute.before"]) =>
      Effect.gen(function* () {
        const command = shellCommand(event.tool, event.input)
        if (!command) return
        const family = yield* familyOf(ctx, event.sessionID)
        const workdir = shellWorkdir(event.input) ?? family.directory
        // 1. A command only the Bancada runs in this repository.
        const root = yield* Effect.promise(() => repository(workdir))
        const read = root ? yield* Effect.promise(() => contract(root)) : undefined
        const hit = root && read ? reserved(command, { root, workdir, outside: read.outside }) : undefined
        if (hit && read)
          return yield* new Tool.Error({
            message: `Neste repositório, \`${hit}\` só roda pela Bancada. Use \`bancada_run\` com o teste ${read.tests.map((name) => `\`${name}\``).join(" ou ")}.`,
          })
        if (!touchesDevices(command)) return
        const parts = inspect(command)
        if (parts.length === 0) return
        const starts = parts.some((part) => part.starts.length > 0)
        const decision = yield* Effect.tryPromise(() =>
          client.call<{ allow: boolean; message?: string }>(
            "hook",
            {
              sessionID: event.sessionID,
              rootSessionID: family.root,
              ...(family.title ? { sessionTitle: family.title } : {}),
              ...(family.rootTitle ? { rootTitle: family.rootTitle } : {}),
              parts,
            },
            // A start may wait up to 8 s for another machine's answer.
            starts ? 12_000 : 3_000,
          ),
        ).pipe(Effect.option)
        if (decision._tag === "None") {
          if (starts)
            return yield* new Tool.Error({ message: "a Bancada está reconciliando; tente de novo em instantes" })
          unchecked.add(event.id)
          return
        }
        if (!decision.value.allow)
          return yield* new Tool.Error({ message: decision.value.message ?? "A Bancada recusou este comando." })
      }),
    after: (event: ToolHooks["execute.after"]) =>
      Effect.sync(() => {
        if (!unchecked.delete(event.id) || event.status !== "completed") return
        const content =
          typeof event.result.content === "string"
            ? [{ type: "text" as const, text: event.result.content }]
            : (event.result.content ?? [])
        event.result = { ...event.result, content: [...content, { type: "text" as const, text: warning }] }
      }),
  }
}

const warning =
  "[Bancada] O processo da Bancada não respondeu: este comando passou sem a conferência de aparelhos e reservas."
