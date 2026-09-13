import { expect, story } from "../../storybook/playwright/story"
import type { Locator } from "@playwright/test"
import { fileURLToPath } from "node:url"

const pasteImages = (editor: Locator, names: string[], colorOffset = 0) =>
  editor.evaluate(
    async (element, input) => {
      const transfer = new DataTransfer()
      for (let index = 0; index < input.names.length; index++) {
        const canvas = document.createElement("canvas")
        canvas.width = 2
        canvas.height = 2
        const context = canvas.getContext("2d")
        if (!context) throw new Error("Canvas unavailable")
        context.fillStyle = (index + input.colorOffset) % 2 ? "#00ff00" : "#ff0000"
        context.fillRect(0, 0, 2, 2)
        const blob = await new Promise<Blob>((resolve, reject) =>
          canvas.toBlob((value) => (value ? resolve(value) : reject(new Error("PNG encoding failed"))), "image/png"),
        )
        transfer.items.add(new File([blob], input.names[index], { type: "image/png" }))
      }
      const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer })
      element.dispatchEvent(event)
      return event.defaultPrevented
    },
    { names, colorOffset },
  )

for (const hasTouch of [true, false]) {
  story.describe(`composer writing assistance with touch=${hasTouch}`, () => {
    story.use({ hasTouch, isMobile: hasTouch })

    story("follows the input device and mode rather than viewport width", async ({ mount, page }) => {
      const component = await mount("opencode-composer-flow--empty-draft")
      const editor = component.locator('[data-component="composer-editor"]')

      for (const width of [390, 1280]) {
        await page.setViewportSize({ width, height: 844 })
        expect(await page.evaluate(() => matchMedia("(pointer: coarse)").matches)).toBe(hasTouch)
        await expect(editor).toHaveAttribute("autocorrect", hasTouch ? "on" : "off")
        await expect(editor).toHaveAttribute("autocapitalize", hasTouch ? "sentences" : "none")
        await expect(editor).toHaveAttribute("spellcheck", String(hasTouch))

        await editor.fill("!")
        await expect(editor).toHaveAttribute("autocorrect", "off")
        await expect(editor).toHaveAttribute("autocapitalize", "none")
        await expect(editor).toHaveAttribute("spellcheck", "false")
        await component.locator('[data-action="composer-exit-shell"]').click()
        await expect(editor).toHaveAttribute("autocorrect", hasTouch ? "on" : "off")
      }
    })
  })
}

story("mobile Enter preserves newlines in the submitted payload", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--snippets")
  const editor = component.locator('[data-component="composer-editor"]')
  const output = component.locator("output")

  for (const width of [390, 1280]) {
    await page.setViewportSize({ width, height: 844 })
    const previous = await output.textContent()
    await editor.fill("First line")
    await editor.press(width < 768 ? "Enter" : "Shift+Enter")
    await editor.pressSequentially("Second line")
    await expect(output).toHaveText(previous!)
    await editor.press(width < 768 ? "Shift+Enter" : "Enter")
    await expect(output).toHaveText(
      JSON.stringify({ text: "First line\nSecond line", files: [], agents: [], skills: [], apps: [] }),
    )
    await expect(editor).toHaveText("")
  }
})

story("keeps reference text editable and drops stale metadata when edited", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--snippets")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const output = component.getByRole("status")

  await editor.fill("$eff")
  await component.locator('[data-suggestion-id="skill:effect"]').click()
  await expect(editor.locator('[data-mention="skill"][data-id="effect"]')).toHaveText("$effect")

  await editor.press("End")
  await editor.press("Backspace")
  await editor.press("Backspace")
  await editor.pressSequentially("x")
  await expect(editor).toHaveText("$effecx")
  await expect(editor.locator('[data-mention="skill"]')).toHaveCount(0)
  await expect(editor).toBeFocused()

  await component.getByRole("button", { name: "Send", exact: true }).click()
  await expect(output).toHaveText(JSON.stringify({ text: "$effecx", files: [], agents: [], skills: [], apps: [] }))
})

