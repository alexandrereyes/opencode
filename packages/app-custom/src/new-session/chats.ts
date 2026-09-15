import type { ServerSDK } from "@/runtime/server/client"
import type { ServerConnection } from "@/runtime/server/registry"
import type { PromptModel } from "@/composer/state"
import type { useTabs } from "@/shell/tabs/tabs"
import { allocateChat } from "@/runtime/chats"
import { Session } from "@opencode/schema/session"

export async function newChatDraft(input: {
  sdk: ServerSDK
  server: ServerConnection.Key
  tabs: ReturnType<typeof useTabs>
  model?: PromptModel
}) {
  const allocation = await allocateChat(input.sdk)
  return input.tabs.newDraft(
    {
      server: input.server,
      directory: allocation.directory,
      chat: { allocationID: allocation.id, sessionID: Session.ID.create() },
    },
    "",
    input.model,
  )
}
