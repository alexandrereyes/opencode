import { useNavigate } from "@solidjs/router"
import { base64Encode } from "@opencode/util/encode"
import { useComposerState } from "@/composer/persistence"
import { extractPromptComments, extractPromptFromMessage } from "@/composer/prompt"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useData, useServer } from "@/runtime/server/current"
import { showToast } from "@/shell/notifications/toast"
import { sessionHref } from "@/shell/routes/session"
import { useWorkspaceLocation } from "@/workspaces/location"

export function createSessionFork() {
  const data = useData()
  const serverSDK = useServerSDK()
  const server = useServer()
  const location = useWorkspaceLocation()
  const prompt = useComposerState()
  const language = useLanguage()
  const navigate = useNavigate()

  return (input: { sessionID: string; messageID: string }, onFork?: () => void) => {
    const message = data.session.message.get(input.sessionID, input.messageID)
    if (message?.type !== "user") return
    const restored = extractPromptFromMessage(message, {
      directory: location().directory,
      attachmentName: language.t("common.attachment"),
    })
    const dir = base64Encode(location().directory)

    return serverSDK.api.session
      .fork({ sessionID: input.sessionID, boundary: { type: "before", messageID: input.messageID } })
      .then((forked) => {
        data.session.remember(forked)
        onFork?.()
        const target = prompt.capture({ dir, id: forked.id })
        target.set(restored)
        target.context.replaceComments(
          extractPromptComments(message).map((comment) => ({
            type: "file",
            path: comment.path,
            selection: comment.selection,
            comment: comment.comment,
            preview: comment.preview,
            commentOrigin: comment.origin,
          })),
        )
        navigate(sessionHref(server.key, forked.id))
      })
      .catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err)
        showToast({ title: language.t("common.requestFailed"), description: message })
      })
  }
}
