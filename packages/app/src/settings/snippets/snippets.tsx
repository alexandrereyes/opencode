import { createMemo, For, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui/button"
import { Dialog, DialogFooter, DialogHeader, DialogTitle } from "@opencode/ui/dialog"
import { Field } from "@opencode/ui/field"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Menu } from "@opencode/ui/menu"
import { Select } from "@opencode/ui/select"
import { Textarea } from "@opencode/ui/textarea"
import { TextInput } from "@opencode/ui/text-input"
import { useDialog } from "@opencode/ui/context/dialog"
import { useLanguage } from "@/runtime/i18n/language"
import { useGlobal } from "@/runtime/server/runtime"
import { ScopedKey } from "@/runtime/server/scope"
import { serverName } from "@/runtime/server/registry"
import { displayName } from "@/shell/layout/helpers"
import { useSettings } from "../model"
import { SettingsList } from "../list"
import { snippetAliases, type Snippet } from "./model"

export function SettingsSnippets() {
  const language = useLanguage()
  const settings = useSettings()
  const global = useGlobal()
  const dialog = useDialog()
  const [state, setState] = createStore({ query: "" })
  const projects = createMemo(() =>
    global.servers
      .list()
      .flatMap((server) => {
        const ctx = global.ensureServerCtx(server)
        return ctx.projects.list().flatMap((project) =>
          project.id
            ? [
                {
                  id: ScopedKey.from(ctx.sdk.scope, project.id),
                  label:
                    global.servers.list().length > 1
                      ? `${displayName(project)} — ${serverName(server)}`
                      : displayName(project),
                },
              ]
            : [],
        )
      })
      .filter((project, index, items) => items.findIndex((item) => item.id === project.id) === index),
  )
  const scopeLabel = (project?: string) =>
    project
      ? (projects().find((item) => item.id === project)?.label ?? language.t("settings.snippets.project"))
      : language.t("settings.snippets.global")
  const filtered = createMemo(() =>
    settings.snippets
      .list()
      .filter((item) =>
        [item.name, item.description, ...item.aliases]
          .join(" ")
          .toLowerCase()
          .includes(state.query.trim().toLowerCase()),
      )
      .toSorted((a, b) => a.name.localeCompare(b.name)),
  )
  const edit = (snippet?: Snippet) => dialog.push(() => <SnippetDialog snippet={snippet} projects={projects()} />)

  return (
    <>
      <div class="settings-tab-header settings-tab-header--stacked">
        <div class="settings-tab-header-row">
          <div class="flex flex-col gap-1">
            <h2 class="settings-tab-title">{language.t("settings.snippets.title")}</h2>
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.snippets.description")}</span>
          </div>
          <Button variant="ghost-muted" onClick={() => edit()} disabled={!settings.ready()}>
            <Icon name="plus" />
            {language.t("settings.snippets.add")}
          </Button>
        </div>
        <Show when={settings.snippets.list().length > 0}>
          <div class="settings-tab-search">
            <TextInput
              type="search"
              appearance="base"
              value={state.query}
              onInput={(event) => setState("query", event.currentTarget.value)}
              placeholder={language.t("settings.snippets.search")}
              aria-label={language.t("settings.snippets.search")}
            />
          </div>
        </Show>
      </div>
      <div class="settings-tab-body settings-servers">
        <Show
          when={filtered().length > 0}
          fallback={
            <div class="settings-servers-status">
              {language.t(state.query ? "palette.empty" : "settings.snippets.empty")}
            </div>
          }
        >
          <SettingsList>
            <For each={filtered()}>
              {(snippet) => (
                <div class="settings-servers-row">
                  <button
                    type="button"
                    class="flex min-w-0 flex-1 flex-col gap-1 text-start rounded-md focus-visible:outline-v2-border-border-focus"
                    onClick={() => edit(snippet)}
                  >
                    <span class="text-13-medium break-words text-v2-text-text-accent">#{snippet.name}</span>
                    <Show when={snippet.description}>
                      <span class="text-13-regular text-v2-text-text-muted break-words">{snippet.description}</span>
                    </Show>
                    <span class="text-11-regular text-v2-text-text-muted">{scopeLabel(snippet.project)}</span>
                    <Show when={snippet.aliases.length}>
                      <span class="text-11-regular text-v2-text-text-muted break-words">
                        {snippet.aliases.join(", ")}
                      </span>
                    </Show>
                  </button>
                  <Menu placement="bottom-end">
                    <Menu.Trigger
                      as={IconButton}
                      variant="ghost-muted"
                      icon={<Icon name="outline-dots" />}
                      aria-label={language.t("settings.snippets.actions", { name: snippet.name })}
                    />
                    <Menu.Portal>
                      <Menu.Content>
                        <Menu.Item onSelect={() => edit(snippet)}>{language.t("common.edit")}</Menu.Item>
                        <Menu.Item onSelect={() => settings.snippets.remove(snippet.id)}>
                          {language.t("common.delete")}
                        </Menu.Item>
                      </Menu.Content>
                    </Menu.Portal>
                  </Menu>
                </div>
              )}
            </For>
          </SettingsList>
        </Show>
      </div>
    </>
  )
}

