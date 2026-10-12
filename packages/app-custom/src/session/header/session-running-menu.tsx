import { SessionProgressIndicatorV2 } from "@opencode/session-ui-custom/v2/session-progress-indicator-v2"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Menu } from "@opencode/ui-custom/menu"
import { TextShimmer } from "@opencode/ui-custom/text-shimmer"
import { createEffect, createMemo, createUniqueId, For, on, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { createAnimatedPresence } from "@/runtime/animated-presence"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useServer } from "@/runtime/server/current"
import { useOpenSessionRoute } from "@/session/session-identity-header"
import { errorMessage } from "@/shell/layout/helpers"
import { showToast } from "@/shell/notifications/toast"
import { SessionWorkingIndicator } from "./session-working-indicator"
import { runningItems, runningLabel, type RunningItem, type RunningWork } from "./running-work"

const neutral = "light-dark(var(--v2-text-text-base), #ffffff)"

/**
 * The running subagents and background shells of a session, or of its parent inside a subagent.
 * `title` renders a subagent's header title as the trigger; `compact` is the phone's session navigation trigger.
 */
export function SessionRunningMenu(
  props: RunningWork & {
    // Reveals a tool call in the visible timeline; without it, the session route opens on the call.
    onReveal?: (target: string) => boolean | void
    onOpen?: () => void
    title?: string
    compact?: boolean
  },
) {
  const language = useLanguage()
  const openRoute = useOpenSessionRoute()
  const server = useServer()
  const sdk = useServerSDK()
  const id = createUniqueId()
  const [menu, setMenu] = createStore({ open: false })
  const [appearance, setAppearance] = createStore<{ group?: HTMLElement; entered: boolean }>({ entered: false })

  const items = createMemo(() =>
    runningItems(props, (sessionID) => (sessionID ? server.ctx.data.session.get(sessionID)?.agent : undefined)),
  )
  const viewing = (item: RunningItem) => !!item.sessionID && item.sessionID === props.sessionID
  const summary = createMemo(() =>
    runningLabel(items(), props.sessionID, props.title ? "additional" : props.compact ? "others" : "all"),
  )
  const label = createMemo(() => {
    const value = summary()
    return value ? language.plural(value.key, value.count) : undefined
  })
  // The phone trigger shows only the count beside the progress icon; it keeps the last count while fading out.
  const count = createMemo<number | undefined>((previous) => summary()?.count ?? previous)
  const presence = createAnimatedPresence(
    label,
    () => appearance.group ?? null,
    () => props.sessionID,
  )
  // Label updates change presence state without changing visibility.
  const visible = createMemo(presence.show)
  createEffect(
    on(
      visible,
      (show) => {
        if (show) {
          setAppearance("entered", false)
          return
        }
        setMenu("open", false)
      },
      { defer: true },
    ),
  )

  const open = (item: RunningItem) => {
    const current = props.sessionID
    if (!current || viewing(item)) return
    props.onOpen?.()
    if (item.sessionID) return openRoute(current, item.sessionID)
    // Shell calls and starting subagent calls live in the owner's timeline, which reveals them once open.
    if (props.owner && props.owner !== current) return openRoute(current, props.owner, item.target)
    if (props.onReveal?.(item.target)) return
    openRoute(current, current, item.target)
  }

  // A subagent can only be interrupted once its child session exists.
  const stoppable = (item: RunningItem) => item.type === "shell" || !!item.sessionID
  const stop = (item: RunningItem) => {
    const request = item.sessionID
      ? sdk.api.session.interrupt({ sessionID: item.sessionID })
      : sdk.api.shell.remove({
          id: item.target,
          location: { directory: server.ctx.data.shell.get(item.target)?.location.directory },
        })
    void request.catch((error: unknown) =>
      showToast({
        title: language.t("common.requestFailed"),
        description: errorMessage(error, language.t("common.requestFailed")),
      }),
    )
  }

  const shimmer = () => <TextShimmer text={presence.value() ?? ""} active={presence.show()} />
  const trigger = () => (
    <Show
      when={props.title}
      fallback={
        <Menu.Trigger
          as="button"
          type="button"
          data-slot="session-running-trigger"
          aria-label={presence.value()}
          class="flex h-7 shrink-0 items-center gap-1.5 rounded-[6px] px-2 text-[13px] font-[530] leading-[var(--line-height-compact)] tracking-[-0.04px] tabular-nums whitespace-nowrap text-v2-text-text-base outline-none hover:bg-v2-overlay-simple-overlay-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-v2-border-border-focus data-[expanded]:bg-v2-overlay-simple-overlay-hover"
        >
          <Show when={props.compact} fallback={shimmer()}>
            <SessionProgressIndicatorV2 class="shrink-0 text-v2-icon-icon-muted" aria-hidden="true" />
            <span aria-hidden="true">{count()}</span>
          </Show>
        </Menu.Trigger>
      }
    >
      <h1
        data-slot="session-title-child"
        aria-label={props.title}
        class="min-w-0 text-[13px] font-[530] leading-[var(--line-height-compact)] tracking-[-0.04px] text-v2-text-text-base"
      >
        <Menu.Trigger
          as="button"
          type="button"
          data-slot="session-running-trigger"
          disabled={!visible()}
          aria-labelledby={`${id}-title${visible() ? ` ${id}-count` : ""}`}
          class="flex h-7 max-w-full items-center gap-0.5 rounded-[6px] outline-none enabled:hover:bg-v2-overlay-simple-overlay-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-v2-border-border-focus data-[expanded]:bg-v2-overlay-simple-overlay-hover"
        >
          <SessionWorkingIndicator sessionID={props.sessionID} />
          <span id={`${id}-title`} dir="auto" class="min-w-0 truncate px-1">
            {props.title}
          </span>
          <Show when={presence.present()}>
            <span
              id={`${id}-count`}
              ref={(element) => setAppearance("group", element)}
              class="shrink-0 ps-0.5 pe-1 tabular-nums text-v2-text-text-muted duration-150 ease-out motion-reduce:animate-none"
              classList={{
                "animate-in fade-in": presence.animate() && presence.show() && !appearance.entered,
                "animate-out fade-out fill-mode-forwards": presence.animate() && !presence.show(),
              }}
              onAnimationEnd={(event) => {
                if (event.target === event.currentTarget && presence.show()) setAppearance("entered", true)
              }}
            >
              {shimmer()}
            </span>
          </Show>
        </Menu.Trigger>
      </h1>
    </Show>
  )

  return (
    <Show when={props.title || presence.present()}>
      <div
        ref={(element) => {
          if (!props.title) setAppearance("group", element)
        }}
        data-component="session-running-menu"
        inert={!props.title && !presence.show()}
        class="flex min-w-0 shrink-0 items-center gap-0.5 duration-150 ease-out motion-reduce:animate-none"
        classList={{
          "max-w-[45%]": !!props.title,
          "animate-in fade-in": !props.title && presence.animate() && presence.show() && !appearance.entered,
          "animate-out fade-out fill-mode-forwards": !props.title && presence.animate() && !presence.show(),
        }}
        onAnimationEnd={(event) => {
          if (event.target === event.currentTarget && presence.show()) setAppearance("entered", true)
        }}
      >
        <Show when={!props.title && !props.compact}>
          <span
            aria-hidden="true"
            class="shrink-0 ps-2 pe-1 text-[11px] font-medium leading-[var(--line-height-compact)] text-v2-text-text-faint"
          >
            /
          </span>
        </Show>
        <Menu
          gutter={6}
          placement={props.compact ? "bottom-end" : "bottom-start"}
          open={menu.open && presence.show()}
          onOpenChange={(open) => setMenu("open", open)}
        >
          {trigger()}
          <Menu.Portal>
            <Menu.Content class="w-60 max-w-[calc(100vw-16px)]" aria-label={presence.value()}>
              <For each={items()}>
                {(item) => (
                  <Menu.Item
                    class="group/running-item"
                    classList={{ "!bg-v2-overlay-simple-overlay-hover": viewing(item) }}
                    aria-current={viewing(item) ? "page" : undefined}
                    onSelect={() => {
                      // Close before navigating: the router's transition would hold the close until this
                      // timeline detaches, and the menu would flash at the viewport origin.
                      setMenu("open", false)
                      open(item)
                    }}
                    onKeyDown={(event: KeyboardEvent) => {
                      if ((event.key !== "Delete" && event.key !== "Backspace") || !stoppable(item)) return
                      event.preventDefault()
                      stop(item)
                    }}
                  >
                    <Show
                      when={item.type === "subagent"}
                      fallback={<Icon name="console" class="shrink-0 text-v2-icon-icon-muted" />}
                    >
                      {/* Built-in agents have theme tokens; any other agent keeps the neutral color. */}
                      <SessionProgressIndicatorV2
                        class="shrink-0"
                        style={{
                          color: item.agent ? `var(--v2-agent-${item.agent.toLowerCase()}-solid, ${neutral})` : neutral,
                        }}
                      />
                    </Show>
                    <span class="shrink-0 font-[530]">
                      {item.type === "shell"
                        ? language.t("ui.tool.shell")
                        : item.agent
                          ? `${item.agent[0].toUpperCase()}${item.agent.slice(1)}`
                          : language.t("ui.tool.agent.default")}
                    </span>
                    {/* Menu rows end 6px in for trailing controls; text alone ends 12px in, like the leading edge. */}
                    <span
                      dir="auto"
                      class="me-1.5 min-w-0 flex-1 truncate text-v2-text-text-muted"
                      classList={{
                        "group-hover/running-item:me-0 group-data-[highlighted]/running-item:me-0 [@media(hover:none)]:me-0":
                          stoppable(item),
                      }}
                    >
                      {item.label}
                    </span>
                    <Show when={stoppable(item)}>
                      {/* The button's own display rule outranks utilities, so this wrapper shows and hides it. */}
                      <span class="hidden shrink-0 group-hover/running-item:flex group-data-[highlighted]/running-item:flex [@media(hover:none)]:flex">
                        {/* The row selects on press, so the stop button keeps its pointer events to itself. */}
                        <IconButton
                          type="button"
                          size="small"
                          variant="ghost-muted"
                          tabIndex={-1}
                          icon={<Icon name="outline-xmark" />}
                          aria-label={language.t(
                            item.type === "shell" ? "session.running.stop.shell" : "session.running.stop.subagent",
                          )}
                          onPointerDown={(event) => {
                            event.preventDefault()
                            event.stopPropagation()
                          }}
                          onPointerUp={(event) => event.stopPropagation()}
                          onClick={(event) => {
                            event.stopPropagation()
                            stop(item)
                          }}
                        />
                      </span>
                    </Show>
                  </Menu.Item>
                )}
              </For>
            </Menu.Content>
          </Menu.Portal>
        </Menu>
      </div>
    </Show>
  )
}
