import { afterEach, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { callTool, RelayError, relayPort, relayTokenFile } from "../src/resources/adapters/browse-relay"
import { makeChromeAdapter } from "../src/resources/adapters/chrome"
import { browseSettings } from "../src/resources/adapters/chrome-browse"
import { createHub, type Lock } from "../src/resources/hub/hub"
import { browseEntry, fakeRelay, handoffEntry, token, useRelay } from "./fixture/fake-browse"
import { watch } from "./fixture/fake-chrome"

/**
 * The Chrome adapter's browse mode (`docs/browse-handoff-remoto.md`, rev. 2026-11-22) and its relay client against a
 * fake browse 0.1.5 relay, which lists every agent's tabs to every caller: a resource's own tabs and nothing else,
 * frames polled from `screenshot`, input through browse's tools, and the token kept out of every message.
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
const B = "mcp-bbbb0002"
/** A's tabs are 10 and 12 (14 is a popup 10 opened); B's is 13 (16 its popup); 11 is lent and 15 the CLI's. */
const relayTabs = () => [
  { tab: 10, url: "http://127.0.0.1:5191/", title: "Entrar · Abacato", lastUsed: "2026-11-22T10:00:00Z" },
  { tab: 11, url: "https://mail.example/", title: "Caixa de entrada", lent: true },
  { tab: 12, url: "http://127.0.0.1:5191/ajuda", title: "Ajuda", id: "ajuda", lastUsed: "2026-11-22T10:05:00Z" },
  { tab: 13, url: "https://banco.example/extrato", title: "Extrato · Banco do Alexandre", group: "banco" },
  { tab: 14, url: "https://login.example/oauth", title: "Login", opener: 10 },
  { tab: 15, url: "https://cli.example/", title: "CLI" },
  { tab: 16, url: "https://banco.example/pix", title: "Pix", opener: 13 },
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

test("a call goes with a key of its own; tool errors, a refused token and no relay fail apart", async () => {
  const fake = await relay()
  fake.state.tabs = relayTabs()
  await callTool("tabs", { action: "list" })
  expect(fake.calls).toEqual([{ name: "tabs", arguments: { action: "list" } }])
  expect(fake.keys[0]).toMatch(/^[0-9a-f-]{36}$/)
  // A tab that went away: the tool's own refusal.
  const refused = await callTool("click", { tab: 99, x: 1, y: 1 }).catch((error: unknown) => error)
  expect(refused).toBeInstanceOf(RelayError)
  expect(refused).toMatchObject({ reason: "tool", message: "Tab 99 is gone." })
  // An aborted call is stopped at the relay too (which takes down a card it shows).
  fake.state.hold.add("handoff")
  const controller = new AbortController()
  const waiting = callTool("handoff", { tab: 10, message: "x" }, { signal: controller.signal }).catch(
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
  const wrong = (await callTool("tabs", {}).catch((error: unknown) => error)) as RelayError
  expect(wrong.reason).toBe("refused")
  expect(wrong.message).not.toContain("not-the-token")
  expect(wrong.message).not.toContain(token)
  await Bun.write(fake.tokenFile, `${token}\n`)
  // No relay listening: down, which the probe reads as stopped.
  fake.server.stop(true)
  expect(await callTool("tabs", {}).catch((error: unknown) => error)).toMatchObject({ reason: "down" })
})

test("one list per probe: each resource keeps its own tabs and their popups, never another's, and tells gone from stopped", async () => {
  const fake = await relay()
  fake.state.tabs = relayTabs()
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const a = browseEntry({ browse: A, targetID: "10" }, [10, 12])
  const b = browseEntry({ browse: B, targetID: "13" }, [13])
  const both = await adapter.probe([a, b])
  expect(fake.calls).toEqual([{ name: "tabs", arguments: { action: "list" } }])
  expect(both.get(a.id)).toEqual({
    status: "running",
    meta: {
      kind: "chrome",
      browse: A,
      cdp: fake.endpoint,
      targetID: "10",
      url: "http://127.0.0.1:5191/",
      title: "Entrar · Abacato",
    },
    // The popup its tab opened joins it; the lent tab, B's and the CLI's never do.
    tabs: [{ tab: 10 }, { tab: 12, id: "ajuda" }, { tab: 14 }],
  })
  expect(both.get(b.id)).toMatchObject({ meta: { targetID: "13" }, tabs: [{ tab: 13, group: "banco" }, { tab: 16 }] })
  const probe = async (entry: ReturnType<typeof browseEntry>) => (await adapter.probe([entry])).get(entry.id)
  // Its tab closed: the one of its own a call used last.
  expect(await probe(browseEntry({ browse: A, targetID: "99" }, [10, 12, 99]))).toMatchObject({
    meta: { targetID: "12" },
    tabs: [{ tab: 10 }, { tab: 12, id: "ajuda" }, { tab: 14 }],
  })
  // A popup another resource holds stays its.
  const held = await adapter.probe([a, browseEntry({ browse: "mcp-cccc0003", targetID: "14" }, [14])])
  expect(held.get(a.id)?.tabs).toEqual([{ tab: 10 }, { tab: 12, id: "ajuda" }])
  // An entry from before rev. 2026-11-22 holds the tab it followed.
  expect((await probe(browseEntry({ browse: A, targetID: "12" })))?.tabs).toEqual([{ tab: 12, id: "ajuda" }])
  // While a handoff waits only its tab counts.
  expect((await probe(handoffEntry({ browse: A, targetID: "10" }, [10, 12])))?.meta).toMatchObject({ targetID: "10" })
  expect((await probe(handoffEntry({ browse: A, targetID: "99" }, [12, 99])))?.status).toBe("stopped")

  // None of its tabs open is gone while a browser is connected; with none (asleep, restarting) its tabs stay.
  expect(await probe(browseEntry({ browse: A, targetID: "98" }, [98]))).toEqual({ status: "gone", tabs: [] })
  fake.state.tabs = []
  fake.state.connected = false
  expect(await probe(a)).toEqual({ status: "stopped" })
  // No relay says nothing about the tabs.
  fake.server.stop(true)
  expect(await probe(a)).toEqual({ status: "stopped" })

  // A tab a registration names, by integer or chosen id, followed by its integer once the relay lists it.
  const live = await relay()
  live.state.tabs = relayTabs()
  expect(await adapter.identify!({ kind: "chrome", browse: A, targetID: "ajuda" })).toEqual({
    kind: "chrome",
    browse: A,
    targetID: "12",
    cdp: live.endpoint,
    url: "http://127.0.0.1:5191/ajuda",
    title: "Ajuda",
  })
  expect(await adapter.identify!({ kind: "chrome", browse: A, targetID: "13" })).toMatchObject({ targetID: "13" })
  await expect(adapter.identify!({ kind: "chrome", browse: A, targetID: "inbox" })).rejects.toThrow(
    "A aba do handoff não está aberta.",
  )
})

test("the viewer gets frames in CSS pixels, the page's state and its own tabs; input goes through browse's tools", async () => {
  Object.assign(browseSettings, { controlledMs: 10, watchingMs: 10, stateMs: 0, holdMs: 60_000 })
  const fake = await relay()
  fake.state.tabs = relayTabs()
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
  const entry = browseEntry({ browse: A, targetID: "10" }, [10, 12])
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
  // Another of its tabs from the tab menu; never another session's, nor a lent or CLI tab it does not hold.
  for (const target of ["13", "11", "15", "12"])
    await adapter.input!(entry, { type: "navigate", action: "tab", target })
  await viewer.until(
    () => viewer.states.at(-1)?.targetID === "12" && fake.named("screenshot").at(-1)?.arguments.tab === 12,
  )
  expect(new Set(fake.calls.map((call) => call.arguments.tab).filter((tab) => tab !== undefined))).toEqual(
    new Set([10, 12]),
  )
  // The resource gains a tab (the hub tells the view): Alexandre's pick stays, and the tab menu shows it.
  const grown = { ...entry, tabs: [{ tab: 10 }, { tab: 12 }, { tab: 14 }] }
  await adapter.update!(grown)
  await viewer.until(() => viewer.states.at(-1)?.tabs.length === 3)
  expect(viewer.states.at(-1)?.targetID).toBe("12")
  // His pick goes to another session: the view follows the resource's tab again.
  await adapter.update!({ ...grown, tabs: [{ tab: 10 }, { tab: 14 }] })
  await viewer.until(() => viewer.states.at(-1)?.targetID === "10" && viewer.states.at(-1)?.tabs.length === 2)
  expect(JSON.stringify(viewer.states)).not.toContain(token)
  // "Abrir no Chrome": browse brings no tab forward, so focus fails and the Mac app selects the tab itself.
  await expect(adapter.focus!(entry)).rejects.toThrow("O browse não traz abas para a frente")
})

test("while a handoff waits the viewer keeps to its tab, cannot navigate, and ends when that tab closes", async () => {
  Object.assign(browseSettings, { controlledMs: 10, watchingMs: 10, stateMs: 0 })
  const fake = await relay()
  fake.state.tabs = relayTabs()
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const free = browseEntry({ browse: A, targetID: "12" }, [10, 12])
  const viewer = watch(adapter, free)
  stops.push(() => viewer.stop())
  await viewer.until(() => viewer.states.at(-1)?.tabs.length === 2)
  // A handoff starts on tab 10 (the hub calls `update` with the entry's handoff and locks): only that tab, no navigation.
  const locked = handoffEntry({ browse: A, targetID: "10" }, [10, 12])
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

  // Without a handoff, a followed tab that closes gives way to the one of its own a call used last.
  fake.state.tabs = relayTabs()
  await adapter.forget!(free)
  const other = watch(adapter, browseEntry({ browse: A, targetID: "12" }, [10, 12, 15]))
  stops.push(() => other.stop())
  await other.until(() => other.states.at(-1)?.targetID === "12")
  // 10 was used; 15, newer, never was.
  fake.state.tabs = fake.state.tabs.filter((tab) => tab.tab !== 12)
  await other.until(() => other.states.at(-1)?.targetID === "10")
  expect((await adapter.snapshot(free)).mime).toBe("image/jpeg")
  expect(fake.named("screenshot").filter((call) => call.arguments.quality === 80)).toEqual([
    { name: "screenshot", arguments: { tab: 10, format: "jpeg", quality: 80, scale: "css" } },
  ])
})

/** The real hub and Chrome adapter over the fake relay, as the plugin registers sessions' browse calls. */
async function hubOver(fake: Awaited<ReturnType<typeof relay>>, file: string) {
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const hub = createHub({
    adapters: { "ios-simulator": adapter, "android-emulator": adapter, chrome: adapter },
    secret: "hub-secret",
    file,
    machine: async () => undefined,
  })
  stops.push(() => hub.close())
  const use = (browse: string, targetID: string) =>
    hub.register({ kind: "chrome", meta: { kind: "chrome", cdp: fake.endpoint, browse, targetID }, used: true })
  const held = (browse: string) =>
    hub.entries
      .get(`chrome:browse:${browse}`)
      ?.tabs?.map((item) => item.tab)
      .toSorted((a, b) => a - b)
  const followed = (browse: string) => {
    const meta = hub.entries.get(`chrome:browse:${browse}`)?.meta
    return meta?.kind === "chrome" ? meta.targetID : undefined
  }
  return { hub, use, held, followed }
}

test("sessions sharing the relay: each resource holds the tabs its calls named or opened, and a tab is one's at a time", async () => {
  const fake = await relay()
  fake.state.tabs = relayTabs()
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "browse-tabs-"))
  stops.push(() => fs.rm(directory, { recursive: true, force: true }))
  const file = path.join(directory, "resources.json")
  const { hub, use, held, followed } = await hubOver(fake, file)
  await use(A, "10")
  // A chosen id is followed, and held, as browse's integer.
  await use(A, "ajuda")
  await use(B, "13")
  await hub.probe(["chrome"])
  expect([held(A), followed(A)]).toEqual([[10, 12, 14], "12"])
  expect([held(B), followed(B)]).toEqual([[13, 16], "13"])
  // B uses A's tab: it moves to B, which follows it; A keeps the rest.
  await use(B, "10")
  await hub.probe(["chrome"])
  expect([held(A), followed(A)]).toEqual([[12, 14], "12"])
  expect([held(B), followed(B)]).toEqual([[10, 13, 16], "10"])
  // A chosen id the relay does not list changes nothing.
  await use(A, "inbox")
  expect([held(A), followed(A)]).toEqual([[12, 14], "12"])

  // While Alexandre controls A the hub's locks name its tabs, for the plugin to refuse every session's calls on them.
  await hub.control(`chrome:browse:${A}`, "take")
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  stops.push(() => server.stop(true))
  const locks = (await fetch(`http://127.0.0.1:${server.port}/admin/locks`, {
    headers: { authorization: "Bearer hub-secret" },
  }).then((response) => response.json())) as { locks: Lock[] }
  expect(locks.locks.map((lock) => lock.tabs)).toEqual([[{ tab: 12, id: "ajuda" }, { tab: 14 }]])

  // Tabs survive a restart of the hub.
  const deadline = Date.now() + 5_000
  while (
    !(
      await Bun.file(file)
        .text()
        .catch(() => "")
    ).includes('"tab":10') &&
    Date.now() < deadline
  )
    await Bun.sleep(20)
  const restarted = await hubOver(fake, file)
  await restarted.hub.start()
  expect(restarted.held(B)).toEqual([10, 13, 16])
})

test("registrations while a probe runs are kept: their tabs stay, and a resource they gave a tab is not removed", async () => {
  const fake = await relay()
  fake.state.tabs = [...relayTabs(), { tab: 98, url: "https://loja.example/", title: "Loja" }]
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "browse-tabs-"))
  stops.push(() => fs.rm(directory, { recursive: true, force: true }))
  const { hub, use, held, followed } = await hubOver(fake, path.join(directory, "resources.json"))
  await use(A, "98")
  await use(B, "10")
  await hub.probe(["chrome"])
  // A's only tab closes, and a probe starts: it will find A gone and B as it was. Meanwhile A names 12 and B 13.
  fake.state.tabs = relayTabs()
  fake.state.hold.add("tabs")
  const lists = fake.named("tabs").length
  const probing = hub.probe(["chrome"])
  const deadline = Date.now() + 5_000
  while (fake.named("tabs").length === lists && Date.now() < deadline) await Bun.sleep(5)
  await use(A, "12")
  await use(B, "13")
  fake.release()
  await probing
  await hub.probe(["chrome"])
  expect([held(A), followed(A)]).toEqual([[12], "12"])
  expect([held(B), followed(B)]).toEqual([[10, 13, 14, 16], "13"])
})