function SnippetDialog(props: { snippet?: Snippet; projects: { id: string; label: string }[] }) {
  const language = useLanguage()
  const dialog = useDialog()
  const settings = useSettings()
  const [state, setState] = createStore({
    name: props.snippet?.name ?? "",
    description: props.snippet?.description ?? "",
    aliases: props.snippet?.aliases.join(", ") ?? "",
    content: props.snippet?.content ?? "",
    project: props.snippet?.project ?? "",
  })
  const scopes = createMemo(() => [
    { id: "global", label: language.t("settings.snippets.global") },
    ...props.projects,
    ...(state.project && !props.projects.some((item) => item.id === state.project)
      ? [{ id: state.project, label: language.t("settings.snippets.project") }]
      : []),
  ])
  const duplicate = () =>
    settings.snippets
      .list()
      .some(
        (item) =>
          item.id !== props.snippet?.id &&
          (item.project ?? "") === state.project &&
          item.name.toLowerCase() === state.name.trim().toLowerCase(),
      )
  const invalidName = () => !!state.name.trim() && /[\s#]/.test(state.name.trim())
  const valid = () => !!state.name.trim() && !!state.content.trim() && !invalidName() && !duplicate()
  return (
    <Dialog
      size="large"
      containerClass="!w-[min(640px,calc(100vw-32px))] !h-[min(760px,calc(100dvh-32px))]"
      class="min-h-0 !overflow-hidden"
    >
      <DialogHeader>
        <DialogTitle>{language.t(props.snippet ? "settings.snippets.edit" : "settings.snippets.add")}</DialogTitle>
      </DialogHeader>
      <form
        class="flex min-h-0 w-full flex-1 flex-col overflow-hidden"
        onSubmit={(event) => {
          event.preventDefault()
          if (!valid()) return
          settings.snippets.save({
            id: props.snippet?.id ?? crypto.randomUUID(),
            name: state.name.trim(),
            description: state.description.trim(),
            aliases: snippetAliases(state.aliases),
            content: state.content,
            project: state.project || undefined,
          })
          dialog.close()
        }}
      >
        <div class="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-6 pb-6">
          <Field invalid={invalidName() || duplicate()}>
            <Field.Label>{language.t("settings.snippets.name")}</Field.Label>
            <TextInput
              autofocus
              required
              class="!w-full"
              value={state.name}
              onInput={(event) => setState("name", event.currentTarget.value)}
              aria-label={language.t("settings.snippets.name")}
            />
            <span class="text-11-regular text-v2-text-text-muted">
              {language.t(duplicate() ? "settings.snippets.duplicate" : "settings.snippets.nameHint")}
            </span>
          </Field>
          <Field>
            <Field.Label>{language.t("settings.snippets.descriptionLabel")}</Field.Label>
            <TextInput
              class="!w-full"
              value={state.description}
              onInput={(event) => setState("description", event.currentTarget.value)}
              aria-label={language.t("settings.snippets.descriptionLabel")}
            />
          </Field>
          <Field>
            <Field.Label>{language.t("settings.snippets.aliases")}</Field.Label>
            <TextInput
              class="!w-full"
              value={state.aliases}
              onInput={(event) => setState("aliases", event.currentTarget.value)}
              aria-label={language.t("settings.snippets.aliases")}
            />
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.snippets.aliasesHint")}</span>
          </Field>
          <Field>
            <Field.Label>{language.t("settings.snippets.scope")}</Field.Label>
            <Select
              options={scopes()}
              current={scopes().find((item) => item.id === (state.project || "global"))}
              value={(item) => item.id}
              label={(item) => item.label}
              onSelect={(item) => {
                if (item) setState("project", item.id === "global" ? "" : item.id)
              }}
              aria-label={language.t("settings.snippets.scope")}
            />
          </Field>
          <Field>
            <Field.Label>{language.t("settings.snippets.content")}</Field.Label>
            <Textarea
              class="!w-full"
              required
              rows={8}
              value={state.content}
              onInput={(event) => setState("content", event.currentTarget.value)}
              aria-label={language.t("settings.snippets.content")}
            />
          </Field>
        </div>
        <DialogFooter>
          <Button type="button" variant="neutral" onClick={dialog.close}>
            {language.t("common.cancel")}
          </Button>
          <Button type="submit" variant="contrast" disabled={!valid()}>
            {language.t("common.save")}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  )
}