story("undoes and redoes reference text with its structured identity", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--snippets")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const skill = editor.locator('[data-mention="skill"][data-id="effect"]')

  await editor.fill("$eff")
  await component.locator('[data-suggestion-id="skill:effect"]').click()
  await expect(skill).toHaveText("$effect")

  await editor.press("ControlOrMeta+z")
  await expect(editor).toHaveText("$eff")
  await expect(skill).toHaveCount(0)
  await editor.press((await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+Shift+z" : "Control+y")
  await expect(editor).toHaveText("$effect ")
  await expect(skill).toHaveCount(1)

  await editor.press("Home")
  await editor.pressSequentially("prefix ")
  await expect(editor).toHaveText("prefix $effect ")
  await expect(skill).toHaveCount(1)
  await editor.press("ControlOrMeta+z")
  await expect(editor).toHaveText("$effect ")
  await expect(skill).toHaveCount(1)
  await editor.press((await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+Shift+z" : "Control+y")
  await expect(editor).toHaveText("prefix $effect ")
  await expect(skill).toHaveCount(1)
  await component.getByRole("button", { name: "Send", exact: true }).click()
  await expect
    .poll(async () => JSON.parse((await component.getByRole("status").textContent()) ?? "{}"))
    .toMatchObject({
      text: "prefix $effect ",
      skills: [{ id: "effect", mention: { start: 7, end: 14, text: "$effect" } }],
    })
})

story("pastes plain and multiline text and replaces the selected range", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--empty-draft")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const paste = (text: string) =>
    editor.evaluate((element, value) => {
      const clipboard = new DataTransfer()
      clipboard.setData("text/plain", value)
      const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: clipboard })
      element.dispatchEvent(event)
      return event.defaultPrevented
    }, text)

  await editor.fill("replace tail")
  await editor.press("Home")
  for (let index = 0; index < "replace".length; index++) await editor.press("Shift+ArrowRight")
  expect(await paste("plain")).toBe(true)
  await expect(editor).toHaveText("plain tail")

  await editor.press("End")
  expect(await paste("\nsecond line")).toBe(true)
  await expect.poll(async () => (await editor.innerText()).replace(/\n$/, "")).toBe("plain tail\nsecond line")
})

story("pastes same-named images at the selection and submits their exact references", async ({ mount, page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const component = await mount("opencode-composer-flow--snippets")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })

  await editor.fill("before replace after")
  await editor.press("Home")
  for (let index = 0; index < "before ".length; index++) await editor.press("ArrowRight")
  for (let index = 0; index < "replace".length; index++) await editor.press("Shift+ArrowRight")
  expect(await pasteImages(editor, ["photo.png", "photo.png"])).toBe(true)

  await expect(editor).toHaveText("before [photo.png] [photo-2.png] after")
  const references = editor.locator('[data-mention="file"][data-id]')
  await expect(references).toHaveCount(2)
  await expect(references).toHaveText(["[photo.png]", "[photo-2.png]"])
  await expect(component.getByAltText("photo.png")).toHaveCount(1)
  await expect(component.getByAltText("photo-2.png")).toHaveCount(1)

  await editor.pressSequentially("!")
  await expect(editor).toHaveText("before [photo.png] [photo-2.png]! after")
  await component.getByRole("button", { name: "Send", exact: true }).click()
  const status = component.getByRole("status")
  await expect(status).toContainText('{"text":')
  await expect
    .poll(async () => {
      const value = JSON.parse((await status.textContent()) ?? "{}")
      return {
        text: value.text,
        files: value.files?.map((file: { uri: string; name: string; mention: unknown }) => ({
          data: file.uri.startsWith("data:image/png;base64,"),
          name: file.name,
          mention: file.mention,
        })),
      }
    })
    .toEqual({
      text: "before [photo.png] [photo-2.png]! after",
      files: [
        { data: true, name: "photo.png", mention: { text: "[photo.png]", start: 7, end: 18 } },
        { data: true, name: "photo-2.png", mention: { text: "[photo-2.png]", start: 19, end: 32 } },
      ],
    })
})

story("uploads a real image through the attachment input", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--snippets")
  await component
    .locator('input[type="file"]')
    .setInputFiles(fileURLToPath(new URL("../../ui/src/assets/favicon/favicon-96x96.png", import.meta.url)))

  await expect(component.getByAltText("favicon-96x96.png")).toHaveCount(1)
  await expect(component.getByRole("textbox", { name: "Prompt", exact: true })).toHaveText("")
})

