import { fileURLToPath } from "node:url"
import { expect, story } from "../../storybook/playwright/story"

const fixture = `/@fs/${fileURLToPath(new URL("./timeline-virtualizer.fixture.tsx", import.meta.url)).replaceAll("\\", "/")}`

for (const scenario of ["streaming", "clamped", "missing"]) {
  story(`reading restoration settles with ${scenario} content`, async ({ page }) => {
    await page.evaluate(
      async ({ fixture, scenario }) => {
        const { mountReadingVirtualizer } = await import(fixture)
        mountReadingVirtualizer({
          index: scenario === "missing" ? 99 : scenario === "clamped" ? 29 : 12,
          offset: scenario === "clamped" ? 50 : 20,
          missing: scenario === "missing",
          streaming: scenario === "streaming",
        })
      },
      { fixture, scenario },
    )
    const root = page.getByTestId("reading-fixture")
    const state = root.locator(":scope > div")
    await expect(state).toHaveAttribute("data-restoring", "false")
    expect(Number(await root.getAttribute("data-restoration-ms"))).toBeLessThan(3000)
    await expect(state).toHaveAttribute("data-pinned", scenario === "missing" ? "true" : "false")
    const viewport = root.locator(".scroll-view__viewport")
    if (scenario === "missing") {
      await expect(state).toHaveAttribute("data-pages", "3")
      await expect
        .poll(() => viewport.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop))
        .toBeLessThan(2)
      expect(Number(await root.getAttribute("data-writes"))).toBeLessThan(5)
      return
    }
    await expect(state).toHaveAttribute("data-pages", "0")
    if (scenario === "streaming") {
      await expect(root.locator('[data-component="markdown"]:not([data-markdown-ready])')).toHaveCount(1)
      await expect.poll(async () => Number(await state.getAttribute("data-growth"))).toBeGreaterThan(0)
      await expect.poll(() => viewport.evaluate((el) => el.scrollTop)).toBe(740)
      await root.getByRole("button", { name: "Jump to latest" }).click()
      await expect(state).toHaveAttribute("data-pinned", "true")
      await expect
        .poll(() => viewport.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop))
        .toBeLessThan(2)
      return
    }
    await expect.poll(() => viewport.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop)).toBeLessThan(2)
    await root.getByRole("button", { name: "Leave", exact: true }).click()
    await root.getByRole("button", { name: "Return", exact: true }).click()
    await expect(state).toHaveAttribute("data-restoring", "false")
    await expect(state).toHaveAttribute("data-pinned", "false")
  })
}

story.beforeEach(async ({ mount }) => {
  // The virtualizer fixture only needs the shared story providers, not a composer.
  const component = await mount("inference-footer--completed")
  await expect(component.getByText("The inference details remain visible below the response.")).toBeVisible()
})

story("final hash offset supersedes reveal-by-index through later measurements", async ({ page }) => {
  await page.evaluate(async (fixture) => {
    const { mountReadingVirtualizer } = await import(fixture)
    mountReadingVirtualizer({ index: 12, offset: 20 })
  }, fixture)
  const root = page.getByTestId("reading-fixture")
  await expect(root.locator(":scope > div")).toHaveAttribute("data-restoring", "false")
  await root.getByRole("button", { name: "Position after reveal and resize", exact: true }).click()
  await expect(root.locator('[data-timeline-key="user-message:reading-11"]')).toHaveCSS("height", "160px")
  await expect.poll(() => root.locator(".scroll-view__viewport").evaluate((el) => el.scrollTop)).toBe(840)
  await root.getByRole("button", { name: "Leave", exact: true }).click()
  await expect(root).toHaveAttribute(
    "data-anchor",
    JSON.stringify({ rowKey: "user-message:reading-12", messageID: "reading-12", offset: 20 }),
  )
})

for (const more of [false, true]) {
  story(`waits for initial sync to supply the anchor with more=${more}`, async ({ page }) => {
    await page.evaluate(
      async ({ fixture, more }) => {
        const { mountReadingVirtualizer } = await import(fixture)
        mountReadingVirtualizer({ index: 12, offset: 20, slowSync: "missing", missing: more })
      },
      { fixture, more },
    )
    const root = page.getByTestId("reading-fixture")
    const state = root.locator(":scope > div")
    await expect(root.getByText("reading-20", { exact: true })).toBeVisible()
    await root.getByRole("button", { name: "Complete sync", exact: true }).click()
    await expect(state).toHaveAttribute("data-restoring", "false")
    await expect(state).toHaveAttribute("data-pinned", "false")
    await expect(state).toHaveAttribute("data-pages", "0")
    await expect.poll(() => root.locator(".scroll-view__viewport").evaluate((el) => el.scrollTop)).toBe(740)
  })
}

