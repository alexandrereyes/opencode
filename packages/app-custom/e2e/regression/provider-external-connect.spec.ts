import { base64Encode } from "@opencode/util/encode"
import { expect, test, type Page } from "@playwright/test"
import type { OpenCodeEvent } from "@opencode/client/promise"
import { mockOpenCodeServer } from "../utils/mock-server"
import { expectSessionTitle } from "../utils/waits"

const directory = "C:/OpenCode/provider-connect"
const projectID = "proj_provider_connect"
const sessionID = "ses_provider_connect"
const title = "Provider connection"
const server = `http://${process.env.PLAYWRIGHT_SERVER_HOST ?? "127.0.0.1"}:${process.env.PLAYWRIGHT_SERVER_PORT ?? "4096"}`
const usage = "https://chatgpt.com/settings/usage"

const bedrock = {
  id: "amazon-bedrock",
  name: "Amazon Bedrock",
  methods: [
    { type: "key", label: "Bedrock API key" },
    {
      id: "aws-profile",
      type: "external",
      label: "AWS profile (SSO or named profile)",
      form: [
        {
          key: "profile",
          type: "string",
          title: "AWS profile",
          description: "Found 2 profiles in ~/.aws/config and ~/.aws/credentials on the server.",
          required: true,
          placeholder: "Profile name",
          custom: true,
          options: [
            { value: "default", label: "default" },
            { value: "sso-dev", label: "sso-dev" },
          ],
        },
      ],
    },
  ],
  connections: [],
}

const vertex = {
  id: "google-vertex",
  name: "Vertex",
  methods: [
    { type: "key" },
    {
      id: "google-adc",
      type: "external",
      label: "Google Cloud credentials (gcloud auth or environment)",
      form: [
        {
          key: "project",
          type: "string",
          title: "Google Cloud project",
          description: "No projects found in your gcloud configuration.",
          required: true,
          placeholder: "Project ID",
          custom: true,
          options: [],
        },
        {
          key: "location",
          type: "string",
          title: "Location",
          required: true,
          placeholder: "Location",
          custom: true,
          default: "global",
          options: [
            { value: "global", label: "global" },
            { value: "us", label: "us" },
          ],
        },
      ],
    },
  ],
  connections: [],
}

const openai = (connections: unknown[]) => ({
  id: "openai",
  name: "OpenAI",
  methods: [
    { id: "chatgpt-token-sharing", type: "oauth", label: "ChatGPT Pro/Plus (browser)" },
    { type: "key", label: "API key" },
  ],
  connections,
})

