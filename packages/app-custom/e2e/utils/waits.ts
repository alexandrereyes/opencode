import { expect, type Locator, type Page } from "@playwright/test"
import { base64Encode } from "@opencode/util/encode"

export const APP_READY_TIMEOUT = 30_000

export async function expectAppVisible(locator: Locator) {
  await expect(locator).toBeVisible({ timeout: APP_READY_TIMEOUT })
}

export async function expectSessionTitle(page: Page, title: string) {
  if ((page.viewportSize()?.width ?? 1280) < 768) {
    const trigger = page.locator('[data-slot="mobile-tabs-trigger"]')
    await expectAppVisible(trigger)
    await expect(trigger.locator('span[dir="auto"]')).toHaveText(title, { timeout: APP_READY_TIMEOUT })
    return
  }
  // The usage tab also has a heading that starts with the session title.
  await expectAppVisible(page.getByRole("heading", { name: title, exact: true }))
}

export async function expectSessionReady(page: Page, input: { server: string; sessionID: string; title: string }) {
  await expect(page).toHaveURL(`/server/${base64Encode(input.server)}/session/${input.sessionID}`)
  await expectSessionTitle(page, input.title)
}
