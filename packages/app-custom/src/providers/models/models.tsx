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

const createModelsController = (directory: Accessor<string | undefined>) => {
  const providers = useProviders(() => directory())
  const models = useGlobal().models
  const store = models.store
  const setStore = models.set
  const preferences = models.preferences

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
  const getVariant = (model: ModelKey) => store.variant?.[variantKey(model)]

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
