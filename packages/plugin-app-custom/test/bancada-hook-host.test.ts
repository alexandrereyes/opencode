import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { afterAll, beforeAll, describe, expect } from "bun:test"
import { Effect } from "effect"
import { AbsolutePath } from "@opencode/core/schema"
import { Watcher } from "@opencode/core/filesystem/watcher"
import { Location } from "@opencode/core/location"
import { Plugin } from "@opencode/core/plugin"
import { PluginModule } from "@opencode/core/plugin/module"
import { Session } from "@opencode/core/session"
import { Tool } from "@opencode/core/tool"
import { ShellTool } from "@opencode/core/tool/plugin/shell"
import type { Context } from "@opencode/plugin/effect/plugin"
import { liveness } from "../src/bancada/daemon/launcher/process"
import { runGit } from "../src/bancada/daemon/git"
import { initGit } from "../../core/test/fixture/git"
import { testEffect } from "../../core/test/lib/effect"
import { executeTool, toolIdentity, waitForTool } from "../../core/test/lib/tool"
import { PluginTestLayer } from "../../core/test/plugin/fixture"

// The custom plugin loaded by the core's plugin host, its hooks run by the core's tool registry as a server runs
// them: the Bancada's hook refuses and lets pass (`docs/bancada.md`, "Tests": 15.3). Its process lives in a folder of
// this test, with a machine file of its own; the shell tool is a stand-in that only says it ran.
const world: { root?: string; env?: Record<string, string | undefined> } = {}

beforeAll(async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-host-"))
  world.root = root
  // The agent's environment is production's: none of it reaches the plugin here (its watch gateway would try
  // production's port, its resources hub production's inventory).
  world.env = Object.fromEntries(
    Object.keys(process.env)
      .filter((name) => name.startsWith("OPENCODE_"))
      .map((name) => [name, process.env[name]]),
  )
  Object.keys(world.env).forEach((name) => delete process.env[name])
  process.env.OPENCODE_WATCH_GATEWAY_PORT = "0"
  process.env.OPENCODE_RESOURCES_HUB_INVENTORY = "0"
  await Bun.write(
    path.join(root, "bancada.toml"),
    `versao = 1\n[orcamento]\nmemoria_gb = 32\ncpu = 16\n[execucao]\nmodo = "processo"\n` +
      `[[fisico]]\napelido = "poco"\nnome = "POCO X7"\nid = "IBHUYT85ZTYH5XDM"\nplataforma = "android"\ntransporte = "usb"\n`,
  )
  const repository = path.join(root, "projeto")
  await fs.cp(path.join(import.meta.dir, "fixture/bancada-exemplo"), repository, { recursive: true })
  await initGit(repository)
  await runGit(["add", "-A"], { cwd: repository })
  await runGit(["commit", "-q", "-m", "exemplo"], { cwd: repository })
  process.env.OPENCODE_BANCADA = "1"
  process.env.OPENCODE_BANCADA_STATE = path.join(root, "state")
  process.env.OPENCODE_BANCADA_CONFIG = path.join(root, "bancada.toml")
})

afterAll(async () => {
  Object.keys(process.env)
    .filter((name) => name.startsWith("OPENCODE_"))
    .forEach((name) => delete process.env[name])
  Object.entries(world.env ?? {}).forEach(([name, value]) => {
    if (value !== undefined) process.env[name] = value
  })
  if (!world.root) return
  const info = (await Bun.file(path.join(world.root, "state", "bancada.json"))
    .json()
    .catch(() => undefined)) as { pid: number } | undefined
  if (info && (await liveness(info.pid)).state !== "dead") process.kill(info.pid, "SIGTERM")
  if (info) await until(async () => (await liveness(info.pid)).state === "dead", 5_000).catch(() => undefined)
  await fs.rm(world.root, { recursive: true, force: true })
})

const it = testEffect(PluginTestLayer)

/** A shell tool that only says it ran: what is under test is whether the hook let the call reach it. */
const shell = {
  id: "test.shell",
  revision: "test",
  effect: (ctx: Context) =>
    ctx.tool
      .transform((editor) =>
        editor.add({
          name: "shell",
          description: "shell",
          input: ShellTool.Input,
          // Called directly, as the core's own shell tool is.
          options: { codemode: false },
          execute: () => Effect.succeed({ content: "rodou" }),
        }),
      )
      .pipe(Effect.orDie),
}

describe("the Bancada's hook in the plugin host", () => {
  it.live(
    "refuses a command the repository reserves, a phone without hold and another family's slot; lets the rest pass",
    () =>
      Effect.gen(function* () {
        const plugins = yield* Plugin.Service
        const modules = yield* PluginModule.make().pipe(Effect.provide(Watcher.testLayer))
        const custom = yield* modules.load({
          type: "add",
          target: path.join(import.meta.dir, "../src/index.ts"),
          options: {},
        })
        if ("pending" in custom || "blocked" in custom) throw new Error("the custom plugin was not loaded")
        yield* plugins.activate([shell, custom])
        const registry = yield* Tool.Service
        yield* waitForTool(registry, "bancada_hold")
        const sessions = yield* Session.Service
        const location = Location.Ref.make({ directory: AbsolutePath.make(path.join(world.root!, "projeto")) })
        const first = yield* sessions.create({ location, title: "Sessão de teste" })
        const second = yield* sessions.create({ location, title: "Outra" })
        let n = 0
        const run = (sessionID: typeof first.id, name: string, input: unknown) =>
          executeTool(registry, {
            sessionID,
            ...toolIdentity,
            call: { type: "tool-call", id: `call-${++n}`, name, input },
          }).pipe(
            Effect.map((result) =>
              result.status === "error"
                ? `recusado: ${result.error?.message}`
                : String(result.content?.[0]?.type === "text" ? result.content[0].text : ""),
            ),
          )
        const command = (sessionID: typeof first.id, text: string) =>
          run(sessionID, "shell", { command: text, description: "teste" })

        expect(yield* command(first.id, "git status")).toBe("rodou")
        expect(yield* command(first.id, "./scripts/por-fora")).toStartWith(
          "recusado: Neste repositório, `./scripts/por-fora` só roda pela Bancada. Use `bancada_run` com o teste `simples`",
        )
        expect(yield* command(first.id, "adb -s IBHUYT85ZTYH5XDM shell")).toBe(
          'recusado: Reserve antes com `bancada_hold({ aparelho: "poco" })`.',
        )
        expect(yield* run(first.id, "bancada_hold", { aparelho: "poco" })).toStartWith("Reserva r-")
        expect(yield* command(first.id, "adb -s IBHUYT85ZTYH5XDM shell")).toBe("rodou")
        expect(yield* command(first.id, "emulator -avd Pixel_Host -no-window")).toBe("rodou")
        expect(yield* command(second.id, "emulator -avd Pixel_Host")).toMatch(
          /^recusado: Pixel_Host está reservado para Sessão de teste \(em .+\); não use aparelho de outra sessão\.$/,
        )
        // Unloaded, the plugin stops asking its process for events: nothing starts it again after the test.
        yield* plugins.activate([shell])
      }),
    120_000,
  )
})

async function until(condition: () => Promise<boolean>, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(100)
  }
  throw new Error(`condition not met in ${ms} ms`)
}
