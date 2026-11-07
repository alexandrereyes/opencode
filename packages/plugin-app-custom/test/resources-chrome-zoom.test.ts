import { afterEach, expect, test } from "bun:test"
import { browserZoom, makeChromeAdapter, settings } from "../src/resources/adapters/chrome"
import { entryOf, fakeBrowser, watch } from "./fixture/fake-chrome"

/**
 * Chrome's browser zoom (Alexandre's runs at 125 %): screencast frames come in device-independent pixels while input
 * takes CSS pixels. The mapping lives in the adapter's `Live`, shared by every way it reaches a browser:
 * `playwright-cli` sessions (headless or headed), attached ones (`attach --cdp=chrome`) and browse handoffs.
 */

const zoomCheckMs = settings.zoomCheckMs
const stops: (() => unknown)[] = []
afterEach(async () => {
  settings.zoomCheckMs = zoomCheckMs
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
  const chrome = fakeBrowser({})
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