story("tracks the paste position while image storage is pending", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--delayed-image-paste")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const complete = component.getByRole("button", { name: "Complete attachment", exact: true })

  await editor.fill("before after")
  await editor.press("Home")
  for (let index = 0; index < "before ".length; index++) await editor.press("ArrowRight")
  expect(await pasteImages(editor, ["photo.png"])).toBe(true)
  await editor.press("Home")
  await editor.pressSequentially("prefix ")
  await complete.click()

  await expect(editor).toHaveText("prefix before [photo.png] after")
  await expect(editor.locator('[data-mention="file"][data-filename="photo.png"]')).toHaveText("[photo.png]")
  await expect(component.getByAltText("photo.png")).toHaveCount(1)
})

for (const completion of ["in order", "out of order"] as const) {
  story(`keeps concurrent image paste order and identity when storage completes ${completion}`, async ({ mount }) => {
    const component = await mount("opencode-composer-flow--delayed-image-paste")
    const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
    const complete = component.getByRole("button", {
      name: completion === "in order" ? "Complete attachment" : "Complete latest attachment",
      exact: true,
    })

    expect(await pasteImages(editor, ["photo.png"])).toBe(true)
    await expect(complete).toBeEnabled()
    expect(await pasteImages(editor, ["photo.png"], 1)).toBe(true)
    await complete.click()
    await expect(editor).toHaveText(completion === "in order" ? "[photo.png]" : "[photo-2.png]")
    await complete.click()

    await expect(editor).toHaveText("[photo.png] [photo-2.png]")
    const references = editor.locator('[data-mention="file"][data-id]')
    await expect(references).toHaveText(["[photo.png]", "[photo-2.png]"])
    expect(
      new Set(await references.evaluateAll((items) => items.map((item) => item.getAttribute("data-id")))).size,
    ).toBe(2)
  })
}

story("keeps image reference edits and preview removal in CodeMirror history", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--empty-draft")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const reference = editor.locator('[data-mention="file"][data-id]')
  const undo = (await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+z" : "Control+z"
  const redo = (await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+Shift+z" : "Control+y"

  expect(await pasteImages(editor, ["photo.png"])).toBe(true)
  await expect(reference).toHaveText("[photo.png]")
  await expect(component.getByAltText("photo.png")).toHaveCount(1)

  await editor.press(undo)
  await expect(editor).toHaveText("")
  await expect(component.getByAltText("photo.png")).toHaveCount(0)
  await editor.press(redo)
  await expect(reference).toHaveText("[photo.png]")
  await expect(component.getByAltText("photo.png")).toHaveCount(1)

  await editor.press("Home")
  for (let index = 0; index < 6; index++) await editor.press("ArrowRight")
  await editor.press("Backspace")
  await expect(editor).toHaveText("[phot.png]")
  await expect(reference).toHaveCount(0)
  await expect(component.getByAltText("photo.png")).toHaveCount(0)

  await editor.press(undo)
  await expect(reference).toHaveText("[photo.png]")
  await expect(component.getByAltText("photo.png")).toHaveCount(1)
  await editor.press(redo)
  await expect(reference).toHaveCount(0)
  await expect(component.getByAltText("photo.png")).toHaveCount(0)

  await editor.press(undo)
  const id = await reference.getAttribute("data-id")
  if (!id) throw new Error("Missing attachment identity")
  await component.locator(`[data-action="remove-attachment"][data-attachment-id="${id}"]`).click()
  await expect(editor).toHaveText("")
  await expect(component.getByAltText("photo.png")).toHaveCount(0)
  await editor.press(undo)
  await expect(reference).toHaveText("[photo.png]")
  await expect(component.getByAltText("photo.png")).toHaveCount(1)
})

story("restores two pasted images in document and payload order after removing the first", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--snippets")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const undo = (await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+z" : "Control+z"
  const redo = (await page.evaluate(() => navigator.platform.startsWith("Mac"))) ? "Meta+Shift+z" : "Control+y"

  expect(await pasteImages(editor, ["a.png", "b.png"])).toBe(true)
  const references = editor.locator('[data-mention="file"][data-id]')
  await expect(references).toHaveText(["[a.png]", "[b.png]"])
  const original = await component.locator('[data-slot="composer-attachments"] img').evaluateAll(async (images) =>
    Promise.all(
      images.map(async (image) => {
        const blob = await fetch((image as HTMLImageElement).src).then((response) => response.blob())
        const data = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader()
          reader.addEventListener("load", () => resolve(String(reader.result)))
          reader.addEventListener("error", () => reject(reader.error))
          reader.readAsDataURL(blob)
        })
        return { name: (image as HTMLImageElement).alt, data }
      }),
    ),
  )
  const firstID = await references.filter({ hasText: "[a.png]" }).getAttribute("data-id")
  if (!firstID) throw new Error("Missing first attachment identity")

  await component.locator(`[data-action="remove-attachment"][data-attachment-id="${firstID}"]`).click()
  await expect(references).toHaveText(["[b.png]"])
  await editor.press(undo)
  await expect(references).toHaveText(["[a.png]", "[b.png]"])
  const previews = component.locator('[data-slot="composer-attachments"] img')
  await expect(previews).toHaveCount(2)
  await expect
    .poll(() => previews.evaluateAll((images) => images.map((image) => image.getAttribute("alt"))))
    .toEqual(["a.png", "b.png"])
  await editor.press(redo)
  await expect(references).toHaveText(["[b.png]"])
  await editor.press(undo)
  await component.getByRole("button", { name: "Send", exact: true }).click()

  const status = component.getByRole("status")
  await expect(status).toContainText('{"text":')
  await expect
    .poll(async () => {
      const value = JSON.parse((await status.textContent()) ?? "{}")
      return value.files?.map((file: { uri: string; name: string }) => ({ name: file.name, data: file.uri }))
    })
    .toEqual(original)
})

