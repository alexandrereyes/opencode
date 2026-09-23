import { Dialog, DialogBody, DialogHeader, DialogTitleGroup } from "@opencode/ui-custom/dialog"
import { Button } from "@opencode/ui-custom/button"
import { Checkbox } from "@opencode/ui-custom/checkbox"
import { Icon } from "@opencode/ui-custom/icon"
import { Keybind } from "@opencode/ui-custom/keybind"
import { TextInput } from "@opencode/ui-custom/text-input"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { Directories } from "@opencode/plugin-app-custom/directories/rpc"
import type { LocationRef } from "@opencode/client/promise"
import { Option, Schema } from "effect"
import { createEffect, createMemo, For, on, onMount, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { useGlobal } from "@/runtime/server/runtime"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection } from "@/runtime/server/registry"
import { formatKeybindParts, matchKeybind, parseKeybind } from "@/shell/commands/command"
import { showToast } from "@/shell/notifications/toast"
import { listPickerDirectory, nativePickerPath, trimPickerPath } from "./domain"
import { explorerDisplay, explorerParent, explorerQuery, explorerRows, explorerSubmission } from "./explorer-query"
import "./explorer.css"

interface ProjectExplorerDialogProps {
  title?: string
  multiple?: boolean
  onSelect: (result: string | string[] | null) => void
  server: ServerConnection.Any
  location?: LocationRef
}

type Row =
  | { type: "up"; path: string }
  | { type: "directory"; name: string; absolute: string; added: boolean; blocked: boolean }

const submitKeybind = parseKeybind("mod+enter")
const decodeCreateFailure = Schema.decodeUnknownOption(
  Schema.Struct({ data: Schema.Struct({ reason: Directories.CreateFailure }) }),
)

