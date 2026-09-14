import { Context } from "effect"
import type { ServerResponse } from "node:http"

/** Transport capability, intentionally absent from in-process/SDK requests. */
export class AfterResponse extends Context.Service<AfterResponse, (callback: () => void) => void>()(
  "@opencode/server/AfterResponse",
) {}

export function afterResponse(response: ServerResponse) {
  return (callback: () => void) => {
    const close = () => response.off("finish", finish)
    const finish = () => {
      response.off("close", close)
      if (response.statusCode >= 200 && response.statusCode < 300) callback()
    }
    response.once("finish", finish)
    response.once("close", close)
  }
}
