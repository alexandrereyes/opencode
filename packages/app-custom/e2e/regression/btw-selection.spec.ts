import type { SessionMessageInfo } from "@opencode/client/promise"
import { expect, test } from "@playwright/test"
import { fixture } from "../performance/timeline/session-timeline-stress.fixture"
import { stressSessionHref } from "../performance/timeline/timeline-test-helpers"
import { expectComposerText } from "../utils/composer"
import { mockOpenCodeServer } from "../utils/mock-server"

test.use({ serviceWorkers: "block" })

for (const width of [1440, 390]) {
  const scenario = test.extend({ hasTouch: width < 768, isMobile: width < 768 })
  for (const selection of ["paragraph", "block", "released", "keyboard"] as const) {
    scenario(`side questions retain ${selection} selections at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      const session = { ...fixture.sessions[0], id: "ses_btw_selection" }
      const first = "Use the complete connection string without external quotes."
      const second = "Check the deployment configuration."
      const quote = selection === "paragraph" ? `> ${first}` : `> ${first}\n> \n> ${second}`
      const messages: SessionMessageInfo[] = [
        { id: "msg_btw_user", type: "user", time: { created: 1700000000000 }, text: "Explain deployment." },
        {
          id: "msg_btw_answer",
          type: "assistant",
          agent: "build",
          time: { created: 1700000000100, completed: 1700000001000 },
          model: { id: "claude-opus-4-6", providerID: "opencode" },
          content: [{ type: "text", text: `${first}\n\n${second}` }],
        },
      ]
      await mockOpenCodeServer(page, {
        ...fixture,
        sessions: [session],
        pageMessages: () => ({ items: messages }),
      })
      await page.route(`**/api/session/${session.id}/generate`, (route) =>
        route.fulfill({ json: { data: { text: "The selected text explains deployment configuration." } } }),
      )
      await page.goto(stressSessionHref(session.id))
      const modifier = await page.evaluate(() =>
        /(Mac|iPod|iPhone|iPad)/.test(navigator.platform) ? "Meta" : "Control",
      )
      const editor = page.getByRole("textbox", { name: "Prompt", exact: true })
      await editor.fill("Main draft stays here")
      const part = page.locator('[data-timeline-part-id="msg_btw_answer:text:0"]')
      await expect(part.locator('[data-component="markdown"]')).toHaveAttribute("data-markdown-ready", "")
      const target =
        selection === "paragraph"
          ? part.getByText(first, { exact: true })
          : part.locator('[data-slot="text-part-body"]')
      await target.evaluate((element) => {
        const range = document.createRange()
        range.selectNodeContents(element)
        window.getSelection()?.removeAllRanges()
        window.getSelection()?.addRange(range)
      })
      const action = page.getByRole("button", { name: "Ask a side question", exact: true })
      await expect(action).toBeVisible()
      if (selection === "released") {
        // The toolbar must use its captured text even if the native selection is cleared before its click handler.
        await action.evaluate((element) => {
          element.addEventListener("click", () => window.getSelection()?.removeAllRanges(), {
            capture: true,
            once: true,
          })
        })
      }
      if (selection === "keyboard") await action.press("Enter")
      if (selection !== "keyboard" && width < 768) await action.tap()
      if (selection !== "keyboard" && width >= 768) await action.click()
      const side = page.getByRole("region", { name: "Ask a side question", exact: true })
      await expect(side).toBeVisible()
      await expectComposerText(editor, `${quote}\n\n`)
      await expect(editor).toBeFocused()
      await editor.press(`${modifier}+End`)
      await editor.pressSequentially("What does this mean?")
      await expectComposerText(editor, `${quote}\n\nWhat does this mean?`)
      const request = page.waitForRequest(`**/api/session/${session.id}/generate`)
      await page.getByRole("button", { name: "Send", exact: true }).click()
      expect((await request).postDataJSON()).toEqual({
        prompt:
          "The user is asking a quick side question about the conversation so far. " +
          "Answer directly and concisely in markdown from what you already know. " +
          `Do not call any tools and do not take any actions.\n\n${quote}\n\nWhat does this mean?`,
      })
      await expect(
        side.getByText("The selected text explains deployment configuration.", { exact: true }),
      ).toBeVisible()
      await side.getByRole("button", { name: "Dismiss side question", exact: true }).click()
      await expectComposerText(editor, "Main draft stays here")
    })
  }
}
