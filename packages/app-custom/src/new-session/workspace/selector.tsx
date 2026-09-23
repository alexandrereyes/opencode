import { createMemo, createSignal, For, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { createResizeObserver } from "@solid-primitives/resize-observer"
import { Menu } from "@opencode/ui-custom/menu"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { Icon } from "@opencode/ui-custom/icon"
import { getFilename } from "@opencode/util/path"
import { useLanguage } from "@/runtime/i18n/language"
import { sameDirectory } from "@/workspaces/paths"
import { NEW_SESSION_TRIGGER } from "@/new-session/layout"

export function PromptWorkspaceSelector(props: {
  value: string
  projectRoot: string
  workspaces: string[]
  branches: string[]
  branch?: string
  checkoutBranch: (directory: string) => string | undefined
  onboarding?: boolean
  onChange: (value: string) => void
  onCreate: (branch: string) => void
  onSearch: (search: string) => void
  onDone: () => void
  onViewAll: () => void
}) {
  const language = useLanguage()
  const [search, setSearch] = createStore({ workspaces: "", branches: "" })
  let searchInput: HTMLInputElement | undefined
  let branchSearchInput: HTMLInputElement | undefined
  const branchTruncation = createTruncatedText()
  let pending: { type: "select"; value: string } | { type: "create"; branch: string } | { type: "viewAll" } | undefined
  const selected = () => (sameDirectory(props.value, props.projectRoot) ? "main" : props.value)
  const worktreeLabel = (directory: string) => props.checkoutBranch(directory) ?? getFilename(directory)
  const rootLabel = () =>
    props.checkoutBranch(props.projectRoot) ??
    (selected() === "main" ? props.branch : undefined) ??
    language.t("session.new.workspace.triggerLocal")
  const workspaces = createMemo(() => {
    const query = search.workspaces.trim().toLowerCase()
    if (!query) return props.workspaces
    return props.workspaces.filter(
      (workspace) =>
        worktreeLabel(workspace).toLowerCase().includes(query) || getFilename(workspace).toLowerCase().includes(query),
    )
  })
  const searchable = () => props.workspaces.length >= 10
  const select = (value: string) => {
    pending = { type: "select", value }
  }
  const onOpenChange = (open: boolean) => {
    if (open) {
      setSearch({ workspaces: "", branches: "" })
      props.onSearch("")
      return
    }
    const action = pending
    pending = undefined
    if (action?.type === "select") props.onChange(action.value)
    if (action?.type === "create") props.onCreate(action.branch)
    if (action?.type === "viewAll") {
      props.onViewAll()
      return
    }
    props.onDone()
  }
  const label = () => {
    if (selected() === "main") return rootLabel()
    if (selected() === "create") return language.t("workspace.new")
    return props.checkoutBranch(props.value) ?? props.branch ?? getFilename(props.value)
  }
  const keepSearchKeys = (event: KeyboardEvent) => {
    if (event.key === "Escape" || event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "Enter") return
    event.stopPropagation()
  }

  return (
    <>
      <Tooltip
        appearance={props.onboarding ? "large" : undefined}
        placement="top"
        openDelay={800}
        value={
          props.onboarding ? (
            <div class="flex flex-col gap-1 text-start">
              <div class="flex items-center gap-1.5 font-[530] text-v2-text-text-base">
                <Icon name="outline-worktree" size="small" class="shrink-0 text-v2-text-text-accent" />
                <span>{language.t("workspace.onboarding.title")}</span>
              </div>
              <span class="font-[440] text-v2-text-text-muted">{language.t("workspace.onboarding.description")}</span>
            </div>
          ) : (
            language.t("session.new.workspace.trigger.tooltip")
          )
        }
        contentClass={props.onboarding ? "max-w-[280px]" : undefined}
        class="min-w-0"
      >
        <Menu placement="bottom-start" gutter={4} overflowPadding={24} onOpenChange={onOpenChange}>
          <Menu.Trigger
            data-action="prompt-workspace"
            aria-description={language.t("session.new.workspace.trigger.tooltip")}
            class={`${NEW_SESSION_TRIGGER} max-w-[240px]`}
          >
            <Show when={selected() === "create"}>
              <Icon name="plus" size="small" class="shrink-0 text-v2-icon-icon-muted" />
            </Show>
            <span class="min-w-0 truncate">{label()}</span>
            <Show when={props.onboarding}>
              <span
                data-slot="workspace-onboarding-dot"
                aria-hidden="true"
                class="size-1.5 shrink-0 rounded-full bg-v2-text-text-accent"
              />
            </Show>
            <Icon name="chevron-down" size="small" class="shrink-0 text-v2-icon-icon-muted" />
          </Menu.Trigger>
          <Menu.Portal>
            <Menu.Content
              data-mobile-menu="session-location"
              data-component="prompt-workspace-menu"
              class="max-h-[min(480px,66.667dvh)] w-max min-w-[200px] max-w-[min(384px,calc(100vw-32px))] overflow-y-auto !rounded-lg !p-1 [&_[data-component=menu-v2-item]]:!rounded-md [&_[role=menuitem]:not([data-action=prompt-workspace-new])]:!h-8 [&_[role=menuitem]:not([data-action=prompt-workspace-new])]:!px-2.5"
              onOpenAutoFocus={(event) => {
                if (!searchable()) return
                event.preventDefault()
                setTimeout(() => requestAnimationFrame(() => searchInput?.focus({ preventScroll: true })))
              }}
            >
              <Menu.Group>
                <Menu.GroupLabel>{language.t("session.new.workspace.projectRoot")}</Menu.GroupLabel>
                <Menu.Item title={props.projectRoot} onSelect={() => select("main")}>
                  <span class="min-w-0 flex-1 truncate">{rootLabel()}</span>
                  <Show when={selected() === "main"}>
                    <Icon name="check" size="small" class="shrink-0" />
                  </Show>
                </Menu.Item>
              </Menu.Group>
              <Menu.Separator class="h-[0.5px]" />
              <Menu.Group>
                <div class="flex items-center justify-between gap-4">
                  <Menu.GroupLabel class="min-w-0 flex-1">{language.t("session.new.workspace.worktrees")}</Menu.GroupLabel>
                  <Menu.Item
                    data-action="prompt-workspace-new"
                    title={language.t("session.new.workspace.new.tooltip")}
                    class="!h-6 shrink-0 !gap-1 !px-1.5 [&_[data-slot=menu-v2-item-content]]:!gap-1 [&_[data-slot=menu-v2-item-content]]:!text-v2-text-text-muted"
                    onSelect={() => select("create")}
                  >
                    <Icon name="plus" size="small" class="shrink-0" />
                    <span>{language.t("session.new.workspace.worktreeNew")}</span>
                  </Menu.Item>
                </div>
                <Show when={searchable()}>
                  <div class="flex h-7 items-center gap-2 rounded-sm ps-3 pe-2 text-v2-icon-icon-muted">
                    <Icon name="magnifying-glass" size="small" class="shrink-0" />
                    <input
                      ref={(element) => {
                        searchInput = element
                      }}
                      value={search.workspaces}
                      placeholder={language.t("session.new.workspace.search.placeholder")}
                      aria-label={language.t("session.new.workspace.search.placeholder")}
                      class="h-7 min-w-0 flex-1 border-0 bg-transparent text-[13px] font-[440] leading-5 tracking-[-0.04px] text-v2-text-text-base outline-none placeholder:text-v2-text-text-faint"
                      onInput={(event) => setSearch("workspaces", event.currentTarget.value)}
                      onKeyDown={keepSearchKeys}
                    />
                  </div>
                </Show>
                <For each={workspaces()}>
                  {(workspace) => (
                    <Menu.Item title={workspace} onSelect={() => select(workspace)}>
                      <span class="min-w-0 flex-1 truncate">{worktreeLabel(workspace)}</span>
                      <Show when={selected() === workspace}>
                        <Icon name="check" size="small" class="shrink-0" />
                      </Show>
                    </Menu.Item>
                  )}
                </For>
                <Show when={search.workspaces.trim() && workspaces().length === 0}>
                  <div class="px-3 py-4 text-center text-[13px] font-[440] leading-5 text-v2-text-text-muted">
                    {language.t("session.new.workspace.search.empty")}
                  </div>
                </Show>
              </Menu.Group>
              <Show when={props.workspaces.length > 0}>
                <Menu.Separator class="h-[0.5px]" />
                <Menu.Item onSelect={() => (pending = { type: "viewAll" })}>
                  <span class="min-w-0 flex-1 truncate text-v2-text-text-muted">{language.t("common.viewAll")}</span>
                </Menu.Item>
              </Show>
            </Menu.Content>
          </Menu.Portal>
        </Menu>
      </Tooltip>
      <Show when={selected() === "create" && props.branch}>
        <Tooltip
          placement="top"
          value={language.t("session.new.workspace.fromBranch", { branch: props.branch! })}
          disabled={!branchTruncation.truncated()}
          class="min-w-0 max-w-[240px]"
          contentClass="max-w-[calc(100vw-32px)] break-all"
        >
          <Menu placement="bottom-start" gutter={4} onOpenChange={onOpenChange}>
            <Menu.Trigger
              data-action="prompt-workspace-base"
              class={`${NEW_SESSION_TRIGGER} max-w-[240px] text-v2-text-text-muted`}
            >
              <Icon name="branch-out" size="small" class="shrink-0 text-v2-icon-icon-muted" />
              <span ref={branchTruncation.observe} class="min-w-0 truncate">
                {language.t("session.new.workspace.fromBranch", { branch: props.branch! })}
              </span>
              <Icon name="chevron-down" size="small" class="shrink-0 text-v2-icon-icon-muted" />
            </Menu.Trigger>
            <Menu.Portal>
              <Menu.Content
                data-mobile-menu="session-location"
                class="w-[243px] overflow-hidden rounded-md border-0 bg-v2-background-bg-layer-01 shadow-[var(--v2-elevation-floating)] focus:outline-none"
                onOpenAutoFocus={(event) => {
                  event.preventDefault()
                  // Kobalte defers its list autofocus until after the focus scope opens.
                  setTimeout(() => requestAnimationFrame(() => branchSearchInput?.focus({ preventScroll: true })))
                }}
              >
                <div class="flex h-7 shrink-0 items-center gap-2 rounded-sm pl-3 pr-2.5 text-v2-icon-icon-muted">
                  <Icon name="magnifying-glass" size="small" class="shrink-0" />
                  <input
                    ref={(element) => {
                      branchSearchInput = element
                    }}
                    value={search.branches}
                    placeholder={language.t("session.new.workspace.branch.search.placeholder")}
                    aria-label={language.t("session.new.workspace.branch.search.placeholder")}
                    class="h-7 min-w-0 flex-1 border-0 bg-transparent text-[13px] font-[440] leading-5 tracking-[-0.04px] text-v2-text-text-base outline-none placeholder:text-v2-text-text-faint"
                    onInput={(event) => {
                      setSearch("branches", event.currentTarget.value)
                      props.onSearch(event.currentTarget.value)
                    }}
                    onKeyDown={keepSearchKeys}
                  />
                  <Show when={search.branches.trim()}>
                    <button
                      type="button"
                      class="flex size-5 items-center justify-center rounded-sm text-v2-icon-icon-muted hover:bg-v2-overlay-simple-overlay-hover"
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => {
                        setSearch("branches", "")
                        props.onSearch("")
                      }}
                      aria-label={language.t("common.clear")}
                    >
                      <Icon name="close-small" size="small" />
                    </button>
                  </Show>
                </div>
                <div class="max-h-[224px] overflow-y-auto">
                  <Menu.RadioGroup value={props.branch}>
                    <For each={props.branches}>
                      {(branch) => (
                        <Menu.RadioItem
                          value={branch}
                          class="h-7 gap-2 rounded-sm px-3 text-[13px] font-[440] leading-5 tracking-[-0.04px] text-v2-text-text-base [font-family:var(--v2-font-family-sans)] data-[highlighted]:!bg-v2-overlay-simple-overlay-hover"
                          closeOnSelect
                          onSelect={() => (pending = { type: "create", branch })}
                        >
                          <span class="min-w-0 truncate leading-5">{branch}</span>
                        </Menu.RadioItem>
                      )}
                    </For>
                  </Menu.RadioGroup>
                </div>
              </Menu.Content>
            </Menu.Portal>
          </Menu>
        </Tooltip>
      </Show>
    </>
  )
}

