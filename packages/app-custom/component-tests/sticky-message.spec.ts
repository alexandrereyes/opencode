import { expect, story } from "../../storybook/playwright/story"

for (const width of [1280, 390]) {
  story(`sticky user message follows the reading position at ${width}px`, async ({ page, mount }) => {
    await page.setViewportSize({ width, height: 844 })
    await mount("sticky-message--reading")
    const root = page.getByTestId("sticky-fixture")
    const viewport = root.locator('[data-slot="session-timeline-scroll"] [data-scrollable]').first()
    const first = root.locator('[data-timeline-key="user-message:sticky-user-0"]')
    const header = first.locator("[data-sticky-user]")
    await root.getByRole("button", { name: "First request", exact: true }).click()
    await expect(first).toBeVisible()
    await viewport.evaluate((element) => {
      element.scrollTop += 650
    })
    await expect
      .poll(async () => {
        const top = await viewport.evaluate((element) => element.getBoundingClientRect().top)
        return Math.round((await header.boundingBox())!.y - top)
      })
      .toBe(48)
    await expect(first.locator('[data-component="user-message"]')).toHaveCount(1)
    await expect(first.getByRole("button", { name: "Expand message", exact: true })).toBeVisible()
    const draft = first.locator('[data-slot="user-message-draft"]')
    expect(
      await draft.evaluate((element) => element.clientHeight / Number.parseFloat(getComputedStyle(element).lineHeight)),
    ).toBeCloseTo(2, 0)

    const anchor = root.getByRole("heading", { name: "Response 1, section 4", exact: true })
    const before = await anchor.boundingBox()
    await first.getByRole("button", { name: "Expand message", exact: true }).focus()
    await page.keyboard.press("Enter")
    await expect(draft).toHaveAttribute("data-expanded", "true")
    await expect.poll(async () => Math.round((await anchor.boundingBox())!.y)).toBe(Math.round(before!.y))
    expect((await header.boundingBox())!.height).toBeLessThanOrEqual((await viewport.boundingBox())!.height * 0.4 + 1)
    const collapse = await first.getByRole("button", { name: "Collapse message", exact: true }).boundingBox()
    expect(collapse!.y + collapse!.height).toBeLessThanOrEqual(
      (await header.boundingBox())!.y + (await header.boundingBox())!.height + 1,
    )
    expect(
      await header
        .locator('[data-slot="user-message-scroll"]')
        .evaluate((element) => element.scrollHeight > element.clientHeight),
    ).toBe(true)

    // Streaming elsewhere must not move a historical response being read.
    await root.getByRole("button", { name: "Append response", exact: true }).click()
    await expect.poll(async () => Math.round((await anchor.boundingBox())!.y)).toBe(Math.round(before!.y))
    await root.getByRole("button", { name: "Load history", exact: true }).click()
    await expect.poll(async () => Math.round((await anchor.boundingBox())!.y)).toBe(Math.round(before!.y))
    await root.getByRole("button", { name: "Latest", exact: true }).click()
    await expect(first).toHaveCount(0)
    await root.getByRole("button", { name: "First request", exact: true }).click()
    await expect(first.locator('[data-slot="user-message-draft"]')).toHaveAttribute("data-expanded", "true")
    await first.getByRole("button", { name: "Collapse message", exact: true }).click()
    await expect(first.locator('[data-slot="user-message-draft"]')).toHaveAttribute("data-expanded", "false")

    await root.getByRole("button", { name: "Short request", exact: true }).click()
    const short = root.locator('[data-timeline-key="user-message:sticky-user-1"]')
    await expect(short).toBeVisible()
    await expect(short.getByRole("button", { name: "Expand message", exact: true })).toHaveCount(0)
    await viewport.evaluate((element) => {
      element.scrollTop += 600
    })
    await expect
      .poll(async () =>
        Math.round((await short.locator("[data-sticky-user]").boundingBox())!.y - (await viewport.boundingBox())!.y),
      )
      .toBe(48)
    await root.evaluate((element) => element.setAttribute("dir", "rtl"))
    await expect
      .poll(async () =>
        Math.round((await short.locator("[data-sticky-user]").boundingBox())!.y - (await viewport.boundingBox())!.y),
      )
      .toBe(48)
    expect(await root.locator("[data-timeline-key]").count()).toBeLessThan(20)
    await root.getByRole("button", { name: "Latest", exact: true }).click()
    await expect(root).toHaveAttribute("data-pinned", "true")
    const latest = root.locator('[data-timeline-key="user-message:sticky-user-11"]')
    await latest.getByRole("button", { name: "Expand message", exact: true }).click()
    await latest.locator('[data-slot="user-message-scroll"]').dispatchEvent("wheel", { deltaY: -100 })
    await expect(root).toHaveAttribute("data-pinned", "true")
    await root.getByRole("button", { name: "Append response", exact: true }).click()
    await expect
      .poll(() =>
        viewport.evaluate((element) => Math.abs(element.scrollHeight - element.clientHeight - element.scrollTop)),
      )
      .toBeLessThan(1)
  })
}

