import { Popover } from "@kobalte/core/popover"
import { Component, ComponentProps, createMemo, For, JSX, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { DragDropProvider, PointerSensor } from "@dnd-kit/solid"
import { isSortable, useSortable } from "@dnd-kit/solid/sortable"
import { AutoScroller, Feedback, PointerActivationConstraints } from "@dnd-kit/dom"
import { RestrictToVerticalAxis } from "@dnd-kit/abstract/modifiers"
import { RestrictToElement } from "@dnd-kit/dom/modifiers"
import { arrayMove } from "@dnd-kit/helpers"
import { Schema } from "effect"
import { useLocal, type ModelSelection } from "@/providers/models/selection"
import { useModels, type ModelKey } from "@/providers/models/models"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { popularProviders } from "@/providers/catalog/providers"
import { Button } from "@opencode/ui-custom/button"
import { Badge } from "@opencode/ui-custom/badge"
import { Dialog, DialogBody, DialogHeader, DialogTitle } from "@opencode/ui-custom/dialog"
import { Icon } from "@opencode/ui-custom/icon"
import { ScrollView } from "@opencode/ui-custom/scroll-view"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { ModelTooltip } from "./tooltip"
import { useLanguage } from "@/runtime/i18n/language"
import { decode64 } from "@/runtime/persistence/base64"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { Persistence } from "@/runtime/persistence/schema"
import { handleDocumentSearchKeydown } from "@/shell/commands/search-keydown"
import { createMenuDismissController } from "@/shell/commands/menu-dismiss"
import { createEventListener } from "@solid-primitives/event-listener"
import { matchesModelSearch } from "./search"

const isFree = (provider: string, cost: { input: number } | undefined) =>
  provider === "opencode" && (!cost || cost.input === 0)

type ModelState = ModelSelection
type ModelItem = ReturnType<ModelState["list"]>[number]
type Section = { id: string; provider?: string; items: ModelItem[] }
type Controller = ReturnType<typeof createModelSelectorController>

const FAVORITES = "favorites"
const manageKey = "action:manage"
const modelKey = (model: ModelItem) => `${model.provider.id}:${model.id}`
const refKey = (model: ModelKey) => `${model.providerID}:${model.modelID}`
const rowKey = (section: string, model: ModelItem) => `${section}|${modelKey(model)}`
const modelRef = (model: ModelItem) => ({ providerID: model.provider.id, modelID: model.id })

const SectionsSchema = Schema.Struct({
  collapsed: Persistence.record(Persistence.fallback(Schema.Boolean, () => false)),
})

const sortModelGroups = (a: { category: string; items: ModelItem[] }, b: { category: string; items: ModelItem[] }) => {
  const aIndex = popularProviders.indexOf(a.category)
  const bIndex = popularProviders.indexOf(b.category)
  const aPopular = aIndex >= 0
  const bPopular = bIndex >= 0

  if (aPopular && !bPopular) return -1
  if (!aPopular && bPopular) return 1
  if (aPopular && bPopular) return aIndex - bIndex
  return a.items[0].provider.name.localeCompare(b.items[0].provider.name)
}

function createModelSelectorController(input: {
  provider: () => string | undefined
  model?: ModelState
  onSelect: () => void
}) {
  const model = input.model ?? useLocal().model
  const models = useModels()
  const allModels = createMemo(() =>
    model
      .list()
      .filter((item) => model.visible({ modelID: item.id, providerID: item.provider.id }))
      .filter((item) => (input.provider() ? item.provider.id === input.provider() : true)),
  )
  const providerRank = createMemo(() => new Map(models.providerOrder.list().map((id, index) => [id, index])))
  const variants = (item: ModelItem) => Object.keys(item.variants ?? {})
  const isCurrent = (item: ModelItem) => {
    const value = model.current()
    return !!value && modelKey(value) === modelKey(item)
  }

  const controller = {
    sections: (search: string): Section[] => {
      const query = search.trim()
      const items = (
        query
          ? allModels().filter((item) => matchesModelSearch(query, [item.name, item.id, item.provider.name]))
          : allModels()
      ).toSorted((a, b) => a.name.localeCompare(b.name))
      const byKey = new Map(items.map((item) => [modelKey(item), item]))
      const favorites = models.favorite.list().flatMap((item) => byKey.get(refKey(item)) ?? [])
      const byProvider = Map.groupBy(items, (item) => item.provider.id)
      const rank = providerRank()
      const groups = Array.from(byProvider, ([category, items]) => ({ category, items })).sort((a, b) => {
        const aRank = rank.get(a.category)
        const bRank = rank.get(b.category)
        if (aRank !== undefined && bRank !== undefined) return aRank - bRank
        if (aRank !== undefined) return -1
        if (bRank !== undefined) return 1
        return sortModelGroups(a, b)
      })
      return [
        ...(favorites.length > 0 ? [{ id: FAVORITES, items: favorites }] : []),
        ...groups.map((group) => ({ id: `provider:${group.category}`, provider: group.category, items: group.items })),
      ]
    },
    current: () => {
      const value = model.current()
      return value ? modelKey(value) : undefined
    },
    variants,
    variant: (item: ModelItem) => {
      const value = isCurrent(item) ? model.variant.current() : models.variant.get(modelRef(item))
      return value && variants(item).includes(value) ? value : "default"
    },
    select: (item: ModelItem, variant?: string) => {
      model.set(modelRef(item), { recent: true })
      if (variant !== undefined) model.variant.set(variant === "default" ? undefined : variant)
      input.onSelect()
    },
    favorite: {
      has: (item: ModelItem) => models.favorite.has(modelRef(item)),
      toggle: (item: ModelItem) => models.favorite.set(modelRef(item), !models.favorite.has(modelRef(item))),
      // Hidden or filtered favorites keep their stored slots while visible ones move.
      order: (visible: string[]) =>
        models.favorite.order(
          reorderSubset(models.favorite.list(), visible, refKey).flatMap((key) => {
            const item = models.favorite.list().find((entry) => refKey(entry) === key)
            return item ? [item] : []
          }),
        ),
    },
    providers: {
      order: (visible: string[]) =>
        models.providerOrder.set(
          reorderSubset(
            [...models.providerOrder.list(), ...visible.filter((id) => !providerRank().has(id))],
            visible,
            (id) => id,
          ),
        ),
    },
    default: {
      is: (item: ModelItem, variant?: string) => {
        const value = models.default.get()
        if (!value || refKey(value) !== modelKey(item)) return false
        return variant === undefined || (value.variant ?? "default") === variant
      },
      toggle: (item: ModelItem, variant: string) => {
        if (controller.default.is(item, variant)) {
          models.default.set(undefined)
          return
        }
        models.default.set({ ...modelRef(item), variant: variant === "default" ? undefined : variant })
      },
    },
  }
  return controller
}

function reorderSubset<T>(all: T[], visible: string[], key: (item: T) => string) {
  const shown = new Set(visible)
  const next = [...visible]
  return all.map((item) => (shown.has(key(item)) ? next.shift()! : key(item)))
}

export function ModelSelectorPopover(props: {
  provider?: string
  model?: ModelState
  trigger: ModelSelectorTrigger
  onClose?: () => void
}) {
  const dialog = useDialog()
  const controller = createModelSelectorController({
    model: props.model,
    provider: () => props.provider,
    onSelect: () => props.onClose?.(),
  })
  const [store, setStore] = createStore({ open: false })
  let contentRef: HTMLElement | undefined
  const dismiss = createMenuDismissController(() => contentRef)
  const setOpen = (open: boolean) => {
    if (open) dismiss.allowTriggerRestore()
    setStore("open", open)
  }
  const close = (after: () => void) => {
    dismiss.preventTriggerRestore()
    setOpen(false)
    dismiss.afterClose(after)
  }

  return (
    <Popover open={store.open} modal={false} placement="top-start" gutter={6} onOpenChange={setOpen}>
      <Popover.Trigger as={props.trigger} />
      <Popover.Portal>
        <Popover.Content
          data-slot="composer-model-menu"
          ref={(element) => (contentRef = element)}
          class="z-[60] flex w-[360px] max-w-[calc(100vw-16px)] flex-col overflow-hidden rounded-md bg-v2-background-bg-layer-01 shadow-[var(--v2-elevation-floating)] outline-none"
          onOpenAutoFocus={(event: Event) => event.preventDefault()}
          onPointerDownOutside={dismiss.preventTriggerRestore}
          onFocusOutside={dismiss.preventTriggerRestore}
          onCloseAutoFocus={dismiss.onCloseAutoFocus}
        >
          <ModelPicker
            controller={controller}
            scrollClass="max-h-[min(360px,calc(var(--kb-popper-content-available-height)-112px))]"
            onSelect={(item, variant) => close(() => controller.select(item, variant))}
            onManage={() =>
              close(() => {
                void import("./manage").then((module) => {
                  void dialog.show(() => <module.DialogManageModels />)
                })
              })
            }
            onEscape={() => close(() => props.onClose?.())}
          />
        </Popover.Content>
      </Popover.Portal>
    </Popover>
  )
}

type ModelSelectorTriggerProps = Omit<ComponentProps<typeof Popover.Trigger>, "as" | "ref">
type ModelSelectorTrigger = (props: ModelSelectorTriggerProps) => JSX.Element

function ModelPicker(props: {
  controller: Controller
  scrollClass: string
  onSelect: (item: ModelItem, variant?: string) => void
  onManage: () => void
  onEscape?: () => void
}) {
  const language = useLanguage()
  const [saved, setSaved] = persisted(Persist.global("model-picker.sections"), SectionsSchema, { collapsed: {} })
  const [store, setStore] = createStore({
    search: "",
    active: "",
    pending: {} as Record<string, string>,
  })
  let searchRef: HTMLInputElement | undefined
  let rootRef: HTMLDivElement | undefined

  const sections = createMemo(() => props.controller.sections(store.search))
  const searching = () => store.search.trim().length > 0
  const expanded = (id: string) => searching() || !saved.collapsed[id]
  const rows = createMemo(() =>
    sections().flatMap((section) =>
      expanded(section.id) ? section.items.map((item) => ({ key: rowKey(section.id, item), item })) : [],
    ),
  )
  const keys = () => [...rows().map((row) => row.key), manageKey]
  const activeRow = () => rows().find((row) => row.key === store.active)
  const variant = (item: ModelItem) => store.pending[modelKey(item)] ?? props.controller.variant(item)
  const scrollToActive = () =>
    queueMicrotask(() =>
      rootRef
        ?.querySelector<HTMLElement>(`[data-option-key="${CSS.escape(store.active)}"]`)
        ?.scrollIntoView({ block: "nearest" }),
    )

  const initialActive = () => {
    const current = props.controller.current()
    return rows().find((row) => modelKey(row.item) === current)?.key ?? keys()[0] ?? ""
  }
  setStore("active", initialActive())
  requestAnimationFrame(() => {
    searchRef?.focus()
    scrollToActive()
  })

  const setSearch = (value: string) => {
    setStore("search", value)
    setStore("active", keys()[0] ?? "")
  }
  const moveActive = (delta: number) => {
    const options = keys()
    const index = options.indexOf(store.active)
    const start = index === -1 ? 0 : index
    setStore("active", options[(start + delta + options.length) % options.length])
    scrollToActive()
  }
  const cycleVariant = (delta: number) => {
    const row = activeRow()
    if (!row) return false
    const options = ["default", ...props.controller.variants(row.item)]
    if (options.length === 1) return false
    const index = options.indexOf(variant(row.item))
    setStore("pending", modelKey(row.item), options[(index + delta + options.length) % options.length])
    return true
  }
  const select = (item: ModelItem) => props.onSelect(item, store.pending[modelKey(item)])
  const selectActive = () => {
    const row = activeRow()
    if (row) {
      select(row.item)
      return
    }
    if (store.active === manageKey) props.onManage()
  }

  const row = (section: string, item: ModelItem, handle?: (element: HTMLElement) => void) => (
    <ModelRow
      item={item}
      rowKey={rowKey(section, item)}
      active={store.active === rowKey(section, item)}
      current={props.controller.current() === modelKey(item)}
      variant={variant(item)}
      controller={props.controller}
      handle={handle}
      onHover={() => setStore("active", rowKey(section, item))}
      onSelect={() => select(item)}
    />
  )
  const favorites = () => sections().find((section) => section.id === FAVORITES)
  const providers = () => sections().filter((section) => section.id !== FAVORITES)
  let favoritesRef!: HTMLDivElement
  let providersRef!: HTMLDivElement

  createEventListener(
    document,
    "keydown",
    (event: KeyboardEvent) => handleDocumentSearchKeydown(searchRef, event, store.search, setSearch),
    true,
  )

  return (
    <div ref={(element) => (rootRef = element)} class="flex min-h-0 flex-1 flex-col">
      <div class="flex flex-col p-0.5">
        <div
          data-slot="composer-model-search"
          class="flex h-7 items-center gap-2 rounded-sm pl-3 pr-2.5 text-v2-icon-icon-muted"
        >
          <Icon name="magnifying-glass" size="small" class="shrink-0" />
          <input
            ref={(element) => (searchRef = element)}
            value={store.search}
            placeholder={language.t("dialog.model.search.placeholder")}
            aria-label={language.t("dialog.model.search.placeholder")}
            autofocus
            class="h-7 min-w-0 flex-1 border-0 bg-transparent text-[13px] font-[440] leading-5 tracking-[-0.04px] text-v2-text-text-base outline-none placeholder:text-v2-text-text-faint"
            spellcheck={false}
            autocorrect="off"
            autocomplete="off"
            autocapitalize="off"
            onInput={(event) => setSearch(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === "Tab") return
              if (event.key === "Escape") {
                if (!props.onEscape) return
                event.stopPropagation()
                event.preventDefault()
                props.onEscape()
                return
              }
              event.stopPropagation()
              if (event.altKey || event.metaKey) return
              if (event.key === "ArrowDown") {
                event.preventDefault()
                moveActive(1)
                return
              }
              if (event.key === "ArrowUp") {
                event.preventDefault()
                moveActive(-1)
                return
              }
              if ((event.key === "ArrowLeft" || event.key === "ArrowRight") && !event.shiftKey) {
                if (cycleVariant(event.key === "ArrowRight" ? 1 : -1)) event.preventDefault()
                return
              }
              if (event.key === "Enter" && !event.isComposing) {
                event.preventDefault()
                selectActive()
              }
            }}
          />
          <Show when={store.search.trim()}>
            <button
              type="button"
              class="flex size-5 items-center justify-center rounded-sm text-v2-icon-icon-muted hover:bg-v2-overlay-simple-overlay-hover"
              onPointerDown={(event) => event.preventDefault()}
              onClick={() => setSearch("")}
              aria-label={language.t("common.clear")}
            >
              <Icon name="close" size="small" />
            </button>
          </Show>
        </div>
      </div>
      <div class="h-px bg-v2-border-border-muted" />
      <ScrollView data-slot="model-selector-scroll" class={`min-h-0 ${props.scrollClass}`}>
        <div role="listbox" aria-label={language.t("dialog.model.select.title")} class="flex flex-col p-0.5 pt-0">
          <Show
            when={sections().length > 0}
            fallback={
              <div class="flex h-12 items-center px-3 text-[13px] font-[440] leading-5 tracking-[-0.04px] text-v2-text-text-faint">
                {language.t("dialog.model.empty")}
              </div>
            }
          >
            <Show when={favorites()}>
              {(section) => (
                <div role="group" aria-label={language.t("dialog.model.favorites")}>
                  <SectionHeader
                    open={expanded(FAVORITES)}
                    searching={searching()}
                    icon={<Icon name="star-fill" size="small" class="shrink-0 text-v2-icon-icon-base" />}
                    label={language.t("dialog.model.favorites")}
                    onToggle={() => setSaved("collapsed", FAVORITES, expanded(FAVORITES))}
                  />
                  <Show when={expanded(FAVORITES)}>
                    <Sortable
                      container={() => favoritesRef}
                      ids={() => section().items.map(modelKey)}
                      onReorder={props.controller.favorite.order}
                    >
                      <div ref={favoritesRef} class="flex flex-col">
                        <For each={section().items.map(modelKey)}>
                          {(id, index) => (
                            <SortableItem id={id} index={index()} disabled={searching()}>
                              {(sortable) => (
                                <Show when={section().items.find((item) => modelKey(item) === id)}>
                                  {(item) => (
                                    <div ref={sortable.ref} classList={{ "opacity-60": sortable.isDragSource() }}>
                                      {row(FAVORITES, item(), searching() ? undefined : sortable.handleRef)}
                                    </div>
                                  )}
                                </Show>
                              )}
                            </SortableItem>
                          )}
                        </For>
                      </div>
                    </Sortable>
                  </Show>
                </div>
              )}
            </Show>
            <Sortable
              container={() => providersRef}
              ids={() => providers().map((section) => section.provider!)}
              onReorder={props.controller.providers.order}
            >
              <div ref={providersRef} class="flex flex-col">
                <For each={providers().map((section) => section.provider!)}>
                  {(provider, index) => (
                    <SortableItem id={provider} index={index()} disabled={searching()}>
                      {(sortable) => (
                        <Show when={providers().find((section) => section.provider === provider)}>
                          {(section) => (
                            <div
                              ref={sortable.ref}
                              role="group"
                              aria-label={section().items[0].provider.name}
                              classList={{ "opacity-60": sortable.isDragSource() }}
                            >
                              <SectionHeader
                                open={expanded(section().id)}
                                searching={searching()}
                                handle={searching() ? undefined : sortable.handleRef}
                                reorderLabel={language.t("dialog.model.provider.reorder")}
                                icon={<ProviderIcon id={provider} width={14} height={14} class="shrink-0" />}
                                label={section().items[0].provider.name}
                                onToggle={() => setSaved("collapsed", section().id, expanded(section().id))}
                              />
                              <Show when={expanded(section().id)}>
                                <For each={section().items}>{(item) => row(section().id, item)}</For>
                              </Show>
                            </div>
                          )}
                        </Show>
                      )}
                    </SortableItem>
                  )}
                </For>
              </div>
            </Sortable>
          </Show>
        </div>
      </ScrollView>
      <div class="h-px bg-v2-border-border-muted" />
      <div class="flex flex-col p-0.5">
        <button
          type="button"
          data-option-key={manageKey}
          class="flex h-7 items-center gap-2 rounded-sm px-3 text-start text-[13px] font-[440] leading-[var(--line-height-compact)] tracking-[-0.04px] text-v2-text-text-base outline-none"
          classList={{ "bg-v2-overlay-simple-overlay-hover": store.active === manageKey }}
          onPointerDown={(event) => event.preventDefault()}
          onMouseEnter={() => setStore("active", manageKey)}
          onClick={() => props.onManage()}
        >
          <Icon name="outline-sliders" size="small" />
          <span class="min-w-0 flex-1 truncate">{language.t("dialog.model.manage")}</span>
        </button>
      </div>
      <div class="flex h-7 shrink-0 items-center gap-3 border-t border-v2-border-border-muted px-3 text-[11px] font-[530] leading-[var(--line-height-tight)] tracking-[0.05px] text-v2-text-text-faint">
        <span>{language.t("dialog.model.hint.navigate")}</span>
        <Show when={activeRow() && props.controller.variants(activeRow()!.item).length > 0}>
          <span>{language.t("dialog.model.hint.thinking")}</span>
        </Show>
      </div>
    </div>
  )
}

