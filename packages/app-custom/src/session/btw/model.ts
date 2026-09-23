import { createEffect, onCleanup } from "solid-js"
import type { ComposerAdapter } from "@/composer/adapter"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK, type ServerSDK } from "@/runtime/server/client"
import { useCommand } from "@/shell/commands/command"
import { createBtwSessions } from "./state"

const states = new WeakMap<ServerSDK, ReturnType<typeof createBtwSessions>>()

export function createComposerBtw(adapter: ComposerAdapter) {
  if (adapter.kind !== "active-session") return
  const server = useServerSDK()
  const language = useLanguage()
  const command = useCommand()
  const sessions =
    states.get(server) ?? createBtwSessions((input, options) => server.api.session.generate(input, options))
  states.set(server, sessions)
  const btw = sessions(adapter.session().id)
  createEffect(() => {
    if (adapter.active?.() === false) btw.cancel()
  })
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