for (const viewport of [
  { name: "desktop", width: 1440, height: 900 },
  { name: "phone", width: 390, height: 844 },
]) {
  test.describe(viewport.name, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } })

    test("connects an external method with a custom choice answer after a failed attempt", async ({ page }) => {
      const requests: unknown[] = []
      const pending = { release: Promise.withResolvers<void>(), fail: true }
      await session(page)
      await integrations(page, () => [bedrock])
      await page.route("**/api/integration/amazon-bedrock/connect/external**", async (route) => {
        if (route.request().method() === "OPTIONS") return route.fallback()
        requests.push({
          directory: new URL(route.request().url()).searchParams.get("location[directory]"),
          body: route.request().postDataJSON(),
        })
        if (!pending.fail) return route.fulfill({ status: 204, headers: cors })
        pending.fail = false
        await pending.release.promise
        return route.fulfill({
          status: 400,
          headers: cors,
          json: { _tag: "InvalidRequestError", message: "AWS profile my-sso was not found on the server" },
        })
      })

      await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
      await expectSessionTitle(page, title)
      const dialog = await openConnect(page)
      await dialog.getByRole("searchbox", { name: "Search providers" }).fill("bedrock")
      await dialog.getByRole("button", { name: /^Amazon Bedrock/ }).click()
      await dialog.getByRole("button", { name: "AWS profile (SSO or named profile)" }).click()

      const choices = dialog.getByRole("radiogroup", { name: "AWS profile" })
      await expect(choices).toBeVisible()
      await expect(dialog.getByText("on the server.", { exact: false })).toBeVisible()
      // A loopback server is this device, so no server-scope notice is needed.
      await expect(dialog.locator('[data-component="provider-connect-remote"]')).toHaveCount(0)
      const own = choices.getByRole("radio", { name: "Type your own answer" })
      // The radio input is visually hidden; people choose through its label.
      const choose = (name: string) =>
        choices.locator('[data-slot="radio-v2-item-label"]').getByText(name, { exact: true }).click()
      const proceed = dialog.getByRole("button", { name: "Continue", exact: true })
      await expect(proceed).toBeDisabled()
      await choose("Type your own answer")
      const answer = dialog.getByRole("textbox", { name: "Type your own answer" })
      await expect(answer).toBeFocused()
      await expect(answer).toHaveAttribute("placeholder", "Profile name")
      await answer.fill("my-sso")
      await choose("default")
      await expect(choices.getByRole("radio", { name: "default" })).toBeChecked()
      await expect(answer).toBeHidden()
      await expect(proceed).toBeEnabled()
      await choose("Type your own answer")
      await expect(own).toBeChecked()
      await expect(answer).toHaveValue("my-sso")
      await screenshot(page, `external-form-${viewport.name}`)
      await proceed.click()

      await expect(dialog.getByText("Authorization in progress…")).toBeVisible()
      await expect(dialog.getByRole("button", { name: "Open browser" })).toHaveCount(0)
      await screenshot(page, `external-pending-${viewport.name}`)
      pending.release.resolve()
      await expect(dialog.getByRole("alert")).toHaveText(
        "Authorization failed: AWS profile my-sso was not found on the server",
      )
      await screenshot(page, `external-error-${viewport.name}`)
      await dialog.getByRole("button", { name: "Try again" }).click()

      await expect(choices).toBeVisible()
      await choose("sso-dev")
      await proceed.click()
      await expect(dialog).toBeHidden()
      await expect(page.getByText("Amazon Bedrock connected", { exact: true })).toBeVisible()
      await screenshot(page, `external-success-${viewport.name}`)
      expect(requests).toEqual([
        { directory, body: { methodID: "aws-profile", answer: { profile: "my-sso" } } },
        { directory, body: { methodID: "aws-profile", answer: { profile: "sso-dev" } } },
      ])
    })

    test("advances through choice fields with visible defaults and a typed answer", async ({ page }) => {
      const requests: unknown[] = []
      await session(page)
      await integrations(page, () => [vertex])
      await page.route("**/api/integration/google-vertex/connect/external**", (route) => {
        if (route.request().method() === "OPTIONS") return route.fallback()
        requests.push(route.request().postDataJSON())
        return route.fulfill({ status: 204, headers: cors })
      })

      await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
      await expectSessionTitle(page, title)
      const dialog = await openConnect(page)
      await dialog.getByRole("searchbox", { name: "Search providers" }).fill("vertex")
      await dialog.getByRole("button", { name: /^Vertex/ }).click()
      await dialog.getByRole("button", { name: "Google Cloud credentials (gcloud auth or environment)" }).click()

      const project = dialog.getByRole("radiogroup", { name: "Google Cloud project" })
      await expect(project.getByRole("radio")).toHaveCount(1)
      await project.locator('[data-slot="radio-v2-item-label"]').getByText("Type your own answer").click()
      await dialog.getByRole("textbox", { name: "Type your own answer" }).fill("fixture-project")
      await dialog.getByRole("button", { name: "Continue", exact: true }).click()

      const location = dialog.getByRole("radiogroup", { name: "Location" })
      await expect(location.getByRole("radio", { name: "global" })).toBeChecked()
      await expect(location.getByRole("radio", { name: "Type your own answer" })).not.toBeChecked()
      await expect(dialog.getByRole("textbox", { name: "Type your own answer" })).toBeHidden()
      await screenshot(page, `external-default-${viewport.name}`)
      await dialog.getByRole("button", { name: "Continue", exact: true }).click()
      await expect(dialog).toBeHidden()
      expect(requests).toEqual([{ methodID: "google-adc", answer: { project: "fixture-project", location: "global" } }])
    })

    test("shows the ChatGPT guidance once after connecting with token sharing", async ({ context, page }) => {
      const connects: unknown[] = []
      await session(page)
      await integrations(page, () => [openai([])])
      await context.route("https://auth.example/chatgpt**", (route) =>
        route.fulfill({ contentType: "text/html", body: "<!doctype html><title>ChatGPT sign-in</title>" }),
      )
      await page.route("**/api/integration/openai/connect/oauth**", (route) => {
        if (route.request().method() === "OPTIONS") return route.fallback()
        if (route.request().method() === "GET")
          return route.fulfill({
            headers: cors,
            json: {
              location: { directory },
              data: { status: "complete", time: { created: 1_700_000_000_000, expires: 4_000_000_000_000 } },
            },
          })
        connects.push(route.request().postDataJSON())
        return route.fulfill({
          headers: cors,
          json: {
            location: { directory },
            data: {
              attemptID: `attempt_chatgpt_${connects.length}`,
              url: "https://auth.example/chatgpt",
              instructions: "Sign in to ChatGPT",
              mode: "auto",
              time: { created: 1_700_000_000_000, expires: 4_000_000_000_000 },
            },
          },
        })
      })
      await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
      await expectSessionTitle(page, title)
      for (const attempt of [1, 2]) {
        const dialog = await openConnect(page)
        await dialog.getByRole("searchbox", { name: "Search providers" }).fill("openai")
        await dialog.getByRole("button", { name: /^OpenAI/ }).click()
        const popup = page.context().waitForEvent("page")
        await dialog.getByRole("button", { name: /^ChatGPT Pro\/Plus/ }).click()
        await (await popup).close()
        await expect(page.getByText("OpenAI connected", { exact: true })).toBeVisible()
        await expect(dialog.getByRole("button", { name: /^ChatGPT Pro\/Plus/ })).toBeHidden()
        const welcome = page.getByRole("dialog", { name: "ChatGPT connected", exact: true })
        if (attempt === 2) {
          await expect(page.getByRole("dialog")).toHaveCount(0)
          continue
        }
        await expect(welcome).toBeVisible()
        await expect(welcome.getByText("Eligible requests in OpenCode can use your ChatGPT plan.")).toBeVisible()
        await expect(welcome.getByRole("link", { name: "Manage usage in ChatGPT settings" })).toHaveAttribute(
          "href",
          usage,
        )
        await screenshot(page, `chatgpt-welcome-${viewport.name}`)
        await welcome.getByRole("button", { name: "Got it" }).click()
        await expect(welcome).toBeHidden()
      }
      expect(connects).toEqual([{ methodID: "chatgpt-token-sharing" }, { methodID: "chatgpt-token-sharing" }])
    })

    test("shows the ChatGPT usage limit once per day for ChatGPT limit failures only", async ({ context, page }) => {
      const events: OpenCodeEvent[] = []
      await session(page, () => events.splice(0))
      await context.route(`${usage}**`, (route) =>
        route.fulfill({ contentType: "text/html", body: "<!doctype html><title>ChatGPT usage</title>" }),
      )
      await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
      await expectSessionTitle(page, title)
      await expect(page.getByRole("textbox", { name: "Prompt", exact: true })).toBeEditable()

      events.push(failed("evt_rate_limit", "Rate limit exceeded"))
      events.push(
        failed("evt_chatgpt_limit", "ChatGPT usage limit reached. Check ChatGPT Settings → Usage for details."),
      )
      const limit = page.getByRole("dialog", { name: "ChatGPT usage limit reached", exact: true })
      await expect(limit).toBeVisible()
      await expect(page.getByRole("dialog")).toHaveCount(1)
      await expect(limit.getByText("Check your usage and limits in ChatGPT settings.")).toBeVisible()
      await screenshot(page, `chatgpt-usage-limit-${viewport.name}`)
      const popup = context.waitForEvent("page")
      await limit.getByRole("button", { name: "Manage usage" }).click()
      const opened = await popup
      await expect(opened).toHaveURL(usage)
      await opened.close()
      await expect(limit).toBeHidden()

      const seen = await page.evaluate(() =>
        Object.entries(localStorage).find(([key]) => key.includes("chatgpt-usage-limit")),
      )
      expect(seen?.[1]).toContain("lastSeenAt")
      events.push(
        failed("evt_chatgpt_again", "ChatGPT usage limit reached. Check ChatGPT Settings → Usage for details."),
      )
      await expect.poll(() => events.length).toBe(0)
      await expect(page.getByRole("dialog")).toHaveCount(0)
    })

    for (const item of [
      { method: "oauth", shown: true },
      { method: "key", shown: false },
    ]) {
      test(`model selector ${item.shown ? "shows" : "hides"} the ChatGPT plan for an OpenAI ${item.method} connection`, async ({
        page,
      }) => {
        await session(page)
        await integrations(page, () => [
          openai([{ type: "credential", id: "cred_openai", label: "OpenAI", method: item.method }]),
        ])
        const integrationList = page.waitForResponse(
          (response) => new URL(response.url()).pathname === "/api/integration",
        )
        await page.goto(`/server/${base64Encode(server)}/session/${sessionID}`)
        await expectSessionTitle(page, title)
        const control = page.locator('[data-action="composer-model"]')
        await expect(control).toContainText("GPT Fixture")
        await control.click()
        await integrationList
        await expect(page.getByPlaceholder("Search models", { exact: true })).toBeFocused()
        const plan = page.locator('[data-slot="model-selector-chatgpt-plan"]')
        if (!item.shown) {
          await expect(page.getByRole("button", { name: "Manage models" })).toBeVisible()
          await expect(plan).toHaveCount(0)
          return
        }
        await expect(plan).toContainText("Using ChatGPT plan")
        await expect(plan.getByRole("link", { name: "Manage usage" })).toHaveAttribute("href", usage)
        await screenshot(page, `chatgpt-model-selector-${viewport.name}`)
      })
    }
  })
}

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
}