for (const header of [true, false]) {
  story(`native sticky handoff at small boundary offsets, header=${header}`, async ({ page, mount }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await mount(header ? "sticky-message--reading" : "sticky-message--without-header")
    const root = page.getByTestId("sticky-fixture")
    const viewport = root.locator('[data-slot="session-timeline-scroll"] [data-scrollable]').first()
    const next = root.locator('[data-timeline-key="user-message:sticky-user-1"]')
    await root.getByRole("button", { name: "Short request", exact: true }).click()
    await expect(next).toBeVisible()
    const boundary = header ? 48 : 0
    for (const offset of [160, 80, 2, 1, 0, -1, -2, -47, -48, -49, 1, 80]) {
      const delta = (await next.boundingBox())!.y - (await viewport.boundingBox())!.y - boundary - offset
      await viewport.evaluate((element, delta) => {
        element.scrollTop += delta
      }, delta)
      await expect
        .poll(async () =>
          Math.round((await next.locator("[data-sticky-user]").boundingBox())!.y - (await viewport.boundingBox())!.y),
        )
        .toBe(boundary + Math.max(0, offset))
      const previous = root.locator('[data-timeline-key="user-message:sticky-user-0"] [data-sticky-user]')
      if (offset > 0) {
        await expect(previous).toHaveCount(1)
        const before = (await previous.boundingBox())!
        expect(before.y + before.height).toBeLessThanOrEqual(
          (await next.locator("[data-sticky-user]").boundingBox())!.y + 1,
        )
      }
      await expect(next.locator('[data-component="user-message"]')).toHaveCount(1)
    }
  })
}

for (const scenario of ["context", "attachments-only"]) {
  for (const width of [1280, 390]) {
    story(`whole message disclosure: ${scenario}, ${width}px`, async ({ page, mount }) => {
      await page.setViewportSize({ width, height: 844 })
      await mount(`sticky-message--${scenario}`)
      const root = page.getByTestId("sticky-fixture")
      await root.getByRole("button", { name: "First request", exact: true }).click()
      const first = root.locator('[data-timeline-key="user-message:sticky-user-0"]')
      const message = first.locator('[data-component="user-message"]')
      await expect(first.getByRole("button", { name: "Expand message", exact: true })).toBeVisible()
      await expect(first.locator('[data-slot="user-message-expand"]')).toHaveCount(0)
      await expect(
        first.getByRole("button", { name: "Expand message", exact: true }).locator("button, a, input"),
      ).toHaveCount(0)
      await expect(first.locator('[data-slot="user-message-attachments"]')).toHaveCount(0)
      await expect(first.locator('[data-slot="user-message-quotes"]')).toHaveCount(0)
      expect((await message.boundingBox())!.height).toBeLessThan(150)
      await first.getByRole("button", { name: "Expand message", exact: true }).click()
      await expect(first.locator('[data-slot="user-message-attachment-image"]')).toHaveCount(6)
      await expect(first.getByText("context-7.ts", { exact: true })).toHaveCount(1)
      await first.getByRole("button", { name: "layout-0.png", exact: true }).click()
      await expect(page.getByRole("dialog")).toBeVisible()
      await page.keyboard.press("Escape")
      if (scenario === "context") {
        await expect(first.locator('[data-slot="user-message-quotes"]')).toHaveCount(1)
        await expect(first.locator('[data-slot="user-message-comments"]')).toHaveCount(1)
      }
      const scroller = first.locator('[data-slot="user-message-scroll"]')
      for (const end of [false, true]) {
        await scroller.evaluate((element, end) => {
          element.scrollTop = end ? element.scrollHeight : 0
        }, end)
        const button = first.getByRole("button", { name: "Collapse message", exact: true })
        await expect(button).toBeInViewport()
        await expect(first.getByRole("button", { name: "Fork to new session", exact: true })).toBeInViewport()
        const box = (await button.boundingBox())!
        expect(box.y + box.height).toBeLessThanOrEqual(
          (await message.boundingBox())!.y + (await message.boundingBox())!.height + 1,
        )
      }
      await first.getByRole("button", { name: "Collapse message", exact: true }).click()
      await first.locator('[data-component="user-message"]').hover()
      await first.getByRole("button", { name: "Fork to new session", exact: true }).click()
      await expect(root.getByRole("status")).toHaveText("Fork sticky-user-0")
      await expect(first.locator('[data-slot="user-message-attachments"]')).toHaveCount(0)
      await expect(first.getByRole("button", { name: "Expand message", exact: true })).toBeInViewport()
    })
  }
}