story("copies partial session text and preserves unselected text during structured paste", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--session-reference")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const session = editor.locator('[data-mention="session"]')
  const copy = () =>
    editor.evaluate((element) => {
      const clipboard = new DataTransfer()
      const event = new ClipboardEvent("copy", { bubbles: true, cancelable: true, clipboardData: clipboard })
      element.dispatchEvent(event)
      return {
        prevented: event.defaultPrevented,
        data: clipboard.getData("text/plain"),
        selection: window.getSelection()?.toString(),
      }
    })
  const paste = (text: string) =>
    editor.evaluate((element, value) => {
      const clipboard = new DataTransfer()
      clipboard.setData("text/plain", value)
      const event = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: clipboard })
      element.dispatchEvent(event)
      return event.defaultPrevented
    }, text)

  await editor.focus()
  await editor.press("Home")
  for (let index = 0; index < 3; index++) await editor.press("Shift+ArrowRight")
  expect(await copy()).toEqual({ prevented: true, data: "@Sh", selection: "@Sh" })

  await editor.press("Home")
  await editor.press("Shift+End")
  const structured = await copy()
  expect(structured.prevented).toBe(true)
  expect(structured.data).toContain("opencode://session/")
  await editor.press("Home")
  await editor.press("ArrowRight")
  await editor.press("ArrowRight")
  for (let index = 0; index < 3; index++) await editor.press("Shift+ArrowRight")
  expect(await paste(structured.data)).toBe(true)

  await expect(editor).toHaveText("@S@Shareded")
  await expect(session).toHaveCount(1)
  await expect(session).toHaveText("@Shared")
  await component.getByRole("button", { name: "Send", exact: true }).click()
  await expect
    .poll(async () => JSON.parse((await component.getByRole("status").textContent()) ?? "{}"))
    .toMatchObject({
      displayText: "@S@Shareded",
      sessions: [{ content: "@Shared", start: 2, end: 9 }],
    })
})

story("normalizes CRLF drafts before placing references and the caret", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--cr-lf-reference")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const output = component.getByRole("status")

  await expect.poll(async () => (await editor.innerText()).replace(/\n$/, "")).toBe("before\n$effect\nafter")
  await expect(editor.locator('[data-mention="skill"][data-id="effect"]')).toHaveText("$effect")
  await editor.focus()
  await editor.pressSequentially("!")
  await expect.poll(async () => (await editor.innerText()).replace(/\n$/, "")).toBe("before\n$effect\nafter!")
  await component.getByRole("button", { name: "Send", exact: true }).click()
  await expect
    .poll(async () => JSON.parse((await output.textContent()) ?? "{}"))
    .toMatchObject({
      text: "before\n$effect\nafter!",
      skills: [{ id: "effect", mention: { start: 7, end: 14, text: "$effect" } }],
    })
})