export function PromptGitStatus(props: { branch?: string; noGit?: boolean; class?: string }) {
  const language = useLanguage()
  const truncation = createTruncatedText()
  const label = () => {
    if (props.noGit) return language.t("session.new.git.none")
    return props.branch
  }

  const icon = () => (props.noGit ? "monitor" : "branch")

  return (
    <Show when={label()}>
      {(value) => (
        <Tooltip
          placement="top"
          value={value()}
          disabled={!truncation.truncated()}
          class={`min-w-0 max-w-[240px] ${props.class ?? ""}`}
          contentClass="max-w-[calc(100vw-32px)] break-all"
        >
          <div
            data-component="prompt-git-status"
            class="flex h-7 min-w-0 max-w-[240px] items-center gap-1.5 px-1.5 text-[13px] font-[440] leading-[var(--line-height-compact)] tracking-[-0.04px] text-v2-text-text-muted"
          >
            <Icon name={icon()} size="small" class="shrink-0 text-v2-icon-icon-muted" />
            <span ref={truncation.observe} class="min-w-0 truncate">
              {value()}
            </span>
          </div>
        </Tooltip>
      )}
    </Show>
  )
}

function createTruncatedText() {
  const [truncated, setTruncated] = createSignal(false)
  return {
    truncated,
    observe: (element: HTMLSpanElement) =>
      createResizeObserver(element, () => setTruncated(element.scrollWidth > element.clientWidth)),
  }
}
