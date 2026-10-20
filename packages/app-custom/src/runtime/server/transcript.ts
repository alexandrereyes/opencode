import type { OpenCodeEvent } from "@opencode/client/promise"
import { omitInlineMedia, Transcript } from "@opencode/plugin-app-custom/transcript/rpc"
import type { ServerApi } from "@/runtime/server/api"

type List = ServerApi["message"]["list"]

/**
 * Pages the transcript through the custom plugin, which empties inline tool-result media before it
 * reaches the browser. Servers without the plugin, and any failed read, use the regular endpoint,
 * which also reports its canonical errors.
 */
export function withLeanTranscript(api: ServerApi): ServerApi {
  return { ...api, message: { ...api.message, list: (input, options) => listTranscript(api, input, options) } }
}

async function listTranscript(
  api: ServerApi,
  input: Parameters<List>[0],
  options?: Parameters<List>[1],
): ReturnType<List> {
  if (input.type !== undefined) return api.message.list(input, options)
  const page = await api
    .rpc(Transcript.Definition)
    .list(
      { sessionID: input.sessionID, limit: input.limit, order: input.order, cursor: input.cursor },
      { signal: options?.signal },
    )
    .catch(() => undefined)
  if (!page) {
    options?.signal?.throwIfAborted()
    return api.message.list(input, options)
  }
  // SAFETY: The plugin encodes the same SessionMessage.Info page that the endpoint serves.
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
  return page as Awaited<ReturnType<List>>
}

/** Live tool results carry the same inline media; retained transcript rows drop it on arrival. */
export function omitEventMedia(event: OpenCodeEvent): OpenCodeEvent {
  if (event.type === "session.tool.success")
    return { ...event, data: { ...event.data, content: omitInlineMedia(event.data.content) } }
  if (event.type === "session.tool.failed" && event.data.content)
    return { ...event, data: { ...event.data, content: omitInlineMedia(event.data.content) } }
  return event
}
