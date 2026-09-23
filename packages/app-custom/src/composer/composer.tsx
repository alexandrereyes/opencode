import { Show, createMemo } from "solid-js"
import { createStore } from "solid-js/store"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { Icon } from "@opencode/ui-custom/icon"
import { Keybind } from "@opencode/ui-custom/keybind"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { ComposerEditor, composerControlClass } from "./editor/editor"
import { ModelSelectorPopover } from "@/providers/models/select-dialog"
import { DialogSelectModelUnpaid } from "@/providers/models/unpaid"
import { formatKeybind, useCommand } from "@/shell/commands/command"
import { useLanguage } from "@/runtime/i18n/language"
import type { ComposerModel } from "./model"
import { ChatQuotes } from "./chat-quotes"
import { BtwPanel } from "@/session/btw/panel"

export function Composer(props: { class?: string; model: ComposerModel; borderUnderlay?: boolean }) {
  const dialog = useDialog()
  const command = useCommand()
  const language = useLanguage()
  const [state, setState] = createStore({ editingQuote: false })

  return (
    <div class="relative flex flex-col gap-3" data-component="composer-region" data-editing-quote={state.editingQuote}>
      <Show when={props.model.btw}>
        {(btw) => <BtwPanel btw={btw()} completion={props.model.completion} restoreFocus={props.model.restoreFocus} />}
      </Show>
      <Show when={props.model.state.mode !== "shell" && props.model.quotes}>
        {(quotes) => (
          <ChatQuotes
            quotes={quotes()}
            completion={props.model.completion}
            onEditingChange={(editing) => setState("editingQuote", editing)}
            onDone={() => {
              if (window.matchMedia("(min-width: 768px)").matches) props.model.restoreFocus()
            }}
          />
        )}
      </Show>
      <ComposerEditor
        controller={props.model}
        borderUnderlay={props.borderUnderlay}
        class={`composer-main ${props.class ?? ""}`}
        modelControlsVisible={!props.model.model.loading}
        attachKeybind={command.keybindParts("file.attach")}
        attachShortcut={command.keybind("file.attach")}
        alternateKeybind={[formatKeybind("mod", language.t), "↵"]}
        exitShellKeybind={[formatKeybind("esc", language.t)]}
        modelControl={
          <ComposerModelControl
            loading={props.model.model.loading}
            paid={props.model.model.paid}
            title={language.t("command.model.choose")}
            keybind={command.keybindParts("model.choose")}
            model={props.model.model.selection}
            providerID={props.model.model.selection.current()?.provider?.id}
            modelName={props.model.model.selection.current()?.name ?? language.t("dialog.model.select.title")}
            onClose={props.model.restoreFocus}
            onUnpaidClick={() => dialog.show(() => <DialogSelectModelUnpaid model={props.model.model.selection} />)}
          />
        }
      />
    </div>
  )
}

function ComposerModelControl(props: {
  loading: boolean
  paid: boolean
  title: string
  keybind: string[]
  model: ComposerModel["model"]["selection"]
  providerID?: string
  modelName: string
  onClose: () => void
  onUnpaidClick: () => void
}) {
  const shouldAnimate = createMemo<boolean>((previous) => previous ?? props.loading)
  const content = () => (
    <>
      <Show when={props.providerID} fallback={<Icon name="models" class="shrink-0 text-v2-icon-icon-muted" />}>
        {(providerID) => <ProviderIcon id={providerID()} class="size-4 shrink-0" />}
      </Show>
      <span class="truncate">{props.modelName}</span>
    </>
  )
  return (
    <Show when={!props.loading}>
      <Tooltip
        placement="top"
        gutter={4}
        value={
          <>
            {props.title}
            <Keybind keys={props.keybind} variant="neutral" />
          </>
        }
      >
        <Show
          when={props.paid}
          fallback={
            <button
              type="button"
              data-action="composer-model"
              data-control-type="dialog"
              class={composerControlClass}
              classList={{ "animate-in fade-in": shouldAnimate() }}
              onClick={props.onUnpaidClick}
            >
              {content()}
            </button>
          }
        >
          <ModelSelectorPopover
            model={props.model}
            trigger={(triggerProps) => (
              <button
                {...triggerProps}
                type="button"
                class={composerControlClass}
                classList={{ "animate-in fade-in": shouldAnimate() }}
                data-action="composer-model"
                data-control-type="popover"
              >
                {content()}
              </button>
            )}
            onClose={props.onClose}
          />
        </Show>
      </Tooltip>
    </Show>
  )
}