story("defers external draft synchronization until composition ends", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--external-draft-during-composition")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })

  await editor.fill("composing")
  await editor.dispatchEvent("compositionstart")
  await component
    .locator('[data-action="restore-external-draft"]')
    .evaluate((element: HTMLButtonElement) => element.click())
  await expect(editor).toHaveText("composing")
  await expect(editor).toHaveAttribute("dir", "auto")
  await editor.dispatchEvent("compositionend")
  await expect.poll(async () => (await editor.innerText()).replace(/\n$/, "")).toBe("restored\ndraft")
  await expect(editor).toHaveAttribute("dir", "ltr")
})

story("blocks editor commands while disabled or read only and restores editing", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--mutable-editor-access")
  const editor = component.getByRole("textbox", { name: "Prompt", exact: true })
  const disabled = component.locator('[data-action="toggle-composer-disabled"]')
  const readOnly = component.locator('[data-action="toggle-composer-readonly"]')
  const undo = (await page.evaluate(() => navigator.platform.startsWith("Mac")))
    ? { key: "z", code: "KeyZ", metaKey: true }
    : { key: "z", code: "KeyZ", ctrlKey: true }

  await editor.focus()
  await editor.press("End")
  await expect(editor).toBeFocused()
  await disabled.evaluate((element: HTMLButtonElement) => element.click())
  await expect(editor).toHaveAttribute("contenteditable", "false")
  await editor.dispatchEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true, cancelable: true })
  await editor.dispatchEvent("keydown", { ...undo, bubbles: true, cancelable: true })
  await expect(editor).toHaveText("abc")

  await disabled.evaluate((element: HTMLButtonElement) => element.click())
  await expect(editor).toHaveAttribute("contenteditable", "true")
  await editor.focus()
  await editor.press("End")
  await editor.pressSequentially("d")
  await expect(editor).toHaveText("abcd")

  await readOnly.evaluate((element: HTMLButtonElement) => element.click())
  await expect(editor).toHaveAttribute("contenteditable", "false")
  await editor.dispatchEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true, cancelable: true })
  await editor.dispatchEvent("keydown", { key: "Delete", code: "Delete", bubbles: true, cancelable: true })
  await editor.dispatchEvent("keydown", { ...undo, bubbles: true, cancelable: true })
  await expect(editor).toHaveText("abcd")

  await readOnly.evaluate((element: HTMLButtonElement) => element.click())
  await expect(editor).toHaveAttribute("contenteditable", "true")
  await editor.focus()
  await editor.press("End")
  await editor.press("Backspace")
  await expect(editor).toHaveText("abc")
})

