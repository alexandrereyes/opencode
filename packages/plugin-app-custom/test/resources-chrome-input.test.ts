import { afterEach, expect, test } from "bun:test"
import { blockedNotice, browserZoom, makeChromeAdapter, settings } from "../src/resources/adapters/chrome"
import { entryOf, fakeBrowser, watch } from "./fixture/fake-chrome"

/**
 * Input on a CDP Chrome (`Live`, shared by `playwright-cli` sessions, headless or headed, and attached ones): Chrome's
 * browser zoom (Alexandre's runs at 125 %), where screencast frames come in device-independent pixels while input takes
 * CSS pixels, and taps Chrome drops.
 */

const timing = { zoom: settings.zoomCheckMs, check: settings.inputCheckMs, notice: settings.blockedNoticeMs }
const stops: (() => unknown)[] = []
afterEach(async () => {
  settings.zoomCheckMs = timing.zoom
  settings.inputCheckMs = timing.check
  settings.blockedNoticeMs = timing.notice
  await Promise.all(stops.splice(0).map((stop) => stop()))
})

test("browser zoom maps touches in CSS pixels, also for playwright-cli browsers; other mismatches do not count", async () => {
  expect(browserZoom({ deviceWidth: 1400, deviceHeight: 771 }, 1120, 616.8)).toBeCloseTo(1.25, 5)
  expect(browserZoom({ deviceWidth: 393, deviceHeight: 659 }, 393, 659)).toBe(1)
  // A window larger than an emulated viewport (`fitWindow`) is not a zoom.
  expect(browserZoom({ deviceWidth: 500, deviceHeight: 572 }, 393, 659)).toBe(1)
  expect(browserZoom({ deviceWidth: 500, deviceHeight: 572 }, undefined, 0)).toBe(1)

  // A playwright-cli Chrome registered by its CDP endpoint (the same `Live` as named sessions and attached ones).
  settings.zoomCheckMs = 0
  const chrome = fakeBrowser()
  stops.push(() => chrome.server.stop(true))
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const entry = entryOf({ kind: "chrome", cdp: chrome.cdp }, "chrome:endpoint")
  const viewer = watch(adapter, entry)
  stops.push(() => viewer.stop())
  await viewer.until(() => viewer.states.at(-1)?.viewport !== undefined)
  const tap = async (x: number, y: number) => {
    chrome.sent.length = 0
    await adapter.input!(entry, { type: "touch", phase: "began", x, y })
    await adapter.input!(entry, { type: "touch", phase: "ended", x, y })
    const pressed = chrome.sent.find(
      (item) => item.method === "Input.dispatchMouseEvent" && item.params.type === "mousePressed",
    )
    return [pressed?.params.x, pressed?.params.y]
  }
  // Zoomed 125 %: CSS pixels.
  expect(await tap(1, 1)).toEqual([1120, 616.8])
  // Not zoomed: the frame's size, as before.
  chrome.view.inner = [1400, 771]
  expect(await tap(1, 1)).toEqual([1400, 771])
  // An emulated viewport smaller than the window it is shown in: unchanged too.
  chrome.view.inner = [1000, 900]
  expect(await tap(0.5, 0.5)).toEqual([700, 385.5])
})

/**
 * Chrome ignores every input to a tab while a dialog of its own covers it: after a login with a password found in a
 * data breach (the test site's tomsmith / SuperSecretPassword!), its password manager's warning blocks the page, the
 * remote viewer cannot see it and taps seemed to do nothing (2026-11-08). A tap the page never received now says why.
 */
test("a tap Chrome drops tells the viewers that a Chrome dialog covers the page, once per interval", async () => {
  const chrome = fakeBrowser()
  stops.push(() => chrome.server.stop(true))
  settings.inputCheckMs = 200
  settings.blockedNoticeMs = 60_000
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const entry = entryOf({ kind: "chrome", cdp: chrome.cdp }, "chrome:endpoint")
  const viewer = watch(adapter, entry)
  stops.push(() => viewer.stop())
  await viewer.until(() => viewer.states.at(-1)?.viewport !== undefined)
  const tap = async () => {
    await adapter.input!(entry, { type: "touch", phase: "began", x: 0.5, y: 0.5 })
    await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.5, y: 0.5 })
    await Bun.sleep(500)
  }
  await tap()
  expect(chrome.view.delivered).toBe(1)
  expect(viewer.notices).toEqual([])
  // A tap on an embedded document (a captcha, an OAuth or 3-D Secure frame) reaches it, never the main frame's count:
  // it is not checked.
  chrome.view.iframes.push({ x: 400, y: 200, width: 320, height: 240 })
  await tap()
  expect(chrome.view.delivered).toBe(1)
  expect(viewer.notices).toEqual([])
  chrome.view.iframes.length = 0
  // A drag scrolls instead of clicking: nothing to check.
  chrome.view.blocked = true
  await adapter.input!(entry, { type: "touch", phase: "began", x: 0.2, y: 0.5 })
  await adapter.input!(entry, { type: "touch", phase: "moved", x: 0.2, y: 0.8 })
  await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.2, y: 0.8 })
  await Bun.sleep(500)
  expect(viewer.notices).toEqual([])
  await tap()
  expect(viewer.notices).toEqual([blockedNotice])
  await tap()
  expect(viewer.notices).toEqual([blockedNotice])
  // The count is read in an isolated world, never the page's own.
  const reads = chrome.sent.filter((item) => item.method === "Runtime.evaluate" && item.params.contextId === 7)
  expect(reads.length).toBeGreaterThan(0)
  expect(chrome.sent.filter((item) => item.method === "Page.createIsolatedWorld")[0]?.params).toEqual({
    frameId: "TAB1",
    worldName: "opencode-input-check",
  })
})
