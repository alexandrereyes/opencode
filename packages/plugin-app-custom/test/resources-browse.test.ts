import { afterEach, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { callTool, RelayError, relayPort, relayTokenFile } from "../src/resources/adapters/browse-relay"
import { makeChromeAdapter } from "../src/resources/adapters/chrome"
import { browseSettings } from "../src/resources/adapters/chrome-browse"
import { browseEntry, fakeRelay, handoffEntry, token, useRelay } from "./fixture/fake-browse"
import { watch } from "./fixture/fake-chrome"

/**
 * The Chrome adapter's browse mode (`docs/browse-handoff-remoto.md`, rev. 2026-11-16) and its relay client against a
 * fake browse 0.1.0 relay: an owner's tabs and nothing else, frames polled from `screenshot`, input through browse's
 * tools, and the token kept out of every message.
 */

const saved = { ...browseSettings }
const stops: (() => unknown)[] = []
afterEach(async () => {
  Object.assign(browseSettings, saved)
  for (const stop of stops.splice(0).toReversed()) await stop()
})

async function relay() {
  const fake = await fakeRelay()
  stops.push(fake.stop)
  stops.push(useRelay(fake))
  return fake
}

const A = "mcp-aaaa0001"
const tabsOf = (owner: string) => [
  { tab: 10, url: "http://127.0.0.1:5191/", title: "Entrar · Abacato", owner },
  { tab: 11, url: "https://mail.example/", title: "Caixa de entrada", lent: true },
  { tab: 12, url: "http://127.0.0.1:5191/ajuda", title: "Ajuda", owner },
  { tab: 13, url: "https://banco.example/extrato", title: "Extrato · Banco do Alexandre", owner: "mcp-bbbb0002" },
]

test("the relay client finds the relay's port and token where browse keeps them", async () => {
  const home = os.homedir()
  expect(relayTokenFile({})).toBe(path.join(home, ".local/share/browse/relay-token"))
  expect(relayTokenFile({ XDG_DATA_HOME: "/x/data" })).toBe("/x/data/browse/relay-token")
  expect(relayTokenFile({ XDG_DATA_HOME: "relative" })).toBe(path.join(home, ".local/share/browse/relay-token"))
  expect(relayTokenFile({ OPENCODE_BROWSER_HOME: "/x/browse", XDG_DATA_HOME: "/x/data" })).toBe("/x/browse/relay-token")
  expect(relayTokenFile({ OPENCODE_BROWSE_RELAY_TOKEN_FILE: "/x/token" })).toBe("/x/token")

  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "browse-state-"))
  stops.push(() => fs.rm(directory, { recursive: true, force: true }))
  const state = (pid: number) =>
    Bun.write(
      path.join(directory, "relays/19988/relay.json"),
      JSON.stringify({ port: 19993, configuredPort: 19988, pid, instanceId: "x", startedAt: "y" }),
    )
  const env = { OPENCODE_BROWSER_HOME: directory }
  expect(await relayPort(env)).toBe(19988)
  // A relay that found 19988 taken moved to a fallback port and said so; a dead one's record is ignored.
  await state(process.pid)
  expect(await relayPort(env)).toBe(19993)
  await state(999_999)
  expect(await relayPort(env)).toBe(19988)
  // OPENCODE_BROWSER_PORT pins it, as for browse's own clients.
  expect(await relayPort({ ...env, OPENCODE_BROWSER_PORT: "19995" })).toBe(19995)
})