story("text selection and links do not expand the message", async ({ page, mount }) => {
  await mount("sticky-message--reading")
  await page.getByRole("button", { name: "First request", exact: true }).click()
  const draft = page.locator('[data-timeline-key="user-message:sticky-user-0"] [data-slot="user-message-draft"]')
  await draft.evaluate((element) => {
    const range = document.createRange()
    range.selectNodeContents(element.firstElementChild!)
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    element.dispatchEvent(new MouseEvent("click", { bubbles: true }))
  })
  await expect(draft).toHaveAttribute("data-expanded", "false")
  // The plain-text renderer currently emits no anchors. Exercise the click
  // boundary with a local anchor so future link renderers remain protected.
  await draft.evaluate((element) => {
    window.getSelection()!.removeAllRanges()
    const link = document.createElement("a")
    link.href = "#fixture-link"
    link.textContent = "Fixture link"
    link.addEventListener("click", (event) => event.preventDefault())
    element.prepend(link)
  })
  await draft.getByRole("link", { name: "Fixture link" }).click()
  await expect(draft).toHaveAttribute("data-expanded", "false")
})

for (const theme of ["light", "dark"]) {
  story(`context-only blue bubble has no collapsed arrow, ${theme}`, async ({ page, mount }) => {
    await page.setViewportSize({ width: theme === "dark" ? 390 : 1280, height: 844 })
    await mount("sticky-message--comments-only", { globals: { theme } })
    await page.getByRole("button", { name: "First request", exact: true }).click()
    const first = page.locator('[data-timeline-key="user-message:sticky-user-0"]')
    const bubble = first.locator('[data-slot="user-message-text"]')
    await expect(bubble).toContainText("Essas tabelas seguem o padrão de @review")
    expect(await bubble.evaluate((element) => getComputedStyle(element).backgroundColor)).not.toBe("rgba(0, 0, 0, 0)")
    await expect(first.locator('[data-slot="user-message-expand"]')).toHaveCount(0)
    await bubble.focus()
    await page.keyboard.press("Space")
    await expect(first.getByRole("button", { name: "Collapse message", exact: true })).toBeVisible()
    await expect(first.locator('[data-slot="user-message-quotes"]')).toHaveCount(1)
    await expect(first.locator('[data-slot="user-message-comments"]')).toHaveCount(1)
    await expect(bubble).not.toHaveAttribute("role", "button")
    await first.getByRole("button", { name: "Collapse message", exact: true }).click()
    await expect(first.locator('[data-slot="user-message-expand"]')).toHaveCount(0)
    await bubble.click()
    await expect(first.getByRole("button", { name: "Collapse message", exact: true })).toBeVisible()
  })
}

story("draft observer follows empty/text mounts, remounts and width changes", async ({ page, mount }) => {
  await page.setViewportSize({ width: 1280, height: 844 })
  await mount("sticky-message--text-lifecycle")
  const draft = page.locator('[data-slot="user-message-draft"]')
  const expand = page.getByRole("button", { name: "Expand message", exact: true })
  await expect(draft).toHaveCount(0)
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.getByRole("button", { name: "Set text", exact: true }).click()
    await expect(draft).toHaveCount(1)
    await expect(expand).toHaveCount(0)
    await page.setViewportSize({ width: 300, height: 844 })
    await expect(expand).toBeVisible()
    await page.getByRole("button", { name: "Toggle message", exact: true }).click()
    await expect(draft).toHaveCount(0)
    await page.getByRole("button", { name: "Toggle message", exact: true }).click()
    await expect(expand).toBeVisible()
    await expand.click()
    await expect(draft).toHaveAttribute("data-expanded", "true")
    await page.getByRole("button", { name: "Collapse message", exact: true }).click()
    await page.setViewportSize({ width: 1280, height: 844 })
    await expect(expand).toHaveCount(0)
    await page.getByRole("button", { name: "Clear text", exact: true }).click()
    await expect(draft).toHaveCount(0)
    await expect(expand).toHaveCount(0)
  }
})
