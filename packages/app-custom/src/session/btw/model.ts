import { onCleanup } from "solid-js"
import type { ComposerAdapter } from "@/composer/adapter"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useCommand } from "@/shell/commands/command"
import { createBtwState } from "./state"

export function createComposerBtw(adapter: ComposerAdapter) {
  if (adapter.kind !== "active-session") return
  const server = useServerSDK()
  const language = useLanguage()
  const command = useCommand()
  const btw = createBtwState(adapter.session().id, (input, options) => server.api.session.generate(input, options))
  onCleanup(btw.cancel)
  command.register("session.btw", () => [
    {
      id: "session.btw",
      title: language.t("command.session.btw"),
      description: language.t("command.session.btw.description"),
      category: language.t("command.category.session"),
      slash: "btw",
      keybind: "mod+shift+b",
      disabled: !(adapter.active?.() ?? true),
      onSelect: () => {
        const selection = window.getSelection()
        const element = selection?.anchorNode?.parentElement
        const text = element?.closest('[data-slot="text-part-body"]') ? selection?.toString().trim() : undefined
        btw.open(
          text
            ? `${text
                .split("\n")
                .map((line) => `> ${line}`)
                .join("\n")}\n\n`
            : undefined,
        )
      },
    },
  ])
  return btw
}