story("positions an available anchor before initial sync settles", async ({ page }) => {
  await page.evaluate(async (fixture) => {
    const { mountReadingVirtualizer } = await import(fixture)
    mountReadingVirtualizer({ index: 12, offset: 20, slowSync: "available" })
  }, fixture)
  const root = page.getByTestId("reading-fixture")
  const state = root.locator(":scope > div")
  await expect.poll(() => root.locator(".scroll-view__viewport").evaluate((el) => el.scrollTop)).toBe(740)
  await expect(state).toHaveAttribute("data-restoring", "true")
  await root.getByRole("button", { name: "Complete sync", exact: true }).click()
  await expect(state).toHaveAttribute("data-restoring", "false")
  await expect(state).toHaveAttribute("data-pinned", "false")
})

for (const pending of [false, true]) {
  story(`short restored session resumes following after ${pending ? "timeout" : "completion"}`, async ({ page }) => {
    await page.evaluate(
      async ({ fixture, pending }) => {
        const { mountReadingVirtualizer } = await import(fixture)
        mountReadingVirtualizer({ index: 0, offset: 20, count: 1, pendingAnchor: pending })
      },
      { fixture, pending },
    )
    const state = page.getByTestId("reading-fixture").locator(":scope > div")
    await expect(state).toHaveAttribute("data-restoring", "false")
    await expect(state).toHaveAttribute("data-pinned", "true")
  })
}

story("pending anchor keeps its intrarow offset until the deadline", async ({ page }) => {
  await page.evaluate(async (fixture) => {
    const { mountReadingVirtualizer } = await import(fixture)
    mountReadingVirtualizer({ index: 12, offset: 40, pendingAnchor: true })
  }, fixture)
  const root = page.getByTestId("reading-fixture")
  const state = root.locator(":scope > div")
  const viewport = root.locator(".scroll-view__viewport")
  await expect.poll(() => viewport.evaluate((el) => el.scrollTop)).toBe(760)
  await expect(state).toHaveAttribute("data-restoring", "true")
  await expect(state).toHaveAttribute("data-restoring", "false")
  await expect.poll(() => viewport.evaluate((el) => el.scrollTop)).toBe(760)
  await expect(state).toHaveAttribute("data-pinned", "false")
  await expect(
    root.locator('[data-timeline-key="user-message:reading-12"] [data-component="markdown"]'),
  ).not.toHaveAttribute("data-markdown-ready")
})

story("captures a programmatic logical offset before its native scroll event", async ({ page }) => {
  await page.evaluate(async (fixture) => {
    const { mountReadingVirtualizer } = await import(fixture)
    mountReadingVirtualizer({ index: 12, offset: 20 })
  }, fixture)
  const root = page.getByTestId("reading-fixture")
  const state = root.locator(":scope > div")
  await expect(state).toHaveAttribute("data-restoring", "false")
  await root.getByRole("button", { name: "Navigate and leave", exact: true }).click()
  await expect(root).toHaveAttribute("data-anchor", /reading-19/)
  await root.getByRole("button", { name: "Return", exact: true }).click()
  await expect(state).toHaveAttribute("data-restoring", "false")
  await expect.poll(() => root.locator(".scroll-view__viewport").evaluate((el) => el.scrollTop)).toBe(1140)
  await expect(state).toHaveAttribute("data-pinned", "false")
})

for (const scenario of ["timeout", "error", "cancel"]) {
  story(`reading recovery stops future requests after ${scenario}`, async ({ page }) => {
    await page.evaluate(
      async ({ fixture, scenario }) => {
        const { mountReadingVirtualizer } = await import(fixture)
        mountReadingVirtualizer({
          index: 99,
          offset: 20,
          missing: true,
          request: scenario === "error" ? "error" : "wait",
        })
      },
      { fixture, scenario },
    )
    const root = page.getByTestId("reading-fixture")
    const state = root.locator(":scope > div")
    await expect(state).toHaveAttribute("data-pages", "1")
    if (scenario === "cancel") {
      await expect(state).toHaveAttribute("data-restoring", "true")
      await root.locator(".scroll-view__viewport").dispatchEvent("wheel", { deltaY: -1 })
    }
    await expect(state).toHaveAttribute("data-restoring", "false")
    await expect(state).toHaveAttribute("data-pinned", "false")
    await root.getByRole("button", { name: "Resolve history", exact: true }).click()
    await root.getByRole("button", { name: "Jump to latest" }).click()
    await expect(state).toHaveAttribute("data-pinned", "true")
    await expect(state).toHaveAttribute("data-pages", "1")
  })
}