function ModelRow(props: {
  item: ModelItem
  rowKey: string
  active: boolean
  current: boolean
  variant: string
  controller: Controller
  handle?: (element: HTMLElement) => void
  onHover: () => void
  onSelect: () => void
}) {
  const language = useLanguage()
  const context = () =>
    props.item.limit?.context
      ? new Intl.NumberFormat(language.intl(), { notation: "compact", maximumFractionDigits: 1 }).format(
          props.item.limit.context,
        )
      : undefined
  const favorite = () => props.controller.favorite.has(props.item)
  const isDefault = () => props.controller.default.is(props.item)
  const defaultMatches = () => props.controller.default.is(props.item, props.variant)
  const thinking = () => props.controller.variants(props.item).length > 0 && (props.active || props.current)
  const action = (run: () => void) => ({
    onPointerDown: (event: PointerEvent) => event.preventDefault(),
    onClick: (event: MouseEvent) => {
      event.stopPropagation()
      run()
    },
  })

  return (
    <div
      role="option"
      aria-selected={props.current}
      data-option-key={props.rowKey}
      data-selected-model={props.current ? true : undefined}
      class="group/model-row flex h-7 shrink-0 cursor-default scroll-my-6 items-center gap-2 rounded-sm pe-1.5 text-[13px] font-[440] leading-[var(--line-height-compact)] tracking-[-0.04px] text-v2-text-text-base select-none"
      classList={{
        "bg-v2-overlay-simple-overlay-hover": props.active,
        "ps-1": !!props.handle,
        "ps-3": !props.handle,
      }}
      onMouseEnter={props.onHover}
      onPointerDown={(event) => event.preventDefault()}
      onClick={props.onSelect}
    >
      <Show when={props.handle}>
        {(handle) => <DragHandle ref={handle()} label={language.t("dialog.model.favorite.reorder")} />}
      </Show>
      <div class="flex min-w-0 flex-1 items-center gap-2">
        <Tooltip
          class="min-w-0"
          placement="right-start"
          gutter={12}
          openDelay={0}
          value={
            <ModelTooltip
              model={props.item}
              latest={props.item.latest}
              free={isFree(props.item.provider.id, props.item.cost)}
              v2
            />
          }
        >
          <span class="block min-w-0 truncate">{props.item.name}</span>
        </Tooltip>
        <Show when={context()}>
          {(value) => <span class="shrink-0 text-[11px] font-[530] text-v2-text-text-faint">{value()}</span>}
        </Show>
        <Show when={isFree(props.item.provider.id, props.item.cost)}>
          <Badge class="shrink-0">{language.t("model.tag.free")}</Badge>
        </Show>
        <Show when={props.item.latest}>
          <Badge class="shrink-0">{language.t("model.tag.latest")}</Badge>
        </Show>
        <Show when={isDefault()}>
          <Badge class="shrink-0">{language.t("common.default")}</Badge>
        </Show>
      </div>
      <Show when={thinking()}>
        <span class="shrink-0 whitespace-nowrap text-[11px] font-[530] text-v2-text-text-faint">
          {language.t("dialog.model.thinking", { variant: props.variant })}
        </span>
      </Show>
      <Tooltip
        placement="top"
        value={language.t(defaultMatches() ? "dialog.model.default.remove" : "dialog.model.default.set")}
      >
        <button
          type="button"
          data-action="model-default"
          aria-pressed={defaultMatches()}
          aria-label={language.t(defaultMatches() ? "dialog.model.default.remove" : "dialog.model.default.set")}
          class="flex size-5 shrink-0 items-center justify-center rounded-sm hover:bg-v2-overlay-simple-overlay-hover focus-visible:opacity-100"
          classList={{
            "text-v2-icon-icon-base": isDefault(),
            "text-v2-icon-icon-muted opacity-0 group-hover/model-row:opacity-100 [@media(hover:none)]:opacity-100":
              !isDefault(),
            "opacity-100": props.active,
          }}
          {...action(() => props.controller.default.toggle(props.item, props.variant))}
        >
          <Icon name="pin" size="small" />
        </button>
      </Tooltip>
      <button
        type="button"
        data-action="model-favorite"
        aria-pressed={favorite()}
        aria-label={language.t(favorite() ? "dialog.model.favorite.remove" : "dialog.model.favorite.add")}
        class="flex size-5 shrink-0 items-center justify-center rounded-sm hover:bg-v2-overlay-simple-overlay-hover"
        classList={{
          "text-v2-icon-icon-base": favorite(),
          "text-v2-icon-icon-muted": !favorite(),
        }}
        {...action(() => props.controller.favorite.toggle(props.item))}
      >
        <Icon name={favorite() ? "star-fill" : "star"} size="small" />
      </button>
      <span class="flex size-4 shrink-0 items-center justify-center">
        <Show when={props.current}>
          <Icon name="check" size="small" class="text-v2-icon-icon-base" />
        </Show>
      </span>
    </div>
  )
}

