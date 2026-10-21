import { join } from "node:path"

const url = process.argv[2] ?? "http://127.0.0.1:4177"
const password =
  process.env.OPENCODE_SERVER_PASSWORD ??
  (process.env.OPENCODE_SERVER_PASSWORD_FILE
    ? (await Bun.file(process.env.OPENCODE_SERVER_PASSWORD_FILE).text()).trim()
    : undefined)
const headers = {
  "Content-Type": "application/json",
  ...(password ? { Authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` } : {}),
}
const root = join(import.meta.dir, "../OpenCodeKit/Tests/OpenCodeKitTests/Fixtures")
async function request(path: string, input?: unknown) {
  const response = await fetch(url + path, {
    headers,
    ...(input ? { method: "POST", body: JSON.stringify({ input }) } : {}),
  })
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`)
  return response.json()
}
function scrub(value: unknown): unknown {
  if (typeof value === "string") {
    if (value.includes("@")) return "conta@example.invalid"
    if (value.startsWith("/private/") || value.startsWith("/Users/")) {
      return value.includes("/repos/") ? `/sandbox/repos/${value.split("/repos/")[1]}` : "/sandbox"
    }
    return value
  }
  if (Array.isArray(value)) return value.map(scrub)
  if (value && typeof value === "object")
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, scrub(item)]))
  return value
}
async function save(name: string, value: unknown) {
  await Bun.write(join(root, `${name}.json`), JSON.stringify(scrub(value), null, 2) + "\n")
}
const navigation = await request("/api/rpc/custom.navigation/list", { limit: 500 })
await save("navigation", navigation)
await save("preferences", await request("/api/rpc/custom.preferences/get", {}))
await save("subscriptions", await request("/api/rpc/custom.subscriptions/list", {}))
await save("projects", await request("/api/project"))
await save("active", await request("/api/session/active"))
await save("permissions", await request("/api/rpc/custom.requests/permissions", {}))
await save("sessions", await request("/api/session?parentID=null&limit=500"))
for (const [name, predicate] of [
  ["running", (row: { session: { title: string } }) => row.session.title === "Alternativas Linear open source"],
  ["image", (row: { session: { title: string } }) => row.session.title === "Landing nova"],
  ["user", (row: { session: { title: string } }) => row.session.title === "Revisar próximos passos"],
] as const) {
  const row = navigation.output.data.find(predicate)
  if (row)
    await save(
      `transcript-${name}`,
      await request("/api/rpc/custom.transcript/list", { sessionID: row.session.id, limit: 3, order: "desc" }),
    )
}
const question = navigation.output.data.find((row: { questionAt?: number }) => row.questionAt !== undefined)
if (question)
  await save(
    "forms",
    await request(`/api/form?location%5Bdirectory%5D=${encodeURIComponent(question.session.location.directory)}`),
  )
console.log("Captured scrubbed live contracts")
