import type { AISDKHooks } from "@opencode/plugin/effect/aisdk"
import { Model } from "@opencode/schema/model"
import { Provider } from "@opencode/schema/provider"

export const providerID = Provider.ID.make("voz-eco")
export const model = Model.Ref.parse("voz-eco/transcricao")
export const notice = "Esta sessão registra conversas por voz. Para pedir algo, use a Sessão mestra."
type Language = NonNullable<AISDKHooks["language"]["language"]>

export function eco(): Language {
  return {
    specificationVersion: "v3",
    provider: providerID,
    modelId: model.id,
    supportedUrls: {},
    async doGenerate() {
      throw new Error("Voice transcription only supports streaming")
    },
    async doStream(options) {
      const text = options.headers?.["x-voz-reply"]
      return {
        stream: new ReadableStream({
          start(controller) {
            controller.enqueue({ type: "stream-start", warnings: [] })
            controller.enqueue({ type: "text-start", id: "voice" })
            controller.enqueue({
              type: "text-delta",
              id: "voice",
              delta: text === undefined ? notice : decodeURIComponent(text),
            })
            controller.enqueue({ type: "text-end", id: "voice" })
            controller.enqueue({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: {
                inputTokens: { total: 0, noCache: 0, cacheRead: 0, cacheWrite: 0 },
                outputTokens: { total: 0, text: 0, reasoning: 0 },
              },
            })
            controller.close()
          },
        }),
      }
    },
  }
}