export function ProjectExplorerDialog(props: ProjectExplorerDialogProps) {
  const global = useGlobal()
  const ctx = global.ensureServerCtx(props.server)
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({
    query: "",
    home: "",
    location: undefined as { directory: string } | undefined,
    highlighted: 0,
    hidden: false,
    selected: [] as string[],
    submitting: false,
    listing: undefined as
      | { key: string; readable: boolean; entries: Array<{ name: string; absolute: string }> }
      | undefined,
  })
  const listings = new Map<string, Promise<{ readable: boolean; entries: Array<{ name: string; absolute: string }> }>>()
  const rowElements = new Map<number, HTMLElement>()
  let input: HTMLInputElement | undefined

  onMount(() => {
    const request = props.location ? Promise.resolve(props.location) : ctx.sdk.api.location.get().catch(() => undefined)
    void request.then(async (current) => {
      if (!current) return
      const location = { directory: current.directory }
      // V2 sync does not publish the home directory, so the custom plugin reports it when available.
      const home =
        ctx.sync.data.path.home ||
        (await ctx.sdk.api
          .rpc(Directories.Definition)
          .home({}, { location })
          .then(
            (result) => result.path,
            () => "",
          ))
      setState({ location, home })
      setQuery(home ? "~/" : explorerDisplay(location.directory, ""))
    })
  })

  const query = createMemo(() => explorerQuery(state.query, state.home))
  const browsed = createMemo(() => query().browsed)
  const added = createMemo(() => new Set(ctx.projects.list().map((project) => trimPickerPath(project.worktree))))
  const listing = () => (state.listing?.key === browsed() ? state.listing : undefined)
  const directories = createMemo(() =>
    explorerRows({
      entries: listing()?.entries ?? [],
      filter: query().filter,
      hidden: state.hidden,
      added: added(),
      home: state.home,
    }),
  )
  const rows = createMemo<Row[]>(() => {
    const parent = explorerParent(state.query, state.home)
    const entries = directories().map((row) => ({ type: "directory" as const, ...row }))
    return parent ? [{ type: "up", path: parent }, ...entries] : entries
  })
  const submission = createMemo(() =>
    explorerSubmission({
      query: state.query,
      home: state.home,
      selected: state.selected,
      added: added(),
      readable: listing()?.readable ?? false,
      rows: directories(),
    }),
  )
  const action = createMemo(() => {
    const current = submission()
    if (state.submitting) return language.t("dialog.projectExplorer.action.adding")
    if (current?.type === "selected")
      return language.plural("dialog.projectExplorer.action.selected", current.paths.length)
    if (current?.type === "added") return language.t("dialog.projectExplorer.action.added")
    if (current?.type === "create") return language.t("dialog.projectExplorer.action.create")
    return language.t("dialog.projectExplorer.action.add")
  })
  const canSubmit = () => !state.submitting && !!submission() && submission()?.type !== "added"

  createEffect(() => {
    const directory = browsed()
    const current = state.location
    if (!directory || !current) return
    const request =
      listings.get(directory) ??
      listPickerDirectory(ctx.sdk, current, directory).then(
        (nodes) => ({
          readable: true,
          entries: nodes.flatMap((node) =>
            node.type === "directory" ? [{ name: node.name, absolute: node.absolute }] : [],
          ),
        }),
        () => ({ readable: false, entries: [] }),
      )
    listings.set(directory, request)
    void request.then((result) => {
      if (!result.readable) listings.delete(directory)
      if (browsed() === directory) setState("listing", { key: directory, ...result })
    })
  })

  createEffect(on(browsed, () => setState("selected", []), { defer: true }))
  createEffect(
    on(
      [() => state.query, () => rows().length],
      () => setState("highlighted", rows()[0]?.type === "up" && rows().length > 1 ? 1 : 0),
      { defer: true },
    ),
  )
  createEffect(() => rowElements.get(state.highlighted)?.scrollIntoView({ block: "nearest" }))

  function browse(row: Row | undefined) {
    if (!row) return
    setQuery(row.type === "up" ? row.path : `${query().directory}${row.name}/`)
  }

  // Programmatic navigation keeps the caret and the visible end of long paths at the typed position.
  function setQuery(value: string) {
    setState("query", value)
    requestAnimationFrame(() => {
      if (!input) return
      input.focus()
      input.setSelectionRange(value.length, value.length)
      input.scrollLeft = input.scrollWidth
    })
  }

  function toggle(path: string) {
    setState("selected", (selected) =>
      selected.includes(path) ? selected.filter((item) => item !== path) : [...selected, path],
    )
  }

  function finish(paths: string[]) {
    const result = paths.map(nativePickerPath)
    props.onSelect(props.multiple ? result : (result[0] ?? null))
    dialog.close()
  }

  async function submit() {
    const current = submission()
    if (!canSubmit() || !current || current.type === "added") return
    if (current.type === "selected") return finish(current.paths)
    if (current.type === "existing") return finish([current.path])
    setState("submitting", true)
    const created = await ctx.sdk.api
      .rpc(Directories.Definition)
      .create({ path: current.path }, { location: state.location })
      .then(
        (result) => result.path,
        (error: unknown) => {
          showToast({
            variant: "error",
            title: language.t("dialog.projectExplorer.create.failed"),
            description: createFailureMessage(error),
          })
          return undefined
        },
      )
    setState("submitting", false)
    if (created) finish([created])
  }

  function createFailureMessage(error: unknown) {
    const reason = decodeCreateFailure(error).pipe(Option.map((value) => value.data.reason))
    if (Option.isNone(reason)) return language.t("dialog.projectExplorer.create.unavailable")
    if (reason.value === "exists") return language.t("dialog.projectExplorer.create.exists")
    if (reason.value === "missing-parent") return language.t("dialog.projectExplorer.create.missingParent")
    if (reason.value === "denied") return language.t("dialog.projectExplorer.create.denied")
    if (reason.value === "invalid-path") return language.t("dialog.projectExplorer.create.invalidPath")
    return language.t("dialog.projectExplorer.create.failed")
  }

  function handleKey(event: KeyboardEvent) {
    if (matchKeybind(submitKeybind, event)) {
      event.preventDefault()
      void submit()
      return
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const delta = event.key === "ArrowDown" ? 1 : -1
      setState("highlighted", (index) => Math.min(Math.max(index + delta, 0), Math.max(rows().length - 1, 0)))
      return
    }
    if (event.key === "Enter") {
      event.preventDefault()
      browse(rows()[state.highlighted])
      return
    }
    // Space is a literal path character while filtering; it toggles selection only while browsing.
    if (event.key === " " && props.multiple && !query().filter) {
      event.preventDefault()
      const row = rows()[state.highlighted]
      if (row?.type === "directory" && !row.added && !row.blocked) toggle(row.absolute)
    }
  }

  return (
    <Dialog class="project-explorer" fit>
      <DialogHeader>
        <div class="project-explorer-header">
          <DialogTitleGroup
            title={props.title ?? language.t("command.project.open")}
            description={language.t("dialog.projectExplorer.description")}
          />
          <Checkbox
            class="project-explorer-hidden"
            checked={state.hidden}
            onChange={(checked: boolean) => {
              setState("hidden", checked)
              input?.focus()
            }}
          >
            {language.t("dialog.projectExplorer.showHidden")}
          </Checkbox>
        </div>
      </DialogHeader>
      <DialogBody class="project-explorer-body">
        <div class="project-explorer-path">
          <TextInput
            ref={input}
            value={state.query}
            autofocus
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
            spellcheck={false}
            appearance="large"
            class="project-explorer-input"
            leadingIcon={<Icon name="folder-add-left" />}
            placeholder={language.t("dialog.projectExplorer.placeholder")}
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="true"
            aria-controls="project-explorer-rows"
            aria-activedescendant={rows().length > 0 ? `project-explorer-row-${state.highlighted}` : undefined}
            onInput={(event) => setState("query", event.currentTarget.value.replaceAll("\\", "/"))}
            onKeyDown={handleKey}
          />
          <Button
            variant="outline"
            tabIndex={-1}
            disabled={!canSubmit()}
            onMouseDown={(event: MouseEvent) => event.preventDefault()}
            onClick={() => void submit()}
          >
            {action()}
          </Button>
        </div>
        <div class="project-explorer-list">
          <div class="project-explorer-heading">{language.t("dialog.projectExplorer.directories")}</div>
          <Show
            when={listing()}
            fallback={
              <div class="project-explorer-state">
                {browsed() || !state.location ? language.t("common.loading") : language.t("dialog.directory.empty")}
              </div>
            }
          >
            {(current) => (
              <Show
                when={current().readable}
                fallback={<div class="project-explorer-state">{language.t("dialog.directory.readError")}</div>}
              >
                <Show
                  when={rows().length > 0}
                  fallback={<div class="project-explorer-state">{language.t("dialog.directory.empty")}</div>}
                >
                  <div id="project-explorer-rows" role="listbox" class="project-explorer-rows">
                    <For each={rows()}>
                      {(row, index) => (
                        <div
                          id={`project-explorer-row-${index()}`}
                          ref={(element) => rowElements.set(index(), element)}
                          role="option"
                          aria-selected={index() === state.highlighted}
                          class="project-explorer-row"
                          data-active={index() === state.highlighted ? "" : undefined}
                          data-added={row.type === "directory" && row.added ? "" : undefined}
                          onPointerMove={() => setState("highlighted", index())}
                          onMouseDown={(event) => event.preventDefault()}
                          onClick={() => browse(row)}
                        >
                          <Icon name={row.type === "up" ? "chevron-left" : "folder"} class="project-explorer-row-icon" />
                          <span class="project-explorer-row-name">{row.type === "up" ? ".." : row.name}</span>
                          <Show when={row.type === "directory" ? row : undefined}>
                            {(directory) => (
                              <Show
                                when={!directory().added && !directory().blocked}
                                fallback={
                                  <Show when={directory().added}>
                                    <span class="project-explorer-badge">
                                      {language.t("dialog.projectExplorer.added")}
                                    </span>
                                  </Show>
                                }
                              >
                                <div class="project-explorer-row-actions" onClick={(event) => event.stopPropagation()}>
                                  <Show when={props.multiple}>
                                    <Checkbox
                                      hideLabel
                                      checked={state.selected.includes(directory().absolute)}
                                      onChange={() => toggle(directory().absolute)}
                                    >
                                      {language.t("dialog.projectExplorer.select")}
                                    </Checkbox>
                                  </Show>
                                  <button
                                    type="button"
                                    class="project-explorer-quick-add"
                                    title={language.t("dialog.projectExplorer.quickAdd")}
                                    aria-label={language.t("dialog.projectExplorer.quickAdd")}
                                    onClick={() => finish([directory().absolute])}
                                  >
                                    <Icon name="plus-small" />
                                  </button>
                                </div>
                              </Show>
                            )}
                          </Show>
                        </div>
                      )}
                    </For>
                  </div>
                </Show>
              </Show>
            )}
          </Show>
        </div>
        <div class="project-explorer-hints">
          <span class="project-explorer-hint">
            <Keybind keys={[...formatKeybindParts("arrowup"), ...formatKeybindParts("arrowdown")]} variant="ghost" />
            {language.t("dialog.projectExplorer.hint.navigate")}
          </span>
          <span class="project-explorer-hint">
            <Keybind keys={formatKeybindParts("enter", language.t)} variant="ghost" />
            {language.t("dialog.projectExplorer.hint.open")}
          </span>
          <Show when={props.multiple}>
            <span class="project-explorer-hint">
              <Keybind keys={formatKeybindParts("space", language.t)} variant="ghost" />
              {language.t("dialog.projectExplorer.hint.select")}
            </span>
          </Show>
          <span class="project-explorer-hint">
            <Keybind keys={formatKeybindParts("mod+enter", language.t)} variant="ghost" />
            {language.t("dialog.projectExplorer.hint.add")}
          </span>
        </div>
      </DialogBody>
    </Dialog>
  )
}
