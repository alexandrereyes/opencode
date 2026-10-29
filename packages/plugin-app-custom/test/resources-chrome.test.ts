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
  namespaceOf,
  normalizeURL,
  parseProcesses,
  sameNamespace,
  shellEnvironment,
  writeConfig,
  type ChromeState,
} from "../src/resources/adapters/chrome"
import { size } from "../src/resources/adapters/process"
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
    expect(await locate("login", rows)).toEqual([
      { pid: 101, daemonPID: 100, userDataDir, port: 62417, headless: true },
    ])
    // A browser opened without the debugging port is found, but has no port to attach to.
    expect((await locate("other", rows))[0]?.port).toBeUndefined()
    // Chrome processes that no playwright-cli daemon launched are never candidates.
    expect(await locate("default", rows)).toEqual([])
  })

  test("tells same-named sessions apart by the playwright-cli namespace of the agent's directory", async () => {
    await using dir = await temporary()
    const scoped = path.join(dir.path, "scoped")
    const plain = path.join(dir.path, "plain", "repo")
    await fs.mkdir(path.join(scoped, ".playwright"), { recursive: true })
    await fs.mkdir(path.join(scoped, "packages", "app"), { recursive: true })
    await fs.mkdir(plain, { recursive: true })
    expect(namespaceOf(path.join(scoped, "packages", "app"))).toBe(scoped)
    expect(namespaceOf(plain)).toBe("")
    const rows = parseProcesses(
      [
        "  400     1 /usr/bin/node /x/lib/entry/cliDaemon.js default",
        "  401   400 /Applications/Chrome --user-data-dir=/tmp/one --remote-debugging-pipe",
        "  500     1 /usr/bin/node /x/lib/entry/cliDaemon.js default",
        "  501   500 /Applications/Chrome --user-data-dir=/tmp/two --remote-debugging-pipe",
      ].join("\n"),
    )
    // Daemon 400 started in the `.playwright` workspace; 500 (the newer PID) in a directory without one.
    const directories = async () =>
      new Map([
        [400, path.join(scoped, "packages")],
        [500, plain],
      ])
    const pick = async (workspace?: string) =>
      (await locate("default", rows, workspace, directories)).map((browser) => browser.pid)
    expect(await pick(path.join(scoped, "packages", "app"))).toEqual([401])
    // Any directory outside a `.playwright` workspace shares the global `default` session.
    expect(await pick(path.join(dir.path, "elsewhere"))).toEqual([501])
    // Without a known directory, two candidates are ambiguous rather than guessed.
    expect(await pick()).toEqual([401, 501])
    expect(sameNamespace(plain, path.join(dir.path, "elsewhere"))).toBe(true)
    expect(sameNamespace(plain, scoped)).toBe(false)
    expect(sameNamespace(undefined, scoped)).toBe(true)
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
       // Chrome keeps writing its profile while it shuts down; exit only after it has, so the test can remove it.
       process.on("SIGTERM", () => { chrome.kill(); void chrome.exited.then(() => process.exit(0)) })
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

const cli = live && Bun.which("playwright-cli") !== null

/**
 * Real `playwright-cli` sessions (desktop and an emulated iPhone), opened the way the plugin's shell hook makes agents
 * open them. Frame-rate and still checks count frames over a few seconds with wide margins: a regression to the
 * uncapped stream (about 44 fps on a spinner) or to stills on every caret blink (one every 500 ms) trips them.
 */
describe.skipIf(!cli)("playwright-cli sessions", () => {
  const prefix = `opencode-perf-${process.pid}`
  let dir: string
  let server: Bun.Server<undefined>
  const adapter = makeChromeAdapter()
  const at = Date.now()
  const entry = (session: string, workspace: string): Entry => ({
    id: `chrome:${session}`,
    kind: "chrome",
    meta: { kind: "chrome", session, workspace },
    status: "running",
    discoveredAt: at,
    lastUsedAt: at,
    updatedAt: at,
  })
  // Asynchronous: `open` waits for the page, which this process serves.
  const cliRun = (args: string[]) =>
    Bun.spawn(["playwright-cli", ...args], {
      cwd: dir,
      env: { ...process.env, PLAYWRIGHT_MCP_CONFIG: path.join(dir, "playwright-cli.json") },
      stdout: "ignore",
      stderr: "ignore",
    }).exited

  beforeAll(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), "chrome-perf-"))
    await writeConfig(path.join(dir, "playwright-cli.json"))
    server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (request) =>
        new Response(
          new URL(request.url).pathname === "/spin"
            ? `<style>@keyframes s { to { transform: rotate(360deg) } }</style><div style="width:120px;height:120px;border:12px solid #ccd;border-top-color:#1f6feb;border-radius:50%;animation:s 1s linear infinite"></div>`
            : `<meta name="viewport" content="width=device-width, initial-scale=1"><input id="email" autofocus style="width:90%;height:40px"><div style="height:4000px;background:linear-gradient(#fff,#888)"></div>`,
          { headers: { "content-type": "text/html; charset=utf-8" } },
        ),
    })
    await Promise.all([
      cliRun([`-s=${prefix}-desktop`, "open", "--browser=chrome", `http://127.0.0.1:${server.port}/spin`]),
      cliRun([
        `-s=${prefix}-phone`,
        "open",
        "--browser=chrome",
        "--device=iPhone 15",
        `http://127.0.0.1:${server.port}/`,
      ]),
    ])
  }, 60_000)

  // Four playwright-cli runs (close and delete-data per session) outlast the default 5 s hook on a loaded Mac.
  afterAll(async () => {
    await adapter.close()
    for (const name of ["desktop", "phone"]) {
      await cliRun([`-s=${prefix}-${name}`, "close"])
      await cliRun([`-s=${prefix}-${name}`, "delete-data"])
    }
    server?.stop(true)
    await fs.rm(dir, { recursive: true, force: true })
    // `delete-data` keeps the daemon's error logs; remove this run's.
    const daemons = path.join(os.homedir(), "Library", "Caches", "ms-playwright", "daemon")
    for (const hash of await fs.readdir(daemons).catch(() => [])) {
      const files = await fs.readdir(path.join(daemons, hash)).catch(() => [])
      await Promise.all(
        files
          .filter((file) => file.startsWith(`${prefix}-`))
          .map((file) => fs.rm(path.join(daemons, hash, file), { force: true })),
      )
    }
  }, 60_000)

  const evaluateIn = async (target: Entry, expression: string) => {
    const probed = (await adapter.probe([target])).get(target.id)
    if (probed?.meta?.kind !== "chrome") throw new Error("expected Chrome metadata")
    return evaluate(probed.meta, expression)
  }

  const watch = (target: Entry, options: { economy?: boolean; ready?: () => Promise<void> } = {}) => {
    const frames: { at: number; width: number }[] = []
    const states: ChromeState[] = []
    const controller = new AbortController()
    const sink: StreamSink = {
      profile: () => (options.economy ? "economy" : "standard"),
      whenReady: () => options.ready?.() ?? Promise.resolve(),
      hello: () => undefined,
      frame: (payload) => void frames.push({ at: Date.now(), width: size(payload)?.width ?? 0 }),
      // The Chrome adapter publishes exactly `ChromeState`.
      meta: (value) => void states.push(value as unknown as ChromeState),
    }
    const streaming = adapter.stream!(target, sink, controller.signal)
    const until = async (condition: () => boolean) => {
      const deadline = Date.now() + 15_000
      while (!condition()) {
        if (Date.now() > deadline) throw new Error(`timed out; last state ${JSON.stringify(states.at(-1))}`)
        await Bun.sleep(20)
      }
    }
    const stop = async () => {
      controller.abort()
      await streaming
    }
    return { frames, states, until, stop }
  }

  test(
    "a continuously repainting page streams near 15 fps, not at the page's rate",
    async () => {
      const view = watch(entry(`${prefix}-desktop`, dir))
      await view.until(() => view.frames.length > 0)
      await Bun.sleep(500)
      const from = Date.now()
      await Bun.sleep(3_000)
      const counted = view.frames.filter((frame) => frame.at >= from).length
      await view.stop()
      expect(counted).toBeGreaterThan(15)
      expect(counted).toBeLessThan(60)
    },
    { timeout: 30_000 },
  )

  test(
    "Chrome waits for the viewers before sending more, and the economy profile sends smaller, fewer frames",
    async () => {
      // A viewer that stops acknowledging: Chrome gets no screencast acks, so it stops after its three frames.
      let open = true
      let release = () => {}
      const view = watch(entry(`${prefix}-desktop`, dir), {
        ready: () => (open ? Promise.resolve() : new Promise<void>((resolve) => (release = resolve))),
      })
      await view.until(() => view.frames.length > 3)
      open = false
      await Bun.sleep(1_000)
      const stalled = view.frames.length
      await Bun.sleep(1_500)
      expect(view.frames.length - stalled).toBeLessThanOrEqual(1)
      open = true
      release()
      await view.until(() => view.frames.length > stalled + 5)
      await view.stop()

      const economy = watch(entry(`${prefix}-desktop`, dir), { economy: true })
      await economy.until(() => economy.frames.length > 0)
      await Bun.sleep(500)
      const from = Date.now()
      await Bun.sleep(3_000)
      const counted = economy.frames.filter((frame) => frame.at >= from)
      await economy.stop()
      expect(counted.length).toBeGreaterThan(10)
      expect(counted.length).toBeLessThan(40)
      expect(counted.every((frame) => frame.width <= 800)).toBe(true)
    },
    { timeout: 30_000 },
  )

  test(
    "a phone page shrinks frames while a finger scrolls, ends sharp, and refreshes a blinking caret sparingly",
    async () => {
      const target = entry(`${prefix}-phone`, dir)
      const view = watch(target)
      await view.until(() => view.states.at(-1)?.viewport !== undefined && view.frames.length > 0)
      const viewport = view.states.at(-1)!.viewport!
      expect(viewport.width).toBe(393)

      const from = view.frames.length
      await adapter.input!(target, { type: "touch", phase: "began", x: 0.5, y: 0.8 })
      for (let step = 1; step <= 15; step++) {
        await adapter.input!(target, { type: "touch", phase: "moved", x: 0.5, y: 0.8 - step * 0.04 })
        await Bun.sleep(40)
      }
      await adapter.input!(target, { type: "touch", phase: "ended", x: 0.5, y: 0.2 })
      // Motion frames are about half the viewport wide; the still after the scroll is twice the viewport.
      await view.until(() => view.frames.slice(from).some((frame) => frame.width <= viewport.width * 0.6))
      await view.until(() => (view.frames.at(-1)?.width ?? 0) >= viewport.width * 1.9)

      // The autofocused field blinks its caret every 500 ms; idle refreshes come at most every 2.5 s.
      await Bun.sleep(3_000)
      const idle = Date.now()
      await Bun.sleep(6_000)
      const refreshed = view.frames.filter((frame) => frame.at >= idle)
      expect(refreshed.length).toBeLessThanOrEqual(4)
      expect(refreshed.every((frame) => frame.width >= viewport.width * 1.9)).toBe(true)
      // Sharp stills come from Playwright, so the agent's emulated device survives them.
      const density = await evaluateIn(target, "[visualViewport.width, visualViewport.height, devicePixelRatio]")
      expect(density).toEqual([393, 659, 3])
      // Giving control back stops the Playwright stills: the agent's session is never kept waiting behind them.
      await adapter.released!(target)
      const released = view.frames.length
      // A repaint the agent causes (no input from the viewer).
      await evaluateIn(target, "(document.body.style.background = '#ddd', 1)")
      await Bun.sleep(2_000)
      expect(view.frames.slice(released).every((frame) => frame.width < viewport.width * 1.5)).toBe(true)
      await view.stop()
    },
    { timeout: 40_000 },
  )
})