test("a call goes as its owner with a key of its own; tool errors, a refused token and no relay fail apart", async () => {
  const fake = await relay()
  fake.state.tabs = tabsOf(A)
  await callTool(A, "tabs", { action: "list" })
  expect(fake.calls).toEqual([{ name: "tabs", arguments: { action: "list" }, owner: A }])
  expect(fake.keys[0]).toMatch(/^[0-9a-f-]{36}$/)
  // Another owner's tab: the tool's own refusal.
  const refused = await callTool(A, "click", { tab: 13, x: 1, y: 1 }).catch((error: unknown) => error)
  expect(refused).toBeInstanceOf(RelayError)
  expect(refused).toMatchObject({ reason: "tool", message: "Tab 13 isn't a browse tab you can use." })
  // An aborted call is stopped at the relay too (which takes down a card it shows).
  fake.state.hold.add("handoff")
  const controller = new AbortController()
  const waiting = callTool(A, "handoff", { tab: 10, message: "x" }, { signal: controller.signal }).catch(
    (error: unknown) => error,
  )
  const deadline = Date.now() + 5_000
  while (fake.named("handoff").length === 0 && Date.now() < deadline) await Bun.sleep(5)
  controller.abort()
  expect(await waiting).toMatchObject({ reason: "cancelled" })
  while (fake.cancelled.length === 0 && Date.now() < deadline) await Bun.sleep(5)
  expect(fake.cancelled).toEqual([fake.keys.at(-1)!])

  // A wrong token: refused, and no message carries either token.
  await Bun.write(fake.tokenFile, "not-the-token\n")
  const wrong = (await callTool(A, "tabs", {}).catch((error: unknown) => error)) as RelayError
  expect(wrong.reason).toBe("refused")
  expect(wrong.message).not.toContain("not-the-token")
  expect(wrong.message).not.toContain(token)
  await Bun.write(fake.tokenFile, `${token}\n`)
  // No relay listening: down, which the probe reads as stopped.
  fake.server.stop(true)
  expect(await callTool(A, "tabs", {}).catch((error: unknown) => error)).toMatchObject({ reason: "down" })
})

test("the probe follows the resource's tab among its owner's, never another owner's, and tells gone from stopped", async () => {
  const fake = await relay()
  fake.state.tabs = tabsOf(A)
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const probe = async (entry: ReturnType<typeof browseEntry>) => (await adapter.probe([entry])).get(entry.id)
  expect(await probe(browseEntry({ browse: A, targetID: "10" }))).toEqual({
    status: "running",
    meta: {
      kind: "chrome",
      browse: A,
      cdp: fake.endpoint,
      targetID: "10",
      url: "http://127.0.0.1:5191/",
      title: "Entrar · Abacato",
    },
  })
  // Its tab closed (or none yet): the owner's newest, never a lent one nor another owner's.
  expect((await probe(browseEntry({ browse: A, targetID: "99" })))?.meta).toMatchObject({ targetID: "12" })
  expect((await probe(browseEntry({ browse: A })))?.meta).toMatchObject({ targetID: "12" })
  // A lent tab the agent works in is followed.
  expect((await probe(browseEntry({ browse: A, targetID: "11" })))?.meta).toMatchObject({ targetID: "11" })
  // While a handoff waits only its tab counts.
  expect((await probe(handoffEntry({ browse: A, targetID: "10" })))?.meta).toMatchObject({ targetID: "10" })
  expect((await probe(handoffEntry({ browse: A, targetID: "99" })))?.status).toBe("stopped")
  // Every list went as the owner, and nothing of another owner's came out.
  expect(fake.calls.every((call) => call.owner === A)).toBe(true)
  // One list per owner and probe.
  fake.calls.length = 0
  await adapter.probe([browseEntry({ browse: A, targetID: "10" }), { ...browseEntry({ browse: A }), id: "other" }])
  expect(fake.calls).toHaveLength(1)

  // An owner without tabs is gone while a browser is connected; with none (asleep, restarting) only stopped.
  expect((await probe(browseEntry({ browse: "mcp-cccc0003" })))?.status).toBe("gone")
  fake.state.connected = false
  expect((await probe(browseEntry({ browse: "mcp-cccc0003" })))?.status).toBe("stopped")
  // No relay says nothing about the tabs.
  fake.server.stop(true)
  expect((await probe(browseEntry({ browse: A, targetID: "10" })))?.status).toBe("stopped")

  // A handoff's resource is the call's own tab, as its owner sees it.
  const live = await relay()
  live.state.tabs = tabsOf(A)
  expect(await adapter.identify!({ kind: "chrome", browse: A, targetID: "12" })).toEqual({
    kind: "chrome",
    browse: A,
    targetID: "12",
    cdp: live.endpoint,
    url: "http://127.0.0.1:5191/ajuda",
    title: "Ajuda",
  })
  await expect(adapter.identify!({ kind: "chrome", browse: A, targetID: "13" })).rejects.toThrow(
    "A aba do handoff não está aberta.",
  )
})

