import { useDialog } from "@opencode/ui-custom/context/dialog"
import { useI18n } from "@opencode/ui-custom/context/i18n"
import { ImagePreview } from "@opencode/ui-custom/image-preview"

export function createImagePreview() {
  const dialog = useDialog()
  const i18n = useI18n()
  const open = (event: MouseEvent | KeyboardEvent) => {
    if (!(event.currentTarget instanceof HTMLImageElement)) return
    const src = event.currentTarget.currentSrc || event.currentTarget.getAttribute("src")
    if (!src) return
    event.preventDefault()
    event.stopPropagation()
    const alt = event.currentTarget.alt || i18n.t("ui.imagePreview.alt")
    dialog.show(() => <ImagePreview src={src} alt={alt} />)
  }
  return (root: HTMLElement) => {
    root.querySelectorAll<HTMLImageElement>("img").forEach((image) => {
      image.setAttribute("role", "button")
      image.setAttribute("aria-haspopup", "dialog")
      image.setAttribute("aria-label", image.alt || i18n.t("ui.imagePreview.alt"))
      image.tabIndex = 0
      image.onclick = open
      image.onkeydown = (event) => {
        if (event.key === "Enter" || event.key === " ") open(event)
      }
    })
  }
}
