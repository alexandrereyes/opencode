import type { ResourceProtocol } from "../protocol.js"

type Input = ResourceProtocol.Input
type Item = { readonly token: string; readonly event: Input }

/** Pending inputs per resource; beyond this the hub refuses new ones (lifting a finger is always accepted). */
export const inputQueueLimit = 128

/**
 * One resource's input queue. Inputs run one at a time, in order, and only while the control token that queued them
 * still holds the resource: giving control back (or another take) discards whatever is still pending, and `reset`
 * lifts the fingers left on the screen once the input in flight finishes.
 *
 * The queue stays short because consecutive moves of the same finger collapse into the newest position (a slow
 * adapter skips intermediate positions instead of replaying them late) and adjacent text joins into one insert.
 * `began`/`ended`/`cancelled`, keys, buttons and text keep their order. After Expo serve-emu's
 * `control-input-queue.ts` (expo-device-hub rev 42918bc).
 */
export function makeInputQueue(options: {
  readonly apply: (event: Input) => Promise<void>
  /** Whether `token` still holds control; checked before each input runs. */
  readonly holds: (token: string) => boolean
  /** An input failed; never pass the event on (text may be a password). */
  readonly failed: (error: unknown) => void
  readonly limit?: number
}) {
  const limit = options.limit ?? inputQueueLimit
  const queue: Item[] = []
  /** Fingers down on the resource, from the inputs applied so far. */
  const contacts = new Map<number, { x: number; y: number }>()
  const state = { running: undefined as Promise<void> | undefined, lift: false }

  const push = (item: Item) => {
    const event = item.event
    if (event.type === "touch" && event.phase === "moved") {
      const pointer = event.pointer ?? 0
      // The newest queued move of this finger, if only other fingers' moves follow it.
      const index = queue.findLastIndex((queued) => !(isMove(queued.event) && (queued.event.pointer ?? 0) !== pointer))
      const found = queue[index]
      if (found && found.token === item.token && isMove(found.event)) {
        queue[index] = item
        return true
      }
    }
    const last = queue.at(-1)
    if (event.type === "text" && last?.token === item.token && last.event.type === "text") {
      queue[queue.length - 1] = { token: item.token, event: { type: "text", text: last.event.text + event.text } }
      return true
    }
    const lifting = event.type === "touch" && (event.phase === "ended" || event.phase === "cancelled")
    if (queue.length >= limit && !lifting) return false
    queue.push(item)
    return true
  }

  const track = (event: Input) => {
    if (event.type !== "touch") return
    const pointer = event.pointer ?? 0
    if (event.phase === "ended" || event.phase === "cancelled") return void contacts.delete(pointer)
    contacts.set(pointer, { x: event.x, y: event.y })
  }

  const next = async (): Promise<void> => {
    if (state.lift) {
      state.lift = false
      const lifted = [...contacts.entries()]
      contacts.clear()
      await lifted.reduce(
        (chain, [pointer, at]) =>
          chain.then(() =>
            options
              .apply({ type: "touch", phase: "cancelled", x: at.x, y: at.y, ...(pointer ? { pointer } : {}) })
              .catch(options.failed),
          ),
        Promise.resolve(),
      )
      return next()
    }
    const item = queue.shift()
    if (!item) return
    if (!options.holds(item.token)) {
      queue.length = 0
      return next()
    }
    track(item.event)
    await options.apply(item.event).catch(options.failed)
    return next()
  }

  const kick = () => {
    if (state.running) return
    state.running = next().finally(() => {
      state.running = undefined
      if (queue.length > 0 || state.lift) kick()
    })
  }

  return {
    /** Queues `events`; `false` when the queue was full and some were refused. */
    enqueue(token: string, events: readonly Input[]) {
      const accepted = events.map((event) => push({ token, event })).every(Boolean)
      kick()
      return accepted
    },
    /**
     * Control ended: drop pending inputs and lift the fingers still down. Resolves once the input in flight and the
     * lifting are done, so the hand-back is announced only after the last input took effect.
     */
    reset() {
      queue.length = 0
      if (contacts.size > 0) {
        state.lift = true
        kick()
      }
      return idle()
    },
    get size() {
      return queue.length
    },
    /** Resolves when nothing is running or pending. */
    idle,
  }

  async function idle(): Promise<void> {
    if (!state.running) return
    await state.running
    return idle()
  }
}

function isMove(event: Input): event is Extract<Input, { type: "touch" }> {
  return event.type === "touch" && event.phase === "moved"
}
