/**
 * Runs `OpenCodeUITests/ChromeResourceTests` against an isolated sandbox and a real headless Chrome:
 *
 * 1. starts the login fixture (`plugin-app-custom/script/chrome-login-fixture.ts`) on a free port;
 * 2. opens Chrome through the sandbox's own shell (`POST /api/shell`), so the plugin's shell hook gives it a CDP port,
 *    exactly like an agent's `playwright-cli open`;
 * 3. registers it with the sandbox's resources hub;
 * 4. measures the field positions, runs the UI test through `test-isolated.py` and cleans up everything it created.
 *
 *   bun packages/ios-custom/script/test-chrome-resource.ts --device <udid> --derived <dir> --evidence <dir> \
 *     --server-url http://127.0.0.1:<port> --home <sandbox home> [--theme openchamber-light]
 */
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { CDP } from "../../plugin-app-custom/src/resources/adapters/cdp"
import { locate, listProcesses } from "../../plugin-app-custom/src/resources/adapters/chrome"

const args = parseArgs({
  options: {
    device: { type: "string" },
    derived: { type: "string" },
    evidence: { type: "string" },
    "server-url": { type: "string" },
    home: { type: "string" },
    theme: { type: "string", default: "openchamber-dark" },
  },
}).values
if (!args.device || !args.derived || !args.evidence || !args["server-url"] || !args.home)
  throw new Error("--device, --derived, --evidence, --server-url and --home are required")
const server = new URL(args["server-url"])
if (!["127.0.0.1", "localhost"].includes(server.hostname) || ["4096", "4178"].includes(server.port))
  throw new Error("Use an isolated loopback sandbox")

const root = path.resolve(import.meta.dirname, "../../..")
const password = (await Bun.file(path.join(args.home, "password")).text()).trim()
const auth = `Basic ${btoa(`opencode:${password}`)}`
const session = `chrome-ui-${process.pid}`
const workspace = path.join(os.tmpdir(), `chrome-ui-${process.pid}`)
await Bun.$`mkdir -p ${workspace}`.quiet()

const fixturePort = await freePort()
const fixture = Bun.spawn(
  ["bun", path.join(root, "packages/plugin-app-custom/script/chrome-login-fixture.ts"), "--port", String(fixturePort)],
  {
    stdout: "ignore",
    stderr: "inherit",
  },
)
const fixtureURL = `http://127.0.0.1:${fixturePort}`
const hubFile = path.join(args.home, "xdg/state/opencode/resources-hub/hub.json")
let resource: string | undefined

try {
  await until(
    () =>
      fetch(`${fixtureURL}/last`).then(
        (response) => response.ok,
        () => false,
      ),
    "fixture",
  )
  // RPC calls wait for the Location's plugins, so the shell hook is in place before the shell runs.
  await api("/api/rpc/custom.resources/list", { input: {} })
  const shell = await api("/api/shell", {
    command: `playwright-cli -s=${session} open --browser=chrome --device='Pixel 7' ${fixtureURL}/login`,
    cwd: workspace,
    timeout: 60_000,
  })
  const shellID: string = shell.data.id
  await until(async () => (await locate(session, await listProcesses()))?.port !== undefined, "Chrome with a CDP port")
  console.log("shell", shellID, "opened Chrome with a CDP port through the plugin's shell hook")

  // The hub's admin API stands in for discovery from the tool call.
  const hub: { port: number; secret: string } = await Bun.file(hubFile).json()
  const registered = await fetch(`http://127.0.0.1:${hub.port}/admin/resources`, {
    method: "PUT",
    headers: { authorization: `Bearer ${hub.secret}`, "content-type": "application/json" },
    body: JSON.stringify({
      kind: "chrome",
      meta: { kind: "chrome", session },
      owner: { sessionID: "ses_chrome_ui", rootSessionID: "ses_chrome_ui", agent: "build" },
      used: true,
    }),
  }).then((response) => response.json() as Promise<{ id: string }>)
  resource = registered.id

  const located = await locate(session, await listProcesses())
  const fields = await fieldPositions(located!.port!)
  const environment = path.join(workspace, "environment.json")
  await Bun.write(
    environment,
    JSON.stringify({
      OPENCODE_TEST_RESOURCE: resource,
      OPENCODE_TEST_FIXTURE_URL: fixtureURL,
      OPENCODE_TEST_FIELDS: fields.join(","),
    }),
  )
  console.log("resource", resource, "fields", fields.join(","))
  const status = Bun.spawnSync(
    [
      "python3",
      path.join(root, "packages/ios-custom/script/test-isolated.py"),
      "--device",
      args.device,
      "--derived",
      args.derived,
      "--evidence",
      args.evidence,
      "--label",
      `chrome-${args.theme}`,
      "--theme",
      args.theme,
      "--server-url",
      args["server-url"],
      "--home",
      args.home,
      "--environment",
      environment,
      "OpenCodeUITests/ChromeResourceTests",
    ],
    { stdout: "inherit", stderr: "inherit" },
  ).exitCode
  process.exitCode = status ?? 1
} finally {
  Bun.spawnSync(["playwright-cli", `-s=${session}`, "close"], { cwd: workspace, stdout: "ignore", stderr: "ignore" })
  if (resource) {
    const hub: { port: number; secret: string } = await Bun.file(hubFile).json()
    await fetch(`http://127.0.0.1:${hub.port}/admin/resources/${encodeURIComponent(resource)}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${hub.secret}` },
    }).catch(() => undefined)
  }
  fixture.kill()
  await Bun.$`rm -rf ${workspace}`.quiet()
}

async function api(pathname: string, body: unknown) {
  const response = await fetch(
    `${args["server-url"]}${pathname}?location[directory]=${encodeURIComponent(workspace)}`,
    {
      method: "POST",
      headers: { authorization: auth, "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  )
  if (!response.ok) throw new Error(`${pathname} answered ${response.status}`)
  return response.json()
}

/** Normalized vertical centers of the e-mail and password fields in the viewport (the streamed frame). */
async function fieldPositions(port: number) {
  const version: { webSocketDebuggerUrl: string } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()
  const cdp = await CDP.connect(version.webSocketDebuggerUrl)
  try {
    const page = (await cdp.send("Target.getTargets", {})).targetInfos.find(
      (info) => info.type === "page" && info.url.includes("/login"),
    )
    if (!page) throw new Error("login page not found")
    const attached = await cdp.send("Target.attachToTarget", { targetId: page.targetId, flatten: true })
    const result = await cdp.send(
      "Runtime.evaluate",
      {
        expression: `["email", "password"].map((id) => { const box = document.getElementById(id).getBoundingClientRect(); return Math.round((box.y + box.height / 2) / innerHeight * 1000) / 1000 })`,
        returnByValue: true,
      },
      attached.sessionId,
    )
    return result.result.value as number[]
  } finally {
    await cdp.close()
  }
}

async function until(condition: () => Promise<boolean>, what: string, timeout = 30_000) {
  const deadline = Date.now() + timeout
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await Bun.sleep(200)
  }
}

async function freePort() {
  const probe = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() })
  const port = probe.port
  probe.stop(true)
  return port
}