story("spaces the first mobile message without changing desktop spacing", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.evaluate(async (fixture) => {
    const { mountTimelineVirtualizer } = await import(fixture)
    mountTimelineVirtualizer({ count: 1, rowHeight: 60, immediate: true })
  }, fixture)
  const root = page.getByTestId("timeline-virtualizer-fixture")
  await root.getByRole("button", { name: "Complete Markdown", exact: true }).click()
  const content = root.locator("[data-timeline-virtual-content]")
  await expect(content).toHaveCSS("visibility", "visible")
  const gap = () =>
    root.locator('[data-timeline-key="user-message:message-0"]').evaluate((element) => {
      const viewport = element.closest("[data-scrollable]")!
      return element.getBoundingClientRect().top - viewport.getBoundingClientRect().top
    })
  await expect.poll(gap).toBe(16)
  await root.evaluate((element) => element.setAttribute("dir", "rtl"))
  await expect.poll(gap).toBe(16)
  await page.setViewportSize({ width: 1280, height: 900 })
  await expect.poll(gap).toBe(0)
  await page.setViewportSize({ width: 390, height: 844 })
  await expect.poll(gap).toBe(16)
})

story("bounds the cheap suffix and reveals only ready measured rows", async ({ page }) => {
  await page.evaluate(async (fixture) => {
    const { mountTimelineVirtualizer } = await import(fixture)
    mountTimelineVirtualizer({ count: 100, rowHeight: 60, immediate: true })
  }, fixture)
  const root = page.getByTestId("timeline-virtualizer-fixture")
  const content = root.locator("[data-timeline-virtual-content]")
  await expect(root).toHaveAttribute("data-observed-height", "180")
  await expect(content).toHaveCSS("visibility", "hidden")
  await expect(content.locator("[data-timeline-key]")).toHaveCount(4)
  await root.getByRole("button", { name: "Complete Markdown", exact: true }).click()
  await expect(content).toHaveCSS("visibility", "visible")
  await expect(root).toHaveAttribute("data-first-reveal", /.+/)
  expect(await root.evaluate((element) => JSON.parse(element.dataset.firstReveal!))).toMatchObject({
    rows: [96, 97, 98, 99],
    pendingMarkdown: 0,
    clipped: [],
    viewportHeight: 180,
  })
})

for (const input of [
  { name: "offset-only", count: 1, rowHeight: 600 },
  { name: "zero-height", count: 4, rowHeight: 60 },
]) {
  story(`reveals ready measured rows after an ${input.name} reconnect`, async ({ page }) => {
    await page.evaluate(
      async ({ fixture, input }) => {
        const { mountTimelineVirtualizer } = await import(fixture)
        mountTimelineVirtualizer(input)
      },
      { fixture, input },
    )
    const root = page.getByTestId("timeline-virtualizer-fixture")
    const content = root.locator("[data-timeline-virtual-content]")
    await expect(root).toHaveAttribute("data-observed-height", "180")
    await expect(content).toHaveCSS("visibility", "hidden")
    await expect(content.locator("[data-timeline-key]")).toHaveCount(1)

    if (input.name === "offset-only") {
      await expect(root).toHaveAttribute("data-last-scroll-top", "484")
      await root.locator("[data-scrollable]").dispatchEvent("wheel", { deltaY: -1 })
      await expect(root.getByTestId("timeline-controls")).toHaveAttribute("data-pinned", "false")
    }
    if (input.name === "zero-height") {
      await root.getByRole("button", { name: "Hide viewport", exact: true }).click()
      // Wait for ResizeObserver to clear the actual range, not just for display:none.
      await expect(root).toHaveAttribute("data-observed-height", "0")
      await expect(content.locator("[data-timeline-key]")).toHaveCount(0)
    }
    await expect(root).not.toHaveAttribute("data-first-reveal")
    const resizes = await root.getAttribute("data-viewport-resizes")
    await root.getByRole("button", { name: "Reconnect ready rows", exact: true }).click()
    await expect(content).toHaveCSS("visibility", "visible")
    await expect(root).toHaveAttribute("data-first-reveal", /.+/)
    expect(await root.evaluate((element) => JSON.parse(element.dataset.firstReveal!))).toMatchObject({
      rows: input.count === 1 ? [0] : [0, 1, 2, 3],
      pendingMarkdown: 0,
      clipped: [],
      viewportHeight: 180,
      ...(input.name === "offset-only" ? { scrollTop: 0 } : {}),
    })
    if (input.name === "offset-only") {
      // This repair must not depend on another native scroll or resize delivery.
      await expect(root).toHaveAttribute("data-scrolls", "0")
      await expect(root).toHaveAttribute("data-viewport-resizes", resizes!)
    }
  })
}