/**
 * `attach --cdp=…` sessions (the default for Alexandre's own Chrome). An isolated headless Chrome with its own
 * debugging port and profile stands in for his browser: a "personal" tab opened before the agent attaches, and the
 * agent's tab opened by `tab-new`. The adapter reaches it only through the daemon's Playwright server.
 */
describe.skipIf(!cli)("attached playwright-cli sessions", () => {
  const session = `opencode-attach-${process.pid}`
  let dir: string
  let server: Bun.Server<undefined>
  let chrome: Bun.Subprocess
  let port = 0
  const adapter = makeChromeAdapter()
  const at = Date.now()
  const target = (): Entry => ({
    id: `chrome:${session}`,
    kind: "chrome",
    meta: { kind: "chrome", session, workspace: dir },
    status: "running",
    discoveredAt: at,
    lastUsedAt: at,
    updatedAt: at,
  })
  const cli = async (args: string[]) => {
    const child = Bun.spawn(["playwright-cli", `-s=${session}`, ...args], { cwd: dir, stdout: "pipe", stderr: "pipe" })
    const [out, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
    return { out, code }
  }

  beforeAll(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), "chrome-attach-"))
    server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (request) => {
        const name = new URL(request.url).pathname.slice(1)
        return new Response(
          `<title>${name}</title><input id="field" style="position:absolute;left:0;top:0;width:300px;height:60px">`,
          { headers: { "content-type": "text/html; charset=utf-8" } },
        )
      },
    })
    chrome = Bun.spawn(
      [
        chromePath,
        "--headless",
        "--remote-debugging-port=0",
        "--no-first-run",
        "--no-default-browser-check",
        `--user-data-dir=${path.join(dir, "profile")}`,
        `http://127.0.0.1:${server.port}/pessoal`,
      ],
      { stdout: "ignore", stderr: "ignore" },
    )
    const deadline = Date.now() + 15_000
    while (!port) {
      if (Date.now() > deadline) throw new Error("Chrome did not start")
      const contents = await Bun.file(path.join(dir, "profile", "DevToolsActivePort"))
        .text()
        .catch(() => "")
      port = Number.parseInt(contents.split("\n")[0] ?? "", 10) || 0
      await Bun.sleep(50)
    }
    expect((await cli(["attach", `--cdp=http://127.0.0.1:${port}`])).code).toBe(0)
    expect((await cli(["tab-new", `http://127.0.0.1:${server.port}/agente`])).code).toBe(0)
  }, 60_000)

  afterAll(async () => {
    await adapter.close()
    await cli(["detach"])
    chrome?.kill()
    await chrome?.exited
    server?.stop(true)
    await fs.rm(dir, { recursive: true, force: true })
    const daemons = path.join(os.homedir(), "Library", "Caches", "ms-playwright", "daemon")
    for (const hash of await fs.readdir(daemons).catch(() => [])) {
      const files = await fs.readdir(path.join(daemons, hash)).catch(() => [])
      await Promise.all(
        files
          .filter((file) => file.startsWith(session))
          .map((file) => fs.rm(path.join(daemons, hash, file), { force: true })),
      )
    }
  })

  test(
    "is running, streams only the agent's tab, takes input, follows the agent's tab and leaves the session working",
    async () => {
      expect((await adapter.probe([target()])).get(target().id)?.status).toBe("running")

      const frames: number[] = []
      const states: ChromeState[] = []
      const controller = new AbortController()
      const sink: StreamSink = {
        hello: () => undefined,
        frame: () => void frames.push(Date.now()),
        // The Chrome adapter publishes exactly `ChromeState`.
        meta: (value) => void states.push(value as unknown as ChromeState),
      }
      const streaming = adapter.stream!(target(), sink, controller.signal)
      const until = async (condition: () => boolean) => {
        const deadline = Date.now() + 20_000
        while (!condition()) {
          if (Date.now() > deadline) throw new Error(`timed out; last state ${JSON.stringify(states.at(-1))}`)
          await Bun.sleep(20)
        }
      }
      await until(() => frames.length > 0 && states.at(-1)?.title === "agente" && states.at(-1)?.viewport !== undefined)
      expect(states.at(-1)?.tabs.map((tab) => tab.title)).toEqual(["agente"])

      // The agent's session keeps working while the viewer streams.
      const title = await cli(["eval", "document.title"])
      expect(title.code).toBe(0)
      expect(title.out).toContain("agente")

      // Alexandre's input goes to the agent's tab.
      const viewport = states.at(-1)!.viewport!
      const point = { x: 100 / viewport.width, y: 30 / viewport.height }
      await adapter.input!(target(), { type: "touch", phase: "began", ...point })
      await adapter.input!(target(), { type: "touch", phase: "ended", ...point })
      await until(() => states.at(-1)?.focus.editable === true)
      await adapter.input!(target(), { type: "text", text: "olá" })
      const typed = async () => (await cli(["eval", "document.getElementById('field').value"])).out
      const deadline = Date.now() + 10_000
      while (!(await typed()).includes("olá") && Date.now() < deadline) await Bun.sleep(200)
      expect(await typed()).toContain("olá")

      // A new tab of the agent replaces the old one in the viewer; the personal tab never shows up.
      await cli(["tab-new", `http://127.0.0.1:${server.port}/agente2`])
      await until(() => states.at(-1)?.title === "agente2")
      expect(states.flatMap((state) => state.tabs.map((tab) => tab.title))).not.toContain("pessoal")
      expect(states.some((state) => state.title === "pessoal")).toBe(false)

      await adapter.released!(target())
      controller.abort()
      await streaming
      await adapter.close()
      expect((await cli(["eval", "document.title"])).out).toContain("agente2")
      // The browser itself is untouched by the relay disconnecting.
      expect((await fetch(`http://127.0.0.1:${port}/json/version`)).ok).toBe(true)
    },
    { timeout: 60_000 },
  )

  test(
    "is no longer running once the agent detaches",
    async () => {
      await cli(["detach"])
      expect((await adapter.probe([target()])).get(target().id)?.status).not.toBe("running")
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