async function session(page: Page, events?: () => OpenCodeEvent[]) {
  await mockOpenCodeServer(page, {
    directory,
    project: {
      id: projectID,
      worktree: directory,
      vcs: "git",
      name: "provider-connect",
      time: { created: 1_700_000_000_000, updated: 1_700_000_000_000 },
      sandboxes: [],
    },
    provider: {
      all: [
        {
          id: "openai",
          name: "OpenAI",
          models: { "gpt-fixture": { id: "gpt-fixture", name: "GPT Fixture", limit: { context: 200_000 } } },
        },
      ],
      connected: ["openai"],
      default: { providerID: "openai", modelID: "gpt-fixture" },
    },
    sessions: [{ id: sessionID, projectID, directory, title }],
    pageMessages: () => ({ items: [] }),
    events,
  })
  await page.addInitScript(() => {
    localStorage.setItem(
      "opencode.global.dat:model",
      JSON.stringify({
        user: [{ providerID: "openai", modelID: "gpt-fixture", visibility: "show" }],
        recent: [{ providerID: "openai", modelID: "gpt-fixture" }],
        variant: {},
      }),
    )
  })
}

async function integrations(page: Page, list: () => { id: string }[]) {
  await page.route("**/api/integration**", (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback()
    const path = new URL(route.request().url()).pathname
    if (path === "/api/integration")
      return route.fulfill({ headers: cors, json: { location: { directory }, data: list() } })
    const match = list().find((item) => path === `/api/integration/${item.id}`)
    if (!match) return route.fallback()
    return route.fulfill({ headers: cors, json: { location: { directory }, data: match } })
  })
}

async function openConnect(page: Page) {
  await page.locator('[data-action="composer-model"]').click()
  await page.getByRole("button", { name: "Manage models" }).click()
  await page.getByRole("button", { name: "Connect provider" }).click()
  const dialog = page.getByRole("dialog")
  await expect(dialog.getByRole("searchbox", { name: "Search providers" })).toBeVisible()
  return dialog
}

function failed(id: string, message: string): OpenCodeEvent {
  return {
    id,
    created: Date.now(),
    type: "session.step.failed",
    durable: { aggregateID: sessionID, seq: 1, version: 1 },
    location: { directory },
    data: {
      sessionID,
      assistantMessageID: "msg_provider_connect",
      error: { type: "provider.rate-limit", message, status: 429 },
    },
  }
}

async function screenshot(page: Page, name: string) {
  await page.screenshot({
    path: `${process.env.P4_SCREENSHOTS ?? "e2e/test-results/provider-external-connect"}/${name}.png`,
  })
}