test("the viewer gets frames in CSS pixels, the page's state and its owner's tabs; input goes through browse's tools", async () => {
  Object.assign(browseSettings, { controlledMs: 10, watchingMs: 10, stateMs: 0, holdMs: 60_000 })
  const fake = await relay()
  fake.state.tabs = tabsOf(A)
  // A page browse scaled down to half (past its 8000 px limit): frames are half the CSS size.
  fake.state.view = { width: 1280, height: 800, scale: 0.5 }
  fake.state.page = {
    url: "http://127.0.0.1:5191/",
    title: "Entrar · Abacato",
    canGoBack: true,
    canGoForward: false,
    focus: { editable: false },
  }
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const entry = browseEntry({ browse: A, targetID: "10" })
  const viewer = watch(adapter, entry)
  stops.push(() => viewer.stop())
  await viewer.until(() => viewer.frames.length > 0 && viewer.states.at(-1)?.url !== "")
  expect(viewer.states.at(-1)).toEqual({
    url: "http://127.0.0.1:5191/",
    title: "Entrar · Abacato",
    canGoBack: true,
    canGoForward: false,
    targetID: "10",
    tabs: [
      { id: "10", title: "Entrar · Abacato", url: "http://127.0.0.1:5191/" },
      { id: "12", title: "Ajuda", url: "http://127.0.0.1:5191/ajuda" },
    ],
    focus: { editable: false },
    editTaps: 0,
    viewport: { width: 1280, height: 800 },
  })
  // An unchanged page is not sent again.
  const shots = fake.named("screenshot").length
  await viewer.until(() => fake.named("screenshot").length >= shots + 3)
  expect(viewer.frames).toHaveLength(1)
  fake.state.frame = "frame-2"
  await viewer.until(() => viewer.frames.length === 2)
  expect(fake.named("screenshot").at(-1)?.arguments).toEqual({ tab: 10, format: "jpeg", quality: 70, scale: "css" })

  // A tap clicks in CSS pixels; on a field it tells the viewer to open the keyboard.
  fake.state.page = { ...fake.state.page, focus: { editable: true, field: "password" } }
  await adapter.input!(entry, { type: "touch", phase: "began", x: 0.5, y: 0.25 })
  await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.5, y: 0.25 })
  expect(fake.named("click").map((call) => call.arguments)).toEqual([{ tab: 10, x: 640, y: 200 }])
  await viewer.until(() => viewer.states.at(-1)?.editTaps === 1)
  expect(viewer.states.at(-1)?.focus).toEqual({ editable: true, field: "password" })
  // A finger that moves scrolls the page the other way, like a phone browser; held first, it drags.
  await adapter.input!(entry, { type: "touch", phase: "began", x: 0.5, y: 0.5 })
  await adapter.input!(entry, { type: "touch", phase: "moved", x: 0.5, y: 0.4 })
  await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.5, y: 0.4 })
  browseSettings.holdMs = 0
  await adapter.input!(entry, { type: "touch", phase: "began", x: 0.1, y: 0.1 })
  await adapter.input!(entry, { type: "touch", phase: "moved", x: 0.3, y: 0.1 })
  await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.3, y: 0.1 })
  expect(fake.named("scroll").map((call) => call.arguments)).toEqual([{ tab: 10, deltaX: 0, deltaY: 80 }])
  expect(fake.named("drag").map((call) => call.arguments)).toEqual([
    { tab: 10, from: { x: 128, y: 80 }, to: { x: 384, y: 80 } },
  ])
  expect(fake.named("click")).toHaveLength(1)
  // A trackpad's flood of wheel events becomes one call per turn, with their deltas summed.
  fake.state.hold.add("scroll")
  for (const dy of [0.1, 0.1, 0.05]) await adapter.input!(entry, { type: "scroll", x: 0.5, y: 0.5, dx: 0, dy })
  const held = Date.now() + 5_000
  while (fake.named("scroll").length < 2 && Date.now() < held) await Bun.sleep(5)
  await adapter.input!(entry, { type: "scroll", x: 0.5, y: 0.5, dx: 0.01, dy: 0 })
  fake.release()
  await viewer.until(() => fake.named("scroll").length === 3)
  expect(fake.named("scroll").map((call) => call.arguments)).toEqual([
    { tab: 10, deltaX: 0, deltaY: 80 },
    { tab: 10, deltaX: 0, deltaY: 80 },
    { tab: 10, deltaX: 12.8, deltaY: 120 },
  ])
  // Keys, text and navigation.
  await adapter.input!(entry, { type: "key", key: "a", modifiers: ["meta", "shift"] })
  await adapter.input!(entry, { type: "key", key: "Enter" })
  await adapter.input!(entry, { type: "text", text: "senha-falsa" })
  await adapter.input!(entry, { type: "navigate", action: "url", url: "127.0.0.1:5191/ajuda" })
  await adapter.input!(entry, { type: "navigate", action: "reload" })
  await adapter.input!(entry, { type: "button", button: "back" })
  expect(fake.named("press").map((call) => call.arguments)).toEqual([
    { tab: 10, key: "Meta+Shift+a" },
    { tab: 10, key: "Enter" },
  ])
  expect(fake.named("type").map((call) => call.arguments)).toEqual([{ tab: 10, text: "senha-falsa" }])
  expect(fake.named("navigate").map((call) => call.arguments)).toEqual([
    { tab: 10, url: "http://127.0.0.1:5191/ajuda", waitUntil: "commit" },
    { tab: 10, action: "reload", waitUntil: "commit" },
    { tab: 10, action: "back", waitUntil: "commit" },
  ])
  // Another of the owner's tabs from the tab menu; never another owner's, nor a lent tab it does not follow.
  await adapter.input!(entry, { type: "navigate", action: "tab", target: "13" })
  await adapter.input!(entry, { type: "navigate", action: "tab", target: "11" })
  await adapter.input!(entry, { type: "navigate", action: "tab", target: "12" })
  await viewer.until(
    () => viewer.states.at(-1)?.targetID === "12" && fake.named("screenshot").at(-1)?.arguments.tab === 12,
  )
  expect(new Set(fake.calls.map((call) => call.arguments.tab).filter((tab) => tab !== undefined))).toEqual(
    new Set([10, 12]),
  )
  expect(fake.calls.every((call) => call.owner === A)).toBe(true)
  expect(JSON.stringify(viewer.states)).not.toContain(token)
  // "Abrir no Chrome": browse brings no tab forward, so focus fails and the Mac app selects the tab itself.
  await expect(adapter.focus!(entry)).rejects.toThrow("O browse não traz abas para a frente")
})

