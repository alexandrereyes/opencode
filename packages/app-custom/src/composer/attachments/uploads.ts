import { createStore } from "solid-js/store"

export type Upload = {
  id: string
  filename: string
  mime: string
  size: number
  loaded: number
  cancel: () => void
}

const [state, setState] = createStore<{ items: Upload[] }>({ items: [] })

export const uploads = {
  items: () => state.items,
  async track<T>(
    input: Pick<Upload, "id" | "filename" | "mime" | "size">,
    work: (report: (loaded: number) => void, signal: AbortSignal) => Promise<T>,
  ): Promise<T | undefined> {
    const controller = new AbortController()
    setState("items", (items) => [...items, { ...input, loaded: 0, cancel: () => controller.abort() }])
    return work((loaded) => setState("items", (item) => item.id === input.id, "loaded", loaded), controller.signal)
      .catch((error: unknown) => {
        if (controller.signal.aborted) return undefined
        throw error
      })
      .finally(() => setState("items", (items) => items.filter((item) => item.id !== input.id)))
  },
}
