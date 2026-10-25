import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import {
  choose,
  decodeFocus,
  keyEvents,
  locate,
  makeChromeAdapter,
  modifiers,
  normalizeURL,
  parseProcesses,
  shellEnvironment,
  writeConfig,
  type ChromeState,
} from "../src/resources/adapters/chrome"
import type { Entry, StreamSink } from "../src/resources/adapters/types"
import type { Resources } from "../src/resources/rpc"

const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

describe("locating the browser of a playwright-cli session", () => {
  test("follows the daemon of the session to its Chrome child and reads its CDP port", async () => {
    await using dir = await temporary()
    const userDataDir = path.join(dir.path, "profile")
    await fs.mkdir(userDataDir)
    await Bun.write(path.join(userDataDir, "DevToolsActivePort"), "62417\n/devtools/browser/abc\n")
    const rows = parseProcesses(
      [
        "  100     1 /opt/homebrew/bin/node /x/playwright-core/lib/entry/cliDaemon.js login --browser=chrome",
        "  200     1 /opt/homebrew/bin/node /x/playwright-core/lib/entry/cliDaemon.js other",
        `  101   100 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --remote-debugging-port=0 --user-data-dir=${userDataDir} --remote-debugging-pipe`,
        `  102   101 /Applications/Google Chrome.app/Contents/Frameworks/Helper --type=renderer --user-data-dir=${userDataDir}`,
        "  201   200 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/elsewhere --remote-debugging-pipe",
        "  300     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222",
      ].join("\n"),
    )
    expect(await locate("login", rows)).toEqual({
      pid: 101,
      daemonPID: 100,
      userDataDir,
      port: 62417,
      headless: true,
    })
    // A browser opened without the debugging port is found, but has no port to attach to.
    expect((await locate("other", rows))?.port).toBeUndefined()
    // Chrome processes that no playwright-cli daemon launched are never candidates.
    expect(await locate("default", rows)).toBeUndefined()
  })

  test("agent shells get the CDP config unless they chose one", async () => {
    await using dir = await temporary()
    const file = path.join(dir.path, "nested", "playwright-cli.json")
    await writeConfig(file)
    expect(await Bun.file(file).json()).toEqual({ browser: { launchOptions: { args: ["--remote-debugging-port=0"] } } })
    const env: Record<string, string | undefined> = { PATH: "/bin" }
    shellEnvironment(env, file)
    expect(env.PLAYWRIGHT_MCP_CONFIG).toBe(file)
    const chosen: Record<string, string | undefined> = { PLAYWRIGHT_MCP_CONFIG: "/mine.json" }
    shellEnvironment(chosen, file)
    expect(chosen.PLAYWRIGHT_MCP_CONFIG).toBe("/mine.json")
  })
})

describe("viewer helpers", () => {
  test("follows the chosen tab, else the newest page with content", () => {
    const pages = [
      { targetId: "a", url: "http://localhost:5173/login" },
      { targetId: "b", url: "https://example.com/" },
      { targetId: "c", url: "about:blank" },
    ]
    expect(choose(pages, "a")?.targetId).toBe("a")
    expect(choose(pages, "gone")?.targetId).toBe("b")
    expect(choose([{ targetId: "c", url: "about:blank" }])?.targetId).toBe("c")
  })

  test("normalizes typed addresses", () => {
    expect(normalizeURL("localhost:5173/login")).toBe("http://localhost:5173/login")
    expect(normalizeURL("127.0.0.1:8080")).toBe("http://127.0.0.1:8080")
    expect(normalizeURL(" example.com/a ")).toBe("https://example.com/a")
    expect(normalizeURL("https://abacato.app")).toBe("https://abacato.app")
    expect(normalizeURL("about:blank")).toBe("about:blank")
  })

  test("maps keys to CDP events", () => {
    expect(keyEvents("Enter", 0)[0]).toMatchObject({
      type: "keyDown",
      code: "Enter",
      text: "\r",
      windowsVirtualKeyCode: 13,
    })
    expect(keyEvents("Backspace", 0)[0]).toMatchObject({
      type: "rawKeyDown",
      code: "Backspace",
      windowsVirtualKeyCode: 8,
    })
    expect(keyEvents("a", modifiers(["meta"]))[0]).toMatchObject({ type: "rawKeyDown", code: "KeyA", modifiers: 4 })
    expect(keyEvents("7", 0)[0]).toMatchObject({ type: "keyDown", code: "Digit7", text: "7" })
    expect(keyEvents("Tab", modifiers(["shift"])).map((event) => event.type)).toEqual(["rawKeyDown", "keyUp"])
  })

  test("accepts only known focus fields and never a value", () => {
    expect(decodeFocus({ editable: true, field: "password", value: "x" })).toEqual({
      editable: true,
      field: "password",
    })
    expect(decodeFocus({ editable: true, field: "weird" })).toEqual({ editable: true, field: "text" })
    expect(decodeFocus({ editable: false })).toEqual({ editable: false })
    expect(decodeFocus(undefined)).toEqual({ editable: false })
  })
})