function SectionHeader(props: {
  open: boolean
  searching: boolean
  icon: JSX.Element
  label: string
  handle?: (element: HTMLElement) => void
  reorderLabel?: string
  onToggle: () => void
}) {
  return (
    <div
      class="flex h-7 items-center gap-2 pe-1.5 text-[11px] font-[530] leading-[var(--line-height-tight)] tracking-[0.05px] text-v2-text-text-faint select-none"
      classList={{ "ps-1": !!props.handle, "ps-3": !props.handle }}
    >
      <Show when={props.handle}>{(handle) => <DragHandle ref={handle()} label={props.reorderLabel ?? ""} />}</Show>
      <button
        type="button"
        class="flex h-full min-w-0 flex-1 items-center gap-2 text-start outline-none disabled:cursor-default"
        aria-expanded={props.open}
        disabled={props.searching}
        onPointerDown={(event) => event.preventDefault()}
        onClick={props.onToggle}
      >
        {props.icon}
        <span class="min-w-0 flex-1 truncate">{props.label}</span>
        <Show when={!props.searching}>
          <Icon name="chevron-down" size="small" classList={{ "-rotate-90 rtl:rotate-90": !props.open }} />
        </Show>
      </button>
    </div>
  )
}

function DragHandle(props: { ref: (element: HTMLElement) => void; label: string }) {
  return (
    <button
      ref={props.ref}
      type="button"
      class="grid shrink-0 cursor-grab touch-none grid-cols-2 gap-x-[2px] gap-y-[2.25px] p-1"
      aria-label={props.label}
      onPointerDown={(event) => event.preventDefault()}
      onClick={(event) => event.stopPropagation()}
    >
      <For each={Array.from({ length: 6 })}>{() => <span class="size-[2px] bg-v2-background-bg-layer-04" />}</For>
    </button>
  )
}

