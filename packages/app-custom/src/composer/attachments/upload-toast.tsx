import { createEffect, createRoot, For, onCleanup } from "solid-js"
import { Toast, toaster } from "@opencode/ui-custom/toast"
import { Icon } from "@opencode/ui-custom/icon"
import { useLanguage } from "@/runtime/i18n/language"
import { uploads } from "./uploads"

export function UploadToastHost() {
  const language = useLanguage()
  let active: { id: number; dispose: () => void } | undefined
  const dismiss = () => {
    if (!active) return
    toaster.dismiss(active.id)
    active.dispose()
    active = undefined
  }
  createEffect(() => {
    if (!uploads.items().length) return dismiss()
    if (active) return
    const id = toaster.show(
      (props) =>
        createRoot((dispose) => {
          active = { id: props.toastId, dispose }
          return (
            <Toast toastId={props.toastId}>
              <Toast.Content>
                <For each={uploads.items()}>
                  {(item) => (
                    <div data-component="attachment-upload-toast">
                      <span title={item.filename}>{item.filename}</span>
                      <span>
                        {language.t("prompt.toast.uploading.percent", {
                          percent: item.size ? Math.floor((item.loaded / item.size) * 100) : 100,
                        })}
                      </span>
                      <progress aria-label={item.filename} max={item.size || 1} value={item.loaded} />
                      <button
                        type="button"
                        aria-label={language.t("prompt.toast.uploading.cancel")}
                        onClick={() => item.cancel()}
                      >
                        <Icon name="outline-xmark" />
                      </button>
                    </div>
                  )}
                </For>
              </Toast.Content>
            </Toast>
          )
        }),
      { persistent: true, resize: () => uploads.items().length },
    )
    active ??= { id, dispose: () => {} }
  })
  onCleanup(dismiss)
  return null
}