const live = process.platform === "darwin" && (await Bun.file(chromePath).exists())

describe.skipIf(!live)("a real headless Chrome", () => {
  const session = `opencode-test-${process.pid}`
  let dir: string
  let daemon: Bun.Subprocess
  let server: Bun.Server<undefined>
  const adapter = makeChromeAdapter()

  beforeAll(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), "chrome-resource-"))
    server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (request) =>
        new Response(
          new URL(request.url).pathname === "/next"
            ? `<title>Próxima</title><h1>Próxima</h1>`
            : `<title>Entrar</title><input id="email" type="email" autocomplete="username" style="position:absolute;left:0;top:0;width:200px;height:40px">
               <input id="password" type="password" style="position:absolute;left:0;top:60px;width:200px;height:40px">
               <div style="height:4000px"></div>`,
          { headers: { "content-type": "text/html; charset=utf-8" } },
        ),
    })
    // Same process tree as playwright-cli: a `cliDaemon.js <session>` parent launching Chrome with a CDP port.
    const script = path.join(dir, "cliDaemon.js")
    await Bun.write(
      script,
      `const chrome = Bun.spawn(${JSON.stringify([chromePath, "--headless", "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", `--user-data-dir=${path.join(dir, "profile")}`, "--window-size=400,600"])}.concat([process.argv[3]]), { stdout: "ignore", stderr: "ignore" })
       process.on("SIGTERM", () => { chrome.kill(); process.exit(0) })
       await chrome.exited`,
    )
    daemon = Bun.spawn([process.execPath, script, session, `http://127.0.0.1:${server.port}/`], {
      stdout: "ignore",
      stderr: "ignore",
    })
    const deadline = Date.now() + 15_000
    while (!(await Bun.file(path.join(dir, "profile", "DevToolsActivePort")).exists())) {
      if (Date.now() > deadline) throw new Error("Chrome did not start")
      await Bun.sleep(50)
    }
  })

  afterAll(async () => {
    await adapter.close()
    daemon?.kill()
    await daemon?.exited
    server?.stop(true)
    await fs.rm(dir, { recursive: true, force: true })
  })

  test(
    "streams frames and applies taps, text, keys, scroll and navigation",
    async () => {
      const at = Date.now()
      const entry: Entry = {
        id: `chrome:${session}`,
        kind: "chrome",
        meta: { kind: "chrome", session },
        status: "running",
        discoveredAt: at,
        lastUsedAt: at,
        updatedAt: at,
      }
      const probed = (await adapter.probe([entry])).get(entry.id)
      expect(probed?.status).toBe("running")
      expect(probed?.meta).toMatchObject({ kind: "chrome", session, url: `http://127.0.0.1:${server.port}/` })

      // A browser registered by its CDP endpoint alone is attached directly.
      if (probed?.meta?.kind !== "chrome") throw new Error("expected Chrome metadata")
      const byEndpoint: Entry = { ...entry, id: "chrome:endpoint", meta: { kind: "chrome", cdp: probed.meta.cdp } }
      expect((await adapter.probe([byEndpoint])).get(byEndpoint.id)).toMatchObject({
        status: "running",
        meta: { cdp: probed.meta.cdp, targetID: probed.meta.targetID },
      })
      expect((await adapter.snapshot(byEndpoint)).mime).toBe("image/jpeg")

      const snapshot = await adapter.snapshot(entry)
      expect(snapshot.mime).toBe("image/jpeg")
      expect(snapshot.width).toBeGreaterThan(0)

      const frames: Uint8Array[] = []
      const states: ChromeState[] = []
      const sink: StreamSink = {
        hello: () => undefined,
        frame: (payload) => void frames.push(payload),
        // The Chrome adapter publishes exactly `ChromeState`.
        meta: (value) => void states.push(value as unknown as ChromeState),
      }
      const controller = new AbortController()
      const streaming = adapter.stream!(entry, sink, controller.signal)
      const until = async (condition: () => boolean) => {
        const deadline = Date.now() + 10_000
        while (!condition()) {
          if (Date.now() > deadline) throw new Error(`timed out; last state ${JSON.stringify(states.at(-1))}`)
          await Bun.sleep(20)
        }
      }
      await until(() => frames.length > 0 && states.at(-1)?.viewport !== undefined)
      const viewport = states.at(-1)!.viewport!
      const point = (x: number, y: number) => ({ x: x / viewport.width, y: y / viewport.height })
      const tap = async (x: number, y: number) => {
        await adapter.input!(entry, { type: "touch", phase: "began", ...point(x, y) })
        await adapter.input!(entry, { type: "touch", phase: "ended", ...point(x, y) })
      }

      await tap(100, 20)
      await until(() => states.at(-1)?.focus.field === "username")
      await adapter.input!(entry, { type: "text", text: "alexandre@abacato.app" })
      const taps = states.at(-1)!.editTaps
      await tap(100, 80)
      await until(() => states.at(-1)?.focus.field === "password")
      // Tapping the focused field again tells the viewer to reopen its keyboard.
      await tap(100, 80)
      await until(() => states.at(-1)!.editTaps === taps + 2)
      await adapter.input!(entry, { type: "text", text: "s3cr3t" })
      await adapter.input!(entry, { type: "key", key: "Backspace" })
      const values = await evaluate(probed!.meta!, "[email.value, password.value.length, scrollY]")
      expect(values).toEqual(["alexandre@abacato.app", 5, 0])

      const scrolled = async (above: number) => {
        const deadline = Date.now() + 5_000
        const read = async () => (await evaluate(probed!.meta!, "scrollY")) as number
        while ((await read()) <= above && Date.now() < deadline) await Bun.sleep(20)
        return read()
      }
      await adapter.input!(entry, { type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 0.5 })
      const wheel = await scrolled(0)
      expect(wheel).toBeGreaterThan(0)
      // A finger drag on this mouse-only page scrolls instead of selecting text, and does not click.
      await adapter.input!(entry, { type: "touch", phase: "began", ...point(300, 500) })
      await adapter.input!(entry, { type: "touch", phase: "moved", ...point(300, 400) })
      await adapter.input!(entry, { type: "touch", phase: "moved", ...point(300, 300) })
      await adapter.input!(entry, { type: "touch", phase: "ended", ...point(300, 300) })
      expect(await scrolled(wheel)).toBeGreaterThan(wheel)
      expect(await evaluate(probed!.meta!, "String(getSelection())")).toBe("")

      await adapter.input!(entry, { type: "navigate", action: "url", url: `127.0.0.1:${server.port}/next` })
      await until(() => states.at(-1)?.title === "Próxima" && states.at(-1)?.canGoBack === true)
      await adapter.input!(entry, { type: "navigate", action: "back" })
      await until(() => states.at(-1)?.title === "Entrar" && states.at(-1)?.canGoForward === true)
      expect(states.at(-1)?.tabs.map((tab) => tab.title)).toEqual(["Entrar"])

      // A second tab appears in the list and the viewer can follow it.
      const first = states.at(-1)!.targetID
      const opened = await createTab(probed!.meta!, `http://127.0.0.1:${server.port}/next`)
      await until(() => states.at(-1)!.tabs.some((tab) => tab.id === opened))
      const before = frames.length
      await adapter.input!(entry, { type: "navigate", action: "tab", target: opened })
      await until(
        () => states.at(-1)?.targetID === opened && states.at(-1)?.title === "Próxima" && frames.length > before,
      )
      await adapter.input!(entry, { type: "navigate", action: "tab", target: first })
      await until(() => states.at(-1)?.targetID === first && states.at(-1)?.title === "Entrar")

      controller.abort()
      await streaming
    },
    { timeout: 30_000 },
  )
})