function Sortable(props: {
  container: () => HTMLElement
  ids: () => string[]
  onReorder: (ids: string[]) => void
  children: JSX.Element
}) {
  return (
    <DragDropProvider
      sensors={(defaults) => [
        ...defaults.filter((sensor) => sensor !== PointerSensor),
        PointerSensor.configure({
          activationConstraints: [new PointerActivationConstraints.Distance({ value: 4 })],
        }),
      ]}
      modifiers={[RestrictToVerticalAxis, RestrictToElement.configure({ element: props.container })]}
      plugins={(defaults) => [
        ...defaults.filter((plugin) => plugin !== AutoScroller && plugin !== Feedback),
        AutoScroller.configure({ acceleration: 8, threshold: { x: 0, y: 0.1 } }),
        Feedback.configure({ dropAnimation: null }),
      ]}
      onDragEnd={(event) => {
        const source = event.operation.source
        if (event.canceled || !isSortable(source)) return
        if (source.initialIndex === source.index) return
        props.onReorder(arrayMove(props.ids(), source.initialIndex, source.index))
      }}
    >
      {props.children}
    </DragDropProvider>
  )
}

function SortableItem(props: {
  id: string
  index: number
  disabled: boolean
  children: (sortable: ReturnType<typeof useSortable>) => JSX.Element
}) {
  const sortable = useSortable({
    get id() {
      return props.id
    },
    get index() {
      return props.index
    },
    get disabled() {
      return props.disabled
    },
  })
  return <>{props.children(sortable)}</>
}

