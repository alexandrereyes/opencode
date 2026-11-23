import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Effect } from "effect"
import { limits, registerRig } from "../src/rig/index"

const folders: string[] = []
afterEach(() => Promise.all(folders.splice(0).map((folder) => fs.rm(folder, { recursive: true, force: true }))))

/** The status the rig server writes (`fila-contrato.md`), with a field this plugin does not know: it goes as it came. */
const queue = {
  versao: 1,
  agora: 1_795_400_000_000,
  maquinas: [{ nome: "mac", ok: true }],
  pedidos: [{ id: "p-cc0ecac1", teste: "android", estado: "esperando", posicao: 1, aparelhos: [], novo: { x: [1] } }],
  reservas: [],
}

/** A PATH whose `rig` answers `status --json` with `body` (and anything else with exit 3); without one, none. */
async function path_(body?: string) {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-rig-"))
  folders.push(folder)
  if (body !== undefined) {
    // Like the real one, a compiled Bun binary: with `BUN_BE_BUN` it would not be the rig.
    await Bun.write(
      path.join(folder, "rig"),
      `#!/bin/sh\n[ -z "$BUN_BE_BUN" ] || exit 4\n[ "$*" = "status --json" ] || exit 3\n${body}\n`,
    )
    await fs.chmod(path.join(folder, "rig"), 0o755)
  }
  return folder
}

/** `custom.rig/status` as the host calls the registered handler; its error as the RPC's type, reason and message. */
async function call(PATH: string) {
  const handlers: { status?: (input: object, context: unknown) => Effect.Effect<unknown, unknown> } = {}
  const ctx = {
    rpc: {
      register: (_definition: unknown, registered: typeof handlers) =>
        Effect.sync(() => Object.assign(handlers, registered)),
    },
  } as never
  await Effect.runPromise(Effect.scoped(registerRig(ctx, { PATH, HOME: os.tmpdir(), BUN_BE_BUN: "1" })))
  const context = { error: (type: string, message: string, data: unknown) => ({ type, message, data }) }
  return Effect.runPromise(
    handlers.status!({}, context).pipe(
      Effect.map((output) => ({ output })),
      Effect.catch((error) => Effect.succeed({ error })),
    ),
  )
}

describe("custom.rig/status", () => {
  test("answers rig status --json as it came", async () => {
    expect(await call(await path_(`printf '%s\\n' '${JSON.stringify(queue)}'`))).toEqual({ output: queue })
  })

  test.each([
    ["no rig on the PATH", undefined, "missing", "rig is not on this server's PATH"],
    ["it fails", "echo 'servidor fora' >&2; exit 1", "failed", "rig status --json ended with 1: servidor fora"],
    ["it prints no JSON", "echo 'Fila: vazia'", "failed", "rig status --json printed no JSON"],
    ["it does not end in time", "exec /bin/sleep 5", "failed", "rig status --json ended with 143"],
  ] as const)("%s: unavailable", async (_case, body, reason, message) => {
    const statusMs = limits.statusMs
    limits.statusMs = 300
    const answer = await call(await path_(body)).finally(() => {
      limits.statusMs = statusMs
    })
    expect(answer).toEqual({ error: { type: "unavailable", message, data: { reason } } })
  })
})