test("while a handoff waits the viewer keeps to its tab, cannot navigate, and ends when that tab closes", async () => {
  Object.assign(browseSettings, { controlledMs: 10, watchingMs: 10, stateMs: 0 })
  const fake = await relay()
  fake.state.tabs = tabsOf(A)
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const free = browseEntry({ browse: A, targetID: "12" })
  const viewer = watch(adapter, free)
  stops.push(() => viewer.stop())
  await viewer.until(() => viewer.states.at(-1)?.tabs.length === 2)
  // A handoff starts on tab 10 (the hub calls `update` with the entry's handoff and locks): only that tab, no navigation.
  const locked = handoffEntry({ browse: A, targetID: "10" })
  await adapter.update!(locked)
  await viewer.until(
    () => viewer.states.at(-1)?.targetID === "10" && fake.named("screenshot").at(-1)?.arguments.tab === 10,
  )
  expect(viewer.states.at(-1)?.tabs.map((tab) => tab.id)).toEqual(["10"])
  const navigations = fake.named("navigate").length
  for (const action of ["url", "back", "forward", "reload", "tab"] as const)
    await expect(
      adapter.input!(locked, { type: "navigate", action, url: "https://example.com", target: "12" }),
    ).rejects.toThrow("not_allowed")
  await expect(adapter.input!(locked, { type: "button", button: "back" })).rejects.toThrow("not_allowed")
  expect(fake.named("navigate")).toHaveLength(navigations)
  // Touches still go to its page: Continue is a click on the card.
  await adapter.input!(locked, { type: "touch", phase: "began", x: 0.95, y: 0.9 })
  await adapter.input!(locked, { type: "touch", phase: "ended", x: 0.95, y: 0.9 })
  expect(fake.named("click").at(-1)?.arguments).toEqual({ tab: 10, x: 1216, y: 720 })
  // The handoff's tab closing ends the stream: it has no replacement.
  fake.state.tabs = fake.state.tabs.filter((tab) => tab.tab !== 10)
  expect(await viewer.streaming).toEqual(new Error("A aba do handoff foi fechada."))

  // Without a handoff, a followed tab that closes gives way to the owner's newest.
  fake.state.tabs = tabsOf(A)
  await adapter.forget!(free)
  const other = watch(adapter, free)
  stops.push(() => other.stop())
  await other.until(() => other.states.at(-1)?.targetID === "12")
  fake.state.tabs = fake.state.tabs.filter((tab) => tab.tab !== 12)
  await other.until(() => other.states.at(-1)?.targetID === "10")
  expect((await adapter.snapshot(free)).mime).toBe("image/jpeg")
  expect(fake.named("screenshot").filter((call) => call.arguments.quality === 80)).toEqual([
    { name: "screenshot", arguments: { tab: 10, format: "jpeg", quality: 80, scale: "css" }, owner: A },
  ])
})