for (const direction of ["ltr", "rtl"]) {
  for (const alternate of ["none", "queue", "steer"]) {
    story(`scrolls overflowing controls beside fixed ${alternate} actions in ${direction}`, async ({ mount, page }) => {
      const component = await mount("opencode-composer-flow--toolbar-overflow", {
        args: { alternate },
        globals: { direction },
      })
      const controls = component.locator('[data-slot="composer-controls"]')
      const actions = component.locator('[data-slot="composer-actions"]')
      const submit = component.locator('[data-action="composer-submit"]')
      const add = component.locator('[data-action="composer-attach"]')
      const agent = controls.getByRole("button", { name: "Choose agent" })
      const variant = controls.getByRole("button", { name: "Choose model variant" })
      await expect(controls).toHaveCSS("overflow-x", "auto")
      await expect(controls).toHaveCSS("overscroll-behavior-x", "contain")
      await expect(controls).toHaveCSS("direction", direction)
      await expect(controls).toHaveCSS("padding-inline-start", "0px")
      await expect(controls).toHaveCSS("padding-inline-end", "0px")
      await expect(component.locator('[data-action="composer-alternate-delivery"]')).toHaveCount(
        alternate === "none" ? 0 : 1,
      )

      for (const width of [1024, 360]) {
        await page.setViewportSize({ width, height: 720 })
        await expect
          .poll(() => controls.evaluate((element) => element.scrollWidth - element.clientWidth))
          .toBeGreaterThan(0)
        const fixed = await submit.boundingBox()
        const fixedAdd = await add.boundingBox()
        const viewport = await controls.boundingBox()
        const action = await actions.boundingBox()
        expect(fixed).not.toBeNull()
        expect(viewport).not.toBeNull()
        expect(action).not.toBeNull()
        expect(fixedAdd).not.toBeNull()
        if (!fixed || !viewport || !action || !fixedAdd) return
        expect(direction === "ltr" ? fixedAdd.x + fixedAdd.width : viewport.x + viewport.width).toBeCloseTo(
          direction === "ltr" ? viewport.x - 4 : fixedAdd.x - 4,
          1,
        )
        expect(direction === "ltr" ? viewport.x + viewport.width : action.x + action.width).toBeCloseTo(
          direction === "ltr" ? action.x - 12 : viewport.x - 12,
          1,
        )

        await controls.evaluate((element) => {
          element.scrollLeft = 0
        })
        await expect(controls).toHaveAttribute("data-overflow-start", "false")
        await expect(controls).toHaveAttribute("data-overflow-end", "true")
        await expect(controls).toHaveCSS(
          "mask-image",
          `linear-gradient(to ${direction === "ltr" ? "right" : "left"}, rgba(0, 0, 0, 0), rgb(0, 0, 0) 0px, rgb(0, 0, 0) calc(100% - 16px), rgba(0, 0, 0, 0))`,
        )
        const first = await agent.boundingBox()
        if (!first) throw new Error("Missing agent control")
        expect(
          direction === "ltr" ? first.x - viewport.x : viewport.x + viewport.width - first.x - first.width,
        ).toBeCloseTo(0, 0)
        await controls.evaluate((element) => {
          element.scrollLeft =
            ((getComputedStyle(element).direction === "rtl" ? -1 : 1) * (element.scrollWidth - element.clientWidth)) / 2
        })
        await expect(controls).toHaveAttribute("data-overflow-start", "true")
        await expect(controls).toHaveAttribute("data-overflow-end", "true")
        const scrolled = (await controls.boundingBox())!
        expect(scrolled.x).toBeCloseTo(viewport.x, 1)
        expect(scrolled.width).toBeCloseTo(viewport.width, 1)
        await controls.hover()
        await page.mouse.wheel(direction === "ltr" ? 1000 : -1000, 0)
        await expect.poll(() => controls.evaluate((element) => Math.abs(element.scrollLeft))).toBeGreaterThan(0)
        expect(await submit.boundingBox()).toEqual(fixed)
        expect(await add.boundingBox()).toEqual(fixedAdd)

        // The fade disappears at the endpoint instead of reserving padding.
        await variant.focus()
        await controls.evaluate((element) => {
          element.scrollLeft =
            getComputedStyle(element).direction === "rtl" ? -element.scrollWidth : element.scrollWidth
        })
        await expect(controls).toHaveAttribute("data-overflow-start", "true")
        await expect(controls).toHaveAttribute("data-overflow-end", "false")
        const last = await variant.boundingBox()
        if (!last) throw new Error("Missing variant control")
        expect(
          Math.abs(direction === "ltr" ? viewport.x + viewport.width - last.x - last.width : last.x - viewport.x),
        ).toBeLessThan(1)
        expect(
          Math.abs((direction === "ltr" ? action.x - last.x - last.width : last.x - action.x - action.width) - 12),
        ).toBeLessThan(1)
        await page.keyboard.press("Enter")
        await expect(page.getByRole("menuitemradio", { name: "high", exact: true })).toBeVisible()
        await page.keyboard.press("Escape")
        await expect(variant).toBeFocused()
        await expect(submit).toBeInViewport()
        await expect(add).toBeInViewport()
        await add.click()
        await expect(page.getByRole("menuitem", { name: "Images and files" })).toBeVisible()
        await page.keyboard.press("Escape")
        expect(await add.boundingBox()).toEqual(fixedAdd)
      }

      if (alternate !== "none") {
        const width = (await controls.boundingBox())!.width
        await component.getByRole("textbox", { name: "Prompt", exact: true }).fill("")
        await expect(component.locator('[data-action="composer-alternate-delivery"]')).toHaveCount(0)
        await expect.poll(async () => (await controls.boundingBox())!.width).toBeGreaterThan(width)
      }
    })
  }
}

