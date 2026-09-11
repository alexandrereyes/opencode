import { createEffect } from "solid-js"
import type { SessionInfo } from "@opencode/client/promise"

/** A visible session acknowledges the same durable idle watermark used by navigation. */
export function createSessionViewed(input: {
  session: () => SessionInfo | undefined
  view: (input: { sessionID: string; idle: number }) => Promise<void>
  remember: (session: SessionInfo) => void
}) {
  const requested = new Map<string, number>()
  createEffect(() => {
    const session = input.session()
    const idle = session?.time.idle
    if (
      !session ||
      idle === undefined ||
      idle <= (session.time.viewed ?? 0) ||
      idle <= (requested.get(session.id) ?? 0)
    )
      return
    requested.set(session.id, idle)
    void input
      .view({ sessionID: session.id, idle })
      .then(() => {
        const current = input.session()
        if (current?.id !== session.id) return
        input.remember({ ...current, time: { ...current.time, viewed: Math.max(current.time.viewed ?? 0, idle) } })
      })
      .catch(() => {
        if (requested.get(session.id) === idle) requested.delete(session.id)
      })
  })
}