export const DialogSelectModel: Component<{ provider?: string; model?: ModelState }> = (props) => {
  const dialog = useDialog()
  const language = useLanguage()
  const local = useLocal()
  const directory = () => decode64(local.slug())
  const controller = createModelSelectorController({
    model: props.model,
    provider: () => props.provider,
    onSelect: () => dialog.close(),
  })

  const provider = () => {
    void import("@/providers/connect/dialog").then((x) => {
      void dialog.show(() => <x.DialogConnectProvider directory={directory()} />)
    })
  }

  const manage = () => {
    void import("./manage").then((x) => {
      dialog.show(() => <x.DialogManageModels />)
    })
  }

  return (
    <Dialog size="large" variant="settings">
      <DialogHeader hideClose closeLabel={language.t("common.close")}>
        <DialogTitle>{language.t("dialog.model.select.title")}</DialogTitle>
        <Button icon="plus" onClick={provider}>
          {language.t("command.provider.connect")}
        </Button>
      </DialogHeader>
      <DialogBody class="flex min-h-0 flex-1 flex-col">
        <ModelPicker
          controller={controller}
          scrollClass="flex-1"
          onSelect={(item, variant) => controller.select(item, variant)}
          onManage={manage}
        />
      </DialogBody>
    </Dialog>
  )
}