async function evaluate(meta: Resources.Meta, expression: string) {
  if (meta.kind !== "chrome" || !meta.cdp || !meta.targetID) throw new Error("no CDP target")
  const { CDP } = await import("../src/resources/adapters/cdp")
  const version: { webSocketDebuggerUrl: string } = await (await fetch(`${meta.cdp}/json/version`)).json()
  const cdp = await CDP.connect(version.webSocketDebuggerUrl)
  try {
    const attached = await cdp.send("Target.attachToTarget", { targetId: meta.targetID, flatten: true })
    const result = await cdp.send(
      "Runtime.evaluate",
      {
        expression: `(() => { const email = document.getElementById("email"); const password = document.getElementById("password"); return ${expression} })()`,
        returnByValue: true,
      },
      attached.sessionId,
    )
    return result.result.value
  } finally {
    await cdp.close()
  }
}

async function createTab(meta: Resources.Meta, url: string) {
  if (meta.kind !== "chrome" || !meta.cdp) throw new Error("no CDP endpoint")
  const { CDP } = await import("../src/resources/adapters/cdp")
  const version: { webSocketDebuggerUrl: string } = await (await fetch(`${meta.cdp}/json/version`)).json()
  const cdp = await CDP.connect(version.webSocketDebuggerUrl)
  try {
    return (await cdp.send("Target.createTarget", { url })).targetId
  } finally {
    await cdp.close()
  }
}

async function temporary() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "chrome-resource-"))
  return { path: directory, [Symbol.asyncDispose]: () => fs.rm(directory, { recursive: true, force: true }) }
}
