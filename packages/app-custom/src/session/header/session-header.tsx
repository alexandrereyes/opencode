import { Show } from "solid-js"
import { createMediaQuery } from "@solid-primitives/media"
import { useLanguage } from "@/runtime/i18n/language"
import { useSettings } from "@/settings/model"
import { StatusPopover } from "@/shell/status/status-popover"
import { TitlebarRight } from "@/shell/titlebar/right-slot"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { useCommand } from "@/shell/commands/command"

export function SessionHeader(props: { reserveReviewToggle: boolean }) {
  const language = useLanguage()
  const settings = useSettings()
  const command = useCommand()

  const isDesktop = createMediaQuery("(min-width: 768px)")

  return (
    <>
      <TitlebarRight>
        <Show when={isDesktop() && settings.visibility.status()}>
          <Tooltip appearance="standard" placement="bottom" value={language.t("status.popover.trigger")}>
            <StatusPopover />
          </Tooltip>
        </Show>
      </TitlebarRight>
      <Show when={isDesktop()}>
        <Tooltip placement="bottom" value={language.t("command.session.new")}>
          <IconButton
            type="button"
            data-action="session-header-new-session"
            variant="ghost-muted"
            size="large"
            icon={<Icon name="plus" />}
            aria-label={language.t("command.session.new")}
            onClick={() => command.trigger("tab.new")}
          />
        </Tooltip>
      </Show>
      <Show when={isDesktop() && props.reserveReviewToggle}>
        <div class="size-7 shrink-0" aria-hidden />
      </Show>
    </>
  )
}