story("does not mask or pad controls when they fit", async ({ mount }) => {
  const component = await mount("opencode-composer-flow--model-and-variant")
  const controls = component.locator('[data-slot="composer-controls"]')
  await expect(controls).toHaveAttribute("data-overflow-start", "false")
  await expect(controls).toHaveAttribute("data-overflow-end", "false")
  await expect(controls).toHaveCSS("mask-image", "none")
  await expect(controls).toHaveCSS("padding-inline-start", "0px")
  await expect(controls).toHaveCSS("padding-inline-end", "0px")
})

// ThemeProvider writes resolved token values into a <style> block, so toggling data-color-scheme by hand
// leaves every --v2-* variable at its previous value. Switch themes through the Storybook global instead.
for (const [theme, background] of [
  ["light", "rgb(255, 255, 255)"],
  ["dark", "rgb(36, 36, 36)"],
] as const) {
  story(`raises the docked composer only in dark mode (${theme})`, async ({ mount }) => {
    const component = await mount("opencode-composer-flow--empty-draft", { globals: { theme } })
    await expect(component.locator('[data-component="composer"]')).toHaveCSS("background-color", background)
  })
}

story("centers add menu shortcuts in a consistent column", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--empty-draft")
  await component.locator('[data-action="composer-attach"]').click()

  const shortcuts = page.locator('[role="menu"] [data-slot="menu-v2-item-shortcut"]')
  await expect(shortcuts).toHaveCount(4)
  const boxes = await shortcuts.evaluateAll((items) =>
    items.map((item) => {
      const box = item.getBoundingClientRect()
      return { width: box.width, center: box.left + box.width / 2 }
    }),
  )

  expect(new Set(boxes.map((box) => box.width)).size).toBe(1)
  expect(new Set(boxes.map((box) => box.center)).size).toBe(1)
})

for (const draft of ["empty-draft", "multiline-draft", "mixed-attachments"]) {
  story(`select all stays inside the composer with ${draft}`, async ({ mount, page }) => {
    const component = await mount(`opencode-composer-flow--${draft}`)
    const input = component.getByRole("textbox", { name: "Prompt", exact: true })
    const text = (await input.innerText()).replace(/\n$/, "")

    for (let count = 0; count < 2; count++) {
      await input.press("ControlOrMeta+a")
      expect(
        await input.evaluate((editor) => {
          const selection = window.getSelection()
          return {
            text: selection?.toString(),
            inside: editor.contains(selection?.anchorNode ?? null) && editor.contains(selection?.focusNode ?? null),
          }
        }),
      ).toEqual({ text, inside: true })
    }

    await page.keyboard.type("Replacement draft")
    await expect(input).toHaveText("Replacement draft")
    await expect(component.getByRole("status")).toHaveText("Ready")
    if (draft === "mixed-attachments") {
      await expect(component.getByAltText("layout.png")).toBeVisible()
      await expect(component.getByText("Keep the normal flow flat", { exact: true })).toBeVisible()
    }
  })
}

story("renders a draft once and supports editing, caret restoration, and failure recovery", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--failed-submission-restoration")
  const input = component.getByRole("textbox", { name: "Prompt", exact: true })
  const original = await input.elementHandle()
  const expectSameEditor = async () =>
    expect(await input.evaluate((element, initial) => element === initial, original)).toBe(true)
  await expect(input).toHaveText("Preserve this draft on failure")
  await expectSameEditor()

  await input.press("Home")
  await input.press("Shift+ArrowRight")
  await input.pressSequentially("XY")
  await expect(input).toHaveText("XYreserve this draft on failure")
  await expectSameEditor()

  // Closing the model picker restores the controller's saved caret through its editor ref.
  await component.locator('[data-action="composer-model"]').click()
  await page.getByRole("menu").getByRole("textbox").press("Escape")
  await expect(input).toBeFocused()
  await input.pressSequentially("!")
  await expect(input).toHaveText("XY!reserve this draft on failure")
  await component.getByRole("button", { name: "Send", exact: true }).click()
  await expect(component.getByRole("status")).toHaveText("Submission failed; draft restored")
  await expect(input).toHaveText("Preserve this draft on failure")
  await expectSameEditor()
})

