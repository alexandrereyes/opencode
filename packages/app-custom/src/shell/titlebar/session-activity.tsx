import { Match, Show, Switch } from "solid-js"
import { Icon } from "@opencode/ui-custom/icon"
import { useLanguage } from "@/runtime/i18n/language"
import type { SidebarActivity } from "./sidebar-model"

export function SessionActivityMarker(props: { activity: SidebarActivity }) {
  const language = useLanguage()
  const label = () =>
    language.t(
      props.activity === "permission"
        ? "sidebar.session.permissionRequired"
        : props.activity === "question"
          ? "sidebar.session.questionPending"
          : props.activity === "running"
            ? "dashboard.status.running"
            : "sidebar.attention.pending",
    )
  return (
    <Switch>
      <Match when={props.activity === "permission" || props.activity === "question"}>
        <span
          role="img"
          data-slot="session-activity"
          data-activity={props.activity}
          aria-label={label()}
          title={label()}
          class="flex shrink-0 items-center"
          classList={{
            "text-v2-state-fg-danger": props.activity === "permission",
            "text-v2-state-fg-info": props.activity === "question",
          }}
        >
          <Icon name={props.activity === "permission" ? "shield" : "help"} size="small" />
        </span>
      </Match>
      <Match when={true}>
        <span
          role="img"
          data-slot="session-activity"
          data-activity={props.activity}
          aria-label={label()}
          title={label()}
          class="size-1.5 shrink-0 rounded-full"
          classList={{
            "bg-icon-warning-base": props.activity === "running",
            "bg-v2-icon-icon-accent": props.activity === "unread",
          }}
        />
      </Match>
    </Switch>
  )
}

export function SessionRequestBadges(props: { permissions?: number; questions?: number }) {
  const language = useLanguage()
  return (
    <Show when={props.permissions || props.questions}>
      <span data-slot="tab-requests">
        <Show when={props.permissions}>
          {(count) => (
            <span
              role="img"
              aria-label={language.plural("sidebar.session.permissionCount", count())}
              title={language.plural("sidebar.session.permissionCount", count())}
              class="bg-v2-state-bg-danger text-v2-state-fg-danger"
            >
              <Icon name="shield" size="small" />
              {count()}
            </span>
          )}
        </Show>
        <Show when={props.questions}>
          {(count) => (
            <span
              role="img"
              aria-label={language.plural("sidebar.session.questionCount", count())}
              title={language.plural("sidebar.session.questionCount", count())}
              class="bg-v2-state-bg-info text-v2-state-fg-info"
            >
              <Icon name="help" size="small" />
              {count()}
            </span>
          )}
        </Show>
      </span>
    </Show>
  )
}
