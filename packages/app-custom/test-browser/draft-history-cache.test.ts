import { expect, test } from "bun:test"
import { resolveObjectURL } from "node:buffer"
import { createDraftStore, resolveBlobUrl } from "@/runtime/persistence/drafts"

function fixture(id: string, getBlob: () => Promise<Blob | null>) {
  const documents = new Map([
    ["history", JSON.stringify({ entries: [{ prompt: [{ type: "image", blob: { id } }] }] })],
    ["draft", JSON.stringify({ prompt: [{ type: "image", blob: { id } }] })],
  ])
  const store = createDraftStore({
    get: async (key) => documents.get(key) ?? null,
    set: async (key, value) => {
      documents.set(key, value)
      return []
    },
    remove: async (key) => void documents.delete(key),
    putBlob: async () => id,
    getBlob,
  })
  return { store, documents }
}

test("deduplicates concurrent history and draft reads without invalidating either live reference", async () => {
  const pending = Promise.withResolvers<Blob | null>()
  const started = Promise.withResolvers<void>()
  let reads = 0
  const { store } = fixture("history-cache-concurrent", () => {
    reads++
    started.resolve()
    return pending.promise
  })
  const history = await store.getItem("history")
  const draft = await store.getItem("draft")
  expect(reads).toBe(0)
  const first = resolveBlobUrl(JSON.parse(history!).entries[0].prompt[0].blob)
  const second = resolveBlobUrl(JSON.parse(draft!).prompt[0].blob)
  await started.promise
  pending.resolve(new Blob(["shared screenshot"]))
  const [a, b] = await Promise.all([first, second])
  expect(a).toBe(b)
  const reference = { id: "history-cache-concurrent", url: a! }
  expect(reads).toBe(1)
  await store.removeItem("history")
  expect(await resolveObjectURL(reference.url)?.text()).toBe("shared screenshot")
  expect(JSON.parse((await store.getItem("draft"))!).prompt[0].blob).toEqual(reference)
  expect(reads).toBe(1)
})

test("hydrates repeated references once within one history document", async () => {
  let reads = 0
  const { store, documents } = fixture("history-cache-repeated", async () => {
    reads++
    return new Blob(["repeated screenshot"])
  })
  documents.set(
    "history",
    JSON.stringify({
      entries: Array.from({ length: 100 }, () => ({
        prompt: [{ type: "image", blob: { id: "history-cache-repeated" } }],
      })),
    }),
  )
  const value = JSON.parse((await store.getItem("history"))!)
  expect(value.entries).toHaveLength(100)
  expect(reads).toBe(0)
  await Promise.all(
    value.entries.map((entry: { prompt: { blob: { id: string } }[] }) => resolveBlobUrl(entry.prompt[0].blob)),
  )
  expect(
    new Set(value.entries.map((entry: { prompt: { blob: { url: string } }[] }) => entry.prompt[0].blob.url)).size,
  ).toBe(1)
  expect(reads).toBe(1)
})

test("reuses a live URL on remount but reads the latest document", async () => {
  let reads = 0
  const { store, documents } = fixture("history-cache-remount", async () => {
    reads++
    return new Blob(["saved screenshot"])
  })
  const first = JSON.parse((await store.getItem("history"))!)
  first.entries[0].prompt[0].blob.url = await resolveBlobUrl(first.entries[0].prompt[0].blob)
  const changed = JSON.parse(documents.get("history")!)
  changed.entries[0].prompt.unshift({ type: "text", content: "new admission" })
  documents.set("history", JSON.stringify(changed))
  const second = JSON.parse((await store.getItem("history"))!)
  expect(second.entries[0].prompt[0].content).toBe("new admission")
  expect(second.entries[0].prompt[1].blob).toEqual(first.entries[0].prompt[0].blob)
  expect(reads).toBe(1)
})

test("reuses a just-stored attachment without a round trip", async () => {
  let reads = 0
  const { store } = fixture("history-cache-put", async () => {
    reads++
    return new Blob(["unexpected read"])
  })
  const reference = await store.putBlob(new Blob(["pending admission"]))
  expect(JSON.parse((await store.getItem("draft"))!).prompt[0].blob).toEqual(reference)
  expect(reads).toBe(0)
  expect(await resolveObjectURL(reference.url)?.text()).toBe("pending admission")
})

test("does not retain a missing blob result", async () => {
  let reads = 0
  const { store } = fixture("history-cache-missing", async () => (++reads === 1 ? null : new Blob(["arrived"])))
  expect(await resolveBlobUrl(JSON.parse((await store.getItem("draft"))!).prompt[0].blob)).toBeUndefined()
  expect(await resolveBlobUrl(JSON.parse((await store.getItem("draft"))!).prompt[0].blob)).toStartWith("blob:")
  expect(reads).toBe(2)
})

test("retries after a failed blob read", async () => {
  let reads = 0
  const { store } = fixture("history-cache-failure", async () => {
    if (++reads === 1) throw new Error("temporary storage failure")
    return new Blob(["recovered"])
  })
  const ref = JSON.parse((await store.getItem("history"))!).entries[0].prompt[0].blob
  await expect(resolveBlobUrl(ref)).rejects.toThrow("temporary storage failure")
  expect(await resolveBlobUrl(ref)).toStartWith("blob:")
  expect(reads).toBe(2)
})

test("keeps different blob IDs independent", async () => {
  const reads: string[] = []
  const store = createDraftStore({
    get: async () => JSON.stringify(["history-cache-first", "history-cache-second"].map((id) => ({ blob: { id } }))),
    set: async () => [],
    remove: async () => {},
    putBlob: async () => "unused",
    getBlob: async (id) => {
      reads.push(id)
      return new Blob([id])
    },
  })
  const value = JSON.parse((await store.getItem("history"))!)
  await Promise.all(
    value.map(async (item: { blob: { id: string; url?: string } }) => {
      item.blob.url = await resolveBlobUrl(item.blob)
    }),
  )
  expect(value[0].blob.url).not.toBe(value[1].blob.url)
  expect(
    await Promise.all(value.map((item: { blob: { url: string } }) => resolveObjectURL(item.blob.url)?.text())),
  ).toEqual(reads)
  expect(reads).toEqual(["history-cache-first", "history-cache-second"])
})