story("shows thinking on composer hover or when a non-default variant is selected", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--model-and-variant")
  const composer = component.locator('[data-component="composer"]')
  const input = composer.getByRole("textbox", { name: "Prompt", exact: true })
  const control = composer.getByRole("button", { name: "Choose model variant" })

  await component.getByRole("status").click()
  await page.mouse.move(0, 0)
  await expect(control).toHaveText("balanced")
  await expect(control).toHaveCSS("opacity", "1")

  await control.click()
  await page.getByRole("menuitemradio", { name: "default", exact: true }).click()
  await component.getByRole("status").click()
  await expect(control).toHaveText("default")
  await expect(control).toHaveCSS("opacity", "0")
  await expect(control).toHaveCSS("pointer-events", "none")

  await input.hover()
  await expect(control).toHaveCSS("opacity", "1")
  await expect(control).toHaveCSS("pointer-events", "auto")
  await input.click()
  await page.mouse.move(0, 0)
  await expect(input).toBeFocused()
  await expect(control).toHaveCSS("opacity", "0")

  await input.hover()
  await control.click()
  const high = page.getByRole("menuitemradio", { name: "high" })
  await expect(high).toBeVisible()
  await page.mouse.move(0, 0)
  await expect(control).toHaveAttribute("aria-expanded", "true")
  await expect(control).toHaveCSS("opacity", "1")
  await expect(high).toBeVisible()
  await high.click()
  await component.getByRole("status").click()
  await expect(control).toHaveText("high")
  await expect(control).toHaveCSS("opacity", "1")

  await control.click()
  await page.getByRole("menuitemradio", { name: "default", exact: true }).click()
  await component.getByRole("status").click()
  await expect(control).toHaveCSS("opacity", "0")
})

story("keeps default thinking accessible by keyboard without composer hover", async ({ mount, page }) => {
  const component = await mount("opencode-composer-flow--model-and-variant")
  const input = component.getByRole("textbox", { name: "Prompt", exact: true })
  const control = component.getByRole("button", { name: "Choose model variant" })

  await control.click()
  await page.getByRole("menuitemradio", { name: "default", exact: true }).click()
  await input.click()
  await page.mouse.move(0, 0)
  await expect(control).toHaveCSS("opacity", "0")

  // Tab through Add, Agent, and Model to the visually hidden thinking trigger.
  for (let count = 0; count < 4; count++) await page.keyboard.press("Tab")
  await expect(control).toBeFocused()
  await expect(control).toHaveCSS("opacity", "1")
  await page.keyboard.press("Enter")
  await expect(control).toHaveAttribute("aria-expanded", "true")
  await expect(page.getByRole("menuitemradio", { name: "default", exact: true })).toBeFocused()
  await expect(control).toHaveCSS("opacity", "1")
  await page.keyboard.press("Escape")
  await expect(control).toHaveAttribute("aria-expanded", "false")
  await expect(control).toBeFocused()
  await expect(control).toHaveCSS("opacity", "1")
  await page.keyboard.press("Enter")
  await expect(page.getByRole("menuitemradio", { name: "default", exact: true })).toBeFocused()
  await page.keyboard.press("End")
  await expect(page.getByRole("menuitemradio", { name: "high", exact: true })).toBeFocused()
  await page.keyboard.press("Enter")
  await expect(control).toHaveText("high")
  await expect(control).toBeFocused()
  await page.keyboard.press("Enter")
  await expect(page.getByRole("menuitemradio", { name: "default", exact: true })).toBeFocused()
  await page.keyboard.press("Enter")
  await expect(control).toHaveText("default")
  await expect(control).toBeFocused()
  await expect(control).toHaveCSS("opacity", "1")
  await page.keyboard.press("Tab")
  await expect(control).not.toBeFocused()
  await expect(control).toHaveCSS("opacity", "0")
})
