import { realpath } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

export async function sandbox(address = "http://127.0.0.1:4177", directory?: string) {
  const url = new URL(address)
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "localhost"].includes(url.hostname) ||
    ["", "4096", "4178"].includes(url.port)
  )
    throw new Error("Conversation fixtures require an isolated localhost sandbox, never production")
  const home = await realpath(
    directory ?? path.join(await realpath(os.tmpdir()), "opencode", `custom-sandbox-${url.port}`),
  )
  const owner = await Bun.file(path.join(home, "sandbox.json")).json()
  if (owner.home !== home || owner.port !== Number(url.port)) throw new Error("Sandbox ownership mismatch")
  const password = (await Bun.file(path.join(home, "password")).text()).trim()
  const headers = {
    authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
    "content-type": "application/json",
  }
  async function api<T = unknown>(
    pathname: string,
    body?: unknown,
    method = body === undefined ? "GET" : "POST",
  ): Promise<T> {
    const response = await fetch(new URL(pathname, url), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    })
    if (!response.ok) throw new Error(`${method} ${pathname}: HTTP ${response.status}`)
    if (response.status === 204) return undefined as T
    return response.json() as Promise<T>
  }
  async function rpc<T = unknown>(id: string, method: string, input: unknown) {
    return (await api<{ output: T }>(`/api/rpc/${id}/${method}`, { input })).output
  }
  return { url, home, headers, api, rpc }
}

export type ConversationSeed = {
  createdAt: number
  directory: string
  sessions: { id: string; title: string; state: string; role: string }[]
}
