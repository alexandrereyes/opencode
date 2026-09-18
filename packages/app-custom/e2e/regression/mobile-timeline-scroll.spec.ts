import { devices, expect, test, type Page } from "@playwright/test"
import {
  assistantMessage,
  partDelta,
  partUpdated,
  renderedPartID,
  setupTimeline,
  shell,
  textPart,
  userMessage,
} from "../performance/timeline-stability/fixture"

// Ported from upstream 81523d4a8. Chromium drives native touch input,
// including the virtualizer's iOS user-agent path.
test.use({ colorScheme: "light", launchOptions: { args: ["--disable-features=ResamplingScrollEvents"] } })

for (const device of ["Pixel 7", "iPhone 13"]) {
  test.describe(device, () => {
    test.use({
      isMobile: true,
      hasTouch: true,
      userAgent: devices[device].userAgent,
      viewport: { width: 390, height: 844 },
    })

    test("reversing a touch drag stops following streamed output", async ({ page }) => {
      const partID = "prt_mobile_stream"
      const content = Array.from({ length: 60 }, (_, index) => `Reading earlier output ${index}.\n\n`).join("")
      const timeline = await setupTimeline(page, {
        messages: [userMessage(), assistantMessage([textPart(partID, content)], { completed: false })],
        viewport: { width: 390, height: 844 },
      })
      const scroller = page
        .locator('[data-slot="session-timeline-scroll"]')
        .getByRole("region", { name: "scrollable content", exact: true })
      const part = page.locator(`[data-timeline-part-id="${renderedPartID(partID)}"]`)
      const anchor = part.getByText("Reading earlier output 59.", { exact: true })
      await page.evaluate(() => document.fonts.ready)
      await expect(scroller.locator("[data-timeline-virtual-content]")).toBeVisible()
      await expect(anchor).toBeInViewport()
      const bounds = (await scroller.boundingBox())!
      const devtools = await page.context().newCDPSession(page)
      const x = bounds.x + bounds.width / 3
      const y = bounds.y + bounds.height * 0.75
      await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
      for (let step = 1; step <= 12; step++)
        await devtools.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y - step * 10 }] })
      for (let step = 1; step <= 8; step++)
        await devtools.send("Input.dispatchTouchEvent", {
          type: "touchMove",
          touchPoints: [{ x, y: y - 120 + step * 10 }],
        })
      const before = (await anchor.boundingBox())!
      await timeline.send(
        partUpdated(textPart(partID, `${content}New streamed output.\n\n${"More output.\n\n".repeat(10)}`)),
      )
      await expect(part).toContainText("New streamed output.")
      await expect(part.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
      await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
      expect((await anchor.boundingBox())?.y).toBeCloseTo(before.y, 0)
    })

    for (const imageCount of [1, 2]) {
      test(`keeps the reading anchor when ${imageCount} earlier images load during a drag`, async ({
        page,
      }, testInfo) => {
        const image = Promise.withResolvers<void>()
        const url = new URL("/mobile-scroll-images.svg", testInfo.project.use.baseURL).href
        await page.route(url, async (route) => {
          await image.promise
          await route.fulfill({
            contentType: "image/svg+xml",
            body: '<svg xmlns="http://www.w3.org/2000/svg" width="340" height="600"><rect width="340" height="600" fill="steelblue"/></svg>',
          })
        })
        await setupTimeline(page, {
          messages: [
            userMessage(),
            assistantMessage(
              Array.from({ length: 6 }, (_, index) =>
                textPart(
                  `prt_images_${index}`,
                  index < imageCount
                    ? `Image ${index}.\n\n![Image ${index}](${url})`
                    : index < 2
                      ? "Earlier context."
                      : Array.from({ length: 12 }, (_, line) => `Part ${index} line ${line}.`).join("\n\n"),
                ),
              ),
              { completed: false },
            ),
          ],
          viewport: { width: 390, height: 844 },
        })
        const reading = await readFrom(page, "Part 2 line 0.")
        const images = Array.from({ length: imageCount }, (_, index) =>
          page.getByAltText(`Image ${index}`, { exact: true }),
        )
        const rows = images.map((image) => reading.scroller.locator("[data-timeline-key]", { has: image }))
        const heights = await Promise.all(
          rows.map((row) => row.evaluate((element) => element.getBoundingClientRect().height)),
        )
        const before = await reading.anchor.evaluate((element) => element.getBoundingClientRect().top)
        const bounds = (await reading.scroller.boundingBox())!
        const devtools = await page.context().newCDPSession(page)
        await devtools.send("Input.dispatchTouchEvent", {
          type: "touchStart",
          touchPoints: [{ x: bounds.x + 120, y: bounds.y + 5 }],
        })
        image.resolve()
        for (const [index, row] of rows.entries()) {
          await expect(images[index]).toHaveJSProperty("naturalHeight", 600)
          await expect
            .poll(() => row.evaluate((element) => element.getBoundingClientRect().height))
            .toBe(heights[index] + 600)
        }
        expect(await reading.anchor.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(before, 0)
        for (let step = 1; step <= 21; step++) {
          await devtools.send("Input.dispatchTouchEvent", {
            type: "touchMove",
            touchPoints: [{ x: bounds.x + 120, y: bounds.y + 5 + step * 30 }],
          })
          await expect
            .poll(() => reading.anchor.evaluate((element) => element.getBoundingClientRect().top))
            .toBeCloseTo(before + step * 30 - 15, 0)
        }
        await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
        await expect(reading.timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        // Native momentum may continue after release. Each held movement above
        // is exact; release must not move the reading anchor against the gesture.
        expect(await reading.anchor.evaluate((element) => element.getBoundingClientRect().top)).toBeGreaterThanOrEqual(
          before + 614.5,
        )
        await reading.scroller.press("Home")
        await expect(reading.scroller.locator('[data-timeline-row="UserMessage"]')).toBeInViewport()
        await reading.scroller.press("End")
        await expect(page.getByText("Part 5 line 11.", { exact: true })).toBeInViewport()
      })
    }

    for (const release of ["touchEnd", "touchCancel"] as const) {
      test(`reconciles after streaming replaces the touch target (${release})`, async ({ page }, testInfo) => {
        const image = Promise.withResolvers<void>()
        const url = new URL("/stream-target-image.svg", testInfo.project.use.baseURL).href
        await page.route(url, async (route) => {
          await image.promise
          await route.fulfill({
            contentType: "image/svg+xml",
            body: '<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300"><rect width="300" height="300" fill="steelblue"/></svg>',
          })
        })
        const fixture = await setupTimeline(page, {
          messages: [
            userMessage(),
            assistantMessage(
              [
                textPart(
                  "prt_target_prefix",
                  Array.from({ length: 60 }, (_, index) => `Prefix ${index}.`).join("\n\n"),
                ),
                textPart("prt_target_image", `Earlier image.\n\n![Delayed image](${url})`),
                textPart(
                  "prt_target_reading",
                  Array.from({ length: 25 }, (_, index) => `Reading ${index}.`).join("\n\n"),
                ),
                textPart("prt_target_heading", "Heading text"),
              ],
              { completed: false },
            ),
          ],
          viewport: { width: 390, height: 844 },
        })
        const timeline = page.locator('[data-slot="session-timeline-scroll"]')
        const scroller = timeline.getByRole("region", { name: "scrollable content", exact: true })
        const heading = page.locator(`[data-timeline-part-id="${renderedPartID("prt_target_heading")}"]`)
        await expect(timeline.locator("[data-timeline-virtual-content]")).toBeVisible()
        await expect(heading).toBeInViewport()
        await page.evaluate(() => document.fonts.ready)
        await expect(timeline.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
        await scroller.evaluate((element) => {
          element.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }))
          element.scrollTop = 0
        })
        const first = scroller.locator('[data-timeline-row="UserMessage"]')
        await expect(first).toBeInViewport()
        const start = await first.evaluate((element) => element.getBoundingClientRect().top)
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        await scroller.evaluate((element) => (element.scrollTop = element.scrollHeight))
        await expect(heading).toBeInViewport()
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        const bounds = (await heading.getByText("Heading text", { exact: true }).boundingBox())!
        const point = { x: bounds.x + 25, y: bounds.y + bounds.height / 2 }
        const target = await page.evaluateHandle((point) => document.elementFromPoint(point.x, point.y), point)
        const devtools = await page.context().newCDPSession(page)
        await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [point] })
        await devtools.send("Input.dispatchTouchEvent", {
          type: "touchMove",
          touchPoints: [{ x: point.x, y: point.y + 60 }],
        })
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="true"]')).toHaveCount(1)
        await fixture.send(partDelta("prt_target_heading", "\n\nMore content."))
        await expect(heading).toContainText("More content.")
        await expect(heading.locator("p")).toHaveCount(2)
        await expect.poll(() => target.evaluate((element) => element?.isConnected)).toBe(false)
        await devtools.send("Input.dispatchTouchEvent", { type: release, touchPoints: [] })
        await target.dispose()
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        const anchor = page.getByText("Reading 20.", { exact: true })
        await expect(anchor).toBeInViewport()
        const before = await anchor.evaluate((element) => element.getBoundingClientRect().top)
        image.resolve()
        const loaded = page.getByAltText("Delayed image", { exact: true })
        await expect(loaded).toHaveJSProperty("naturalHeight", 300)
        await expect
          .poll(() =>
            scroller
              .locator("[data-timeline-key]", { has: loaded })
              .evaluate((element) => element.getBoundingClientRect().height),
          )
          .toBeGreaterThan(300)
        await expect
          .poll(() => anchor.evaluate((element) => element.getBoundingClientRect().top))
          .toBeCloseTo(before, 0)
        await scroller.press("Home")
        await expect(first).toBeInViewport()
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        expect(await first.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(start, 0)
      })
    }

    for (const navigation of ["Home", "End", "latest", "scrollbar"] as const) {
      test(`${navigation} takes over a pending touch adjustment`, async ({ page }) => {
        const fixture = await setupTimeline(page, {
          messages: [
            userMessage(),
            assistantMessage(
              [
                textPart("prt_handoff_prefix", Array.from({ length: 40 }, (_, i) => `Prefix ${i}.`).join("\n\n")),
                shell("prt_handoff_shell", "running", "A short."),
                textPart("prt_handoff_reading", Array.from({ length: 60 }, (_, i) => `Reading ${i}.`).join("\n\n")),
              ],
              { completed: false },
            ),
          ],
          settings: { shellToolPartsExpanded: true },
          viewport: { width: 390, height: 844 },
        })
        const timeline = page.locator('[data-slot="session-timeline-scroll"]')
        const scroller = timeline.getByRole("region", { name: "scrollable content", exact: true })
        await expect(timeline.locator("[data-timeline-virtual-content]")).toBeVisible()
        await expect(page.getByText("Reading 59.", { exact: true })).toBeInViewport()
        await page.evaluate(() => document.fonts.ready)
        await scroller.evaluate((element) => {
          element.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }))
          element.scrollTop = 0
        })
        const first = scroller.locator('[data-timeline-row="UserMessage"]')
        await expect(first).toBeInViewport()
        const start = await first.evaluate((element) => element.getBoundingClientRect().top)
        await expect(page.getByText("Prefix 39.", { exact: true })).toBeAttached()
        await expect(timeline.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
        await scroller.evaluate(
          (element, distance) => (element.scrollTop = element.scrollHeight - element.clientHeight - distance),
          navigation === "latest" ? 800 : 80,
        )
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        const latest = page.getByRole("button", { name: "Jump to latest", exact: true })
        if (navigation === "latest") await expect(latest.locator("..")).toHaveCSS("opacity", "1")
        const row = scroller.locator("[data-timeline-key]", {
          has: page.locator(`[data-timeline-part-id="${renderedPartID("prt_handoff_shell")}"]`),
        })
        const height = await row.evaluate((element) => element.getBoundingClientRect().height)
        const extent = await scroller.evaluate((element) => element.scrollHeight)
        const bounds = (await scroller.boundingBox())!
        const devtools = await page.context().newCDPSession(page)
        await devtools.send("Input.dispatchTouchEvent", {
          type: "touchStart",
          touchPoints: [{ x: bounds.x + 100, y: bounds.y + 200 }],
        })
        await devtools.send("Input.dispatchTouchEvent", {
          type: "touchMove",
          touchPoints: [{ x: bounds.x + 100, y: bounds.y + 230 }],
        })
        await fixture.send(
          partUpdated(
            shell(
              "prt_handoff_shell",
              "running",
              Array.from({ length: 10 }, (_, i) => `Shell line ${i}.`).join("\n\n"),
            ),
          ),
        )
        await expect
          .poll(() => row.evaluate((element) => element.getBoundingClientRect().height))
          .toBeGreaterThan(height)
        // The row has grown while the native extent remains compensated. Navigate
        // with the finger still held so an idle callback cannot reconcile first.
        await expect.poll(() => scroller.evaluate((element) => element.scrollHeight)).toBe(extent)
        if (navigation === "Home" || navigation === "End") await scroller.press(navigation)
        if (navigation === "latest") await latest.click()
        if (navigation === "scrollbar") {
          const thumb = timeline.locator('.scroll-view__thumb[data-orientation="vertical"]')
          await thumb.hover()
          const grip = (await thumb.boundingBox())!
          const anchor = page.getByText("Reading 50.", { exact: true })
          const before = await anchor.evaluate((element) => element.getBoundingClientRect().top)
          await page.mouse.down()
          expect(await anchor.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(before, 0)
          await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2 - 4)
          await expect
            .poll(() => anchor.evaluate((element) => element.getBoundingClientRect().top))
            .toBeGreaterThan(before)
          expect((await anchor.evaluate((element) => element.getBoundingClientRect().top)) - before).toBeLessThan(60)
          await page.mouse.move(grip.x + grip.width / 2, bounds.y + 5)
          await page.mouse.up()
          await page.mouse.move(0, 0)
        }
        const destination =
          navigation === "Home" || navigation === "scrollbar" ? first : page.getByText("Reading 59.", { exact: true })
        await expect(destination).toBeInViewport()
        await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
        await expect(timeline.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        await expect(destination).toBeInViewport()
        if (navigation === "Home" || navigation === "scrollbar")
          expect(await first.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(start, 0)
      })
    }

    for (const nestedStart of [500, 0]) {
      test(`nested output owns the gesture or chains at its boundary (${nestedStart})`, async ({ page }) => {
        const timeline = await setupTimeline(page, {
          messages: [
            userMessage(),
            assistantMessage(
              [
                shell(
                  "prt_nested",
                  "completed",
                  Array.from({ length: 120 }, (_, index) => `Output line ${index}`).join("\n"),
                ),
                textPart("prt_nested_tail", "Latest output."),
              ],
              { completed: false },
            ),
          ],
          settings: { shellToolPartsExpanded: true },
          seedHistory: true,
          viewport: { width: 390, height: 844 },
        })
        const root = page.locator('[data-slot="session-timeline-scroll"]')
        const nested = page.locator(`[data-timeline-part-id="${renderedPartID("prt_nested")}"] [data-scrollable]`)
        const tail = page.getByText("Latest output.", { exact: true })
        await expect(root.locator("[data-timeline-virtual-content]")).toBeVisible()
        await expect(tail).toBeInViewport()
        await page.evaluate(() => document.fonts.ready)
        await nested.evaluate((element, top) => (element.scrollTop = top), nestedStart)
        await expect(nested).toHaveJSProperty("scrollTop", nestedStart)
        const before = await tail.evaluate((element) => element.getBoundingClientRect().top)
        const bounds = (await nested.boundingBox())!
        const x = bounds.x + 100
        const y = bounds.y + bounds.height * (nestedStart ? 0.75 : 0.25)
        const devtools = await page.context().newCDPSession(page)
        await devtools.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] })
        if (nestedStart) {
          for (let step = 1; step <= 12; step++)
            await devtools.send("Input.dispatchTouchEvent", {
              type: "touchMove",
              touchPoints: [{ x, y: y - step * 10 }],
            })
          await expect.poll(() => nested.evaluate((element) => element.scrollTop)).toBeGreaterThan(550)
          const far = await nested.evaluate((element) => element.scrollTop)
          for (let step = 1; step <= 6; step++)
            await devtools.send("Input.dispatchTouchEvent", {
              type: "touchMove",
              touchPoints: [{ x, y: y - 120 + step * 10 }],
            })
          await expect.poll(() => nested.evaluate((element) => element.scrollTop)).toBeLessThan(far)
          expect(await tail.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(before, 0)
        }
        if (!nestedStart) {
          for (let step = 1; step <= 12; step++)
            await devtools.send("Input.dispatchTouchEvent", {
              type: "touchMove",
              touchPoints: [{ x, y: y + step * 10 }],
            })
          await expect
            .poll(() => tail.evaluate((element) => element.getBoundingClientRect().top))
            .toBeGreaterThan(before + 50)
        }
        await devtools.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
        await expect(root.locator('[data-orientation="vertical"][data-visible="false"]')).toHaveCount(1)
        const released = await tail.evaluate((element) => element.getBoundingClientRect().top)
        await timeline.send(
          partUpdated(
            textPart(
              "prt_nested_tail",
              `Latest output.\n\nNew stream.\n\n${"Additional line.\n\n".repeat(30)}Latest stream end.`,
            ),
          ),
        )
        await expect(page.getByText("New stream.", { exact: true })).toBeAttached()
        await expect(root.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
        if (nestedStart) await expect(page.getByText("Latest stream end.", { exact: true })).toBeInViewport()
        if (!nestedStart)
          expect(await tail.evaluate((element) => element.getBoundingClientRect().top)).toBeCloseTo(released, 0)
      })
    }
  })
}

async function readFrom(page: Page, text: string) {
  const timeline = page.locator('[data-slot="session-timeline-scroll"]')
  const scroller = timeline.getByRole("region", { name: "scrollable content", exact: true })
  await expect(timeline.locator("[data-timeline-virtual-content]")).toBeVisible()
  await page.evaluate(() => document.fonts.ready)
  await scroller.evaluate((element) => {
    element.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }))
    element.scrollTop = 0
  })
  await expect(scroller.locator('[data-timeline-row="UserMessage"]')).toBeInViewport()
  const anchor = scroller.getByText(text, { exact: true })
  await expect(anchor).toBeAttached()
  await expect(scroller.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(0)
  await anchor.evaluate((element) => {
    const root = element.closest("[data-scrollable]")!
    root.scrollTop += element.getBoundingClientRect().top - root.getBoundingClientRect().top - 8
  })
  await expect(anchor).toBeInViewport()
  return { timeline, scroller, anchor }
}
