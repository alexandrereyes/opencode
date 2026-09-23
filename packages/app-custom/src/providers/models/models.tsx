import { type Accessor, createMemo } from "solid-js"
import { uniqueBy } from "remeda"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { useProviders } from "@/providers/catalog/providers"
import { useGlobal } from "@/runtime/server/runtime"

export type ModelKey = { providerID: string; modelID: string }

type Visibility = "show" | "hide"
const RECENT_LIMIT = 5

function modelKey(model: ModelKey) {
  return `${model.providerID}:${model.modelID}`
}

// Callers may pass richer model objects; persist only the reference.
function key(model: ModelKey) {
  return { providerID: model.providerID, modelID: model.modelID }
}

const createModelsController = (directory: Accessor<string | undefined>) => {
  const providers = useProviders(() => directory())
  const models = useGlobal().models
  const store = models.store
  const setStore = models.set
  const preferences = models.preferences
  const saved = () => preferences.profile().data.models
  const same = (a: ModelKey, b: ModelKey) => a.providerID === b.providerID && a.modelID === b.modelID

  const available = createMemo(() =>
    providers.connected().flatMap((p) =>
      Object.values(p.models).map((m) => ({
        ...m,
        provider: p,
      })),
    ),
  )

  const visibility = createMemo(() => {
    const map = new Map<string, Visibility>()
    for (const item of store.user) map.set(`${item.providerID}:${item.modelID}`, item.visibility)
    return map
  })

  const list = createMemo(() =>
    available().map((m) => ({
      ...m,
      name: m.name.replace("(latest)", "").trim(),
      latest: m.name.includes("(latest)"),
    })),
  )

  const find = (key: ModelKey) => list().find((m) => m.id === key.modelID && m.provider.id === key.providerID)

  function update(model: ModelKey, state: Visibility) {
    const index = store.user.findIndex((x) => x.modelID === model.modelID && x.providerID === model.providerID)
    if (index >= 0) {
      setStore("user", index, (current) => ({ ...current, visibility: state }))
      void preferences.mutate({ type: "model.visibility", ...model, visibility: state })
      return
    }
    setStore("user", store.user.length, { ...model, visibility: state })
    void preferences.mutate({ type: "model.visibility", ...model, visibility: state })
  }

  const visible = (model: ModelKey) => visibility().get(modelKey(model)) === "show"

  const setVisibility = (model: ModelKey, state: boolean) => {
    update(model, state ? "show" : "hide")
  }

  const push = (model: ModelKey) => {
    const uniq = uniqueBy([model, ...store.recent], (x) => `${x.providerID}:${x.modelID}`)
    if (uniq.length > RECENT_LIMIT) uniq.pop()
    setStore("recent", uniq)
  }

  const variantKey = (model: ModelKey) => `${model.providerID}/${model.modelID}`
  // The web default model starts new selections with the thinking level saved alongside it.
  const getVariant = (model: ModelKey) => {
    const fallback = saved().default
    if (fallback && same(fallback, model)) return fallback.variant ?? "default"
    return store.variant?.[variantKey(model)]
  }

  const setVariant = (model: ModelKey, value: string | undefined) => {
    const key = variantKey(model)
    if (!store.variant) {
      setStore("variant", { [key]: value ?? "default" })
      void preferences.mutate({ type: "model.variant", ...model, variant: value ?? "default" })
      return
    }
    setStore("variant", key, value ?? "default")
    void preferences.mutate({ type: "model.variant", ...model, variant: value ?? "default" })
  }

  return {
    ready: models.ready,
    list,
    find,
    visible,
    setVisibility,
    favorite: {
      list: (): ModelKey[] => [...(saved().favorites ?? [])],
      has: (model: ModelKey) => (saved().favorites ?? []).some((item) => same(item, model)),
      set: (model: ModelKey, favorite: boolean) =>
        void preferences.mutate({ type: "model.favorite", ...key(model), favorite }),
      order: (favorites: ModelKey[]) =>
        void preferences.mutate({ type: "model.favorite.order", favorites: favorites.map(key) }),
    },
    providerOrder: {
      list: () => [...(saved().providerOrder ?? [])],
      set: (order: string[]) => void preferences.mutate({ type: "model.provider.order", order }),
    },
    default: {
      get: () => saved().default,
      is: (model: ModelKey) => {
        const current = saved().default
        return !!current && same(current, model)
      },
      set: (model: (ModelKey & { variant?: string }) | undefined) =>
        void preferences.mutate({
          type: "model.default",
          model: model ? { ...key(model), ...(model.variant ? { variant: model.variant } : {}) } : null,
        }),
    },
    recent: {
      list: models.recent,
      push,
    },
    variant: {
      get: getVariant,
      set: setVariant,
    },
  }
}

export const { use: useModels, provider: ModelsProvider } = createSimpleContext({
  name: "Models",
  gate: false,
  init: (props: { directory?: string | Accessor<string | undefined> } = {}) => {
    return createModelsController(() => (typeof props.directory === "function" ? props.directory() : props.directory))
  },
})
