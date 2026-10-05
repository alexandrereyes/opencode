import { expect, test } from "@playwright/test"
import { fixture, pageMessages } from "../smoke/session-timeline.fixture"
import { mockOpenCodeServer } from "../utils/mock-server"

test.beforeEach(async ({ page }) => {
  const sessions = fixture.sessions.map((session) => ({ ...session }))
  await mockOpenCodeServer(page, {
    sessions,
    provider: fixture.provider,
    directory: fixture.directory,
    project: fixture.project,
    pageMessages,
    tabLayout: "horizontal",
  })
  await page.goto("/")
  await page.locator('[data-component="home-session-row"]').filter({ hasText: fixture.expected.targetTitle }).click()
  await expect(page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true })).toBeVisible()
})

for (const commit of ["Enter", "blur", "click outside"]) {
  test(`saves the session heading on ${commit}`, async ({ page }) => {
    await page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true }).click()
    const input = page.locator('input[data-slot="session-title-child"]')
    await expect(input).toBeFocused()
    await input.fill("Renamed session")
    const renamed = page.waitForResponse(
      (response) =>
        response.request().method() === "PATCH" &&
        new URL(response.url()).pathname === `/api/session/${fixture.targetID}`,
    )
    if (commit === "Enter") await input.press("Enter")
    if (commit === "blur") await input.press("Tab")
    if (commit === "click outside") await page.locator('[data-component="composer-editor"]').click()
    const response = await renamed
    expect(response.status()).toBe(204)
    expect(response.request().postDataJSON()).toEqual({ title: "Renamed session" })
    await expect(page.getByRole("heading", { name: "Renamed session", exact: true })).toBeVisible()
    await expect(page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: "Renamed session" })).toBeVisible()
    await page.reload()
    await expect(page.getByRole("heading", { name: "Renamed session", exact: true })).toBeVisible()
  })
}

test("cancels the session heading with Escape", async ({ page }) => {
  await page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true }).click()
  const input = page.locator('input[data-slot="session-title-child"]')
  await input.fill("Discard this title")
  await input.press("Escape")
  await expect(page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true })).toBeVisible()
})

test("keeps the draft when saving the session heading fails", async ({ page }) => {
  await page.route(`**/api/session/${fixture.targetID}`, (route) => {
    if (route.request().method() !== "PATCH") return route.fallback()
    return route.fulfill({ status: 500, headers: { "access-control-allow-origin": "*" } })
  })
  await page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true }).click()
  const input = page.locator('input[data-slot="session-title-child"]')
  await input.fill("Retry this title")
  await input.press("Tab")
  await expect(page.getByText("Request failed", { exact: true })).toBeVisible()
  await expect(input).toBeEnabled()
  await expect(input).toHaveValue("Retry this title")
  await expect(
    page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: fixture.expected.targetTitle }),
  ).toBeVisible()
})

test("does not save an empty session heading", async ({ page }) => {
  await page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true }).click()
  const input = page.locator('input[data-slot="session-title-child"]')
  await input.fill("   ")
  await input.press("Tab")
  await expect(page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByRole("heading", { name: fixture.expected.targetTitle, exact: true })).toBeVisible()
})

test("renames and closes the session tab from its context menu", async ({ page }) => {
  const tab = page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: fixture.expected.targetTitle })
  await tab.click({ button: "right" })
  await expect(page.getByRole("menuitem", { name: "Rename", exact: true })).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.getByRole("menuitem", { name: "Rename", exact: true })).toBeHidden()
  await expect(tab).toBeFocused()
  await tab.click({ button: "right" })
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click()
  const input = page.locator('[data-slot="tab-title"][contenteditable="true"]')
  await expect(input).toBeFocused()
  await input.fill("Renamed from tab")
  const saved = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      new URL(response.url()).pathname === `/api/session/${fixture.targetID}`,
  )
  await input.press("Enter")
  expect((await saved).status()).toBe(204)
  await expect(page.getByRole("heading", { name: "Renamed from tab", exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByRole("heading", { name: "Renamed from tab", exact: true })).toBeVisible()
  const renamed = page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: "Renamed from tab" })
  await renamed.click({ button: "right" })
  await page.getByRole("menuitem", { name: "Close tab", exact: true }).click()
  await expect(renamed).toBeHidden()
  await page.getByRole("button", { name: "Home", exact: true }).click()
  await expect(
    page.locator('[data-component="home-session-row"]').filter({ hasText: "Renamed from tab" }),
  ).toBeVisible()
})

test("renames an inactive tab without switching sessions", async ({ page }) => {
  await page.getByRole("button", { name: "Home", exact: true }).click()
  await page.locator('[data-component="home-session-row"]').filter({ hasText: fixture.expected.sourceTitle }).click()
  await expect(page.getByRole("heading", { name: fixture.expected.sourceTitle, exact: true })).toBeVisible()
  const tab = page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: fixture.expected.targetTitle })
  await tab.click({ button: "right" })
  await page.getByRole("menuitem", { name: "Rename", exact: true }).click()
  const input = page.locator('[data-slot="tab-title"][contenteditable="true"]')
  await expect(input).toBeFocused()
  await input.fill("Inactive tab renamed")
  const saved = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      new URL(response.url()).pathname === `/api/session/${fixture.targetID}`,
  )
  await input.press("Tab")
  expect((await saved).status()).toBe(204)
  await expect(page.getByRole("heading", { name: fixture.expected.sourceTitle, exact: true })).toBeVisible()
  await expect(page).toHaveURL(new RegExp(`/session/${fixture.sourceID}$`))
  await page.locator('[data-slot="titlebar-tabs"] a').filter({ hasText: "Inactive tab renamed" }).click()
  await expect(page.getByRole("heading", { name: "Inactive tab renamed", exact: true })).toBeVisible()
  await page.reload()
  await expect(page.getByRole("heading", { name: "Inactive tab renamed", exact: true })).toBeVisible()
})
