import { expect, test, type Page, type Request, type Route } from "@playwright/test"

// Addresses of mocked OpenCode servers; requests never leave the browser, and the unreachable one is refused.
const first = "http://127.0.0.1:4098"
const second = "http://127.0.0.1:4099"
const unreachable = "http://127.0.0.1:4179"

test.use({ serviceWorkers: "block" })

test("a QR payload with several addresses pairs and keeps the first address that works with its token", async ({
  page,
}) => {
  // Both addresses reach one server. The second spends the code first, so the first answers 401, and the token works on
  // it as on every address of that server.
  await mockServer(page, { url: first, password: () => "session-token", pairing: { code: "spent-elsewhere" } })
  await mockServer(page, {
    url: second,
    password: () => "session-token",
    pairing: { code: "one-time-code", token: "session-token" },
  })
  const editor = await openAddServer(page)
  await editor
    .getByPlaceholder("http://localhost:4096")
    .fill(JSON.stringify({ code: "one-time-code", urls: [first, second] }))
  await editor.getByRole("button", { name: "Add server", exact: true }).click()

  await expect(editor).toBeHidden()
  const names = page.getByTestId("settings-screen").locator(".settings-servers-name")
  await expect(names.filter({ hasText: "127.0.0.1:4098" })).toHaveCount(1)
  await expect(names.filter({ hasText: "127.0.0.1:4099" })).toHaveCount(0)
})

test("a pairing link whose server cannot be reached says so instead of calling the link expired", async ({ page }) => {
  await page.route(`${unreachable}/**`, (route) => route.abort("connectionrefused"))
  const editor = await openAddServer(page)
  await editor.getByPlaceholder("http://localhost:4096").fill(`${unreachable}/auth/connect/one-time-code`)
  await editor.getByRole("button", { name: "Add server", exact: true }).click()

  await expect(editor.getByRole("alert")).toHaveText(
    `Could not reach ${unreachable}. Check that this device can reach the server, then try again.`,
  )
})

test("a server signed in again with a new password stops using the old one", async ({ page }) => {
  const accepted = { password: "old-password" }
  const events: Array<string | null> = []
  page.on("request", (request) => {
    if (isEvent(request, first)) events.push(request.headers()["authorization"] ?? null)
  })
  await mockServer(page, { url: first, password: () => accepted.password })
  await page.addInitScript((url) => {
    localStorage.setItem(
      "opencode.global.dat:server",
      JSON.stringify({ list: [{ type: "http", displayName: "Remote", http: { url, password: "old-password" } }] }),
    )
  }, first)
  await page.goto("/")
  // The server's controller connects to its event stream with the saved password.
  await expect.poll(() => events.includes(basic("old-password"))).toBe(true)

  await page.keyboard.press("Control+,")
  const settings = page.getByTestId("settings-screen")
  await settings.getByRole("tab", { name: "Servers" }).click()
  const row = settings.locator(".settings-servers-row").filter({ hasText: "Remote" })
  await row.getByRole("button", { name: "More options", exact: true }).click()
  await page.getByRole("menuitem", { name: "Edit", exact: true }).click()
  const editor = page.getByRole("dialog", { name: "Edit server" })
  await editor.getByPlaceholder("password").fill("new-password")
  // The server now rejects the old password, as after `opencode service set password`.
  accepted.password = "new-password"
  await editor.getByRole("button", { name: "Save", exact: true }).click()
  await expect(editor).toBeHidden()

  // A new controller reconnects with the saved password, and the old one no longer retries with the rejected one.
  const saved = events.length
  await expect
    .poll(() => events.slice(saved).filter((auth) => auth === basic("new-password")).length)
    .toBeGreaterThan(1)
  const renewed = events.indexOf(basic("new-password"), saved)
  expect(events.slice(renewed).filter((auth) => auth === basic("old-password"))).toEqual([])
})

async function openAddServer(page: Page) {
  await page.goto("/")
  await page.keyboard.press("Control+,")
  const settings = page.getByTestId("settings-screen")
  await expect(settings).toBeVisible()
  await settings.getByRole("tab", { name: "Servers" }).click()
  await settings.getByRole("button", { name: "Add server" }).click()
  return page.getByRole("dialog", { name: "Add server" })
}

// Answers 401 unless a request carries the current password. `GET /auth/connect/:code` redeems `pairing.code` once for
// `pairing.token` and answers 401 otherwise, as the real server does.
async function mockServer(
  page: Page,
  input: { url: string; password: () => string; pairing?: { code: string; token?: string } },
) {
  const pairing = { redeemed: false }
  await page.route(`${input.url}/**`, (route) => {
    const request = route.request()
    const url = new URL(request.url())
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors(request) })
    if (url.pathname.startsWith("/auth/connect/")) {
      const code = url.pathname.slice("/auth/connect/".length)
      if (!input.pairing?.token || code !== input.pairing.code || pairing.redeemed)
        return json(route, { _tag: "UnauthorizedError", message: "Pairing link expired or already used" }, 401)
      pairing.redeemed = true
      return json(route, { token: input.pairing.token })
    }
    if (request.headers()["authorization"] !== basic(input.password()))
      return json(route, { _tag: "UnauthorizedError", message: "Authentication required" }, 401)
    if (url.pathname === "/api/event")
      return route.fulfill({
        status: 200,
        headers: { ...cors(request), "content-type": "text/event-stream" },
        body: 'data: {"id":"evt_connected","type":"server.connected","data":{}}\n\n',
      })
    if (url.pathname === "/api/info")
      return json(route, { version: "2.0.26", pid: 1, urls: [input.url], paths: {}, capabilities: {} })
    return json(route, {})
  })
}

function cors(request: Request) {
  const headers = request.headers()
  return {
    "access-control-allow-origin": headers["origin"] ?? "*",
    "access-control-allow-credentials": "true",
    "access-control-allow-headers": headers["access-control-request-headers"] ?? "*",
    "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  }
}

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({
    status,
    headers: { ...cors(route.request()), "content-type": "application/json" },
    body: JSON.stringify(body),
  })
}

function basic(password: string) {
  return `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
}

function isEvent(request: Request, server: string) {
  const url = new URL(request.url())
  return url.origin === server && url.pathname === "/api/event"
}
