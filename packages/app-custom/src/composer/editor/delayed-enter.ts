type EnterModifiers = Pick<KeyboardEvent, "shiftKey" | "ctrlKey" | "metaKey">

export function preserveDelayedEnterModifiers(target: HTMLElement) {
  let deferred: EnterModifiers | undefined
  let timer: number | undefined
  const clear = () => {
    deferred = undefined
    if (timer !== undefined) window.clearTimeout(timer)
    timer = undefined
  }
  const keydown = (event: KeyboardEvent) => {
    if (event.key !== "Enter") return
    if ((event as KeyboardEvent & { synthetic?: boolean }).synthetic) {
      if (deferred?.shiftKey) Object.defineProperty(event, "shiftKey", { value: true })
      if (deferred?.ctrlKey) Object.defineProperty(event, "ctrlKey", { value: true })
      if (deferred?.metaKey) Object.defineProperty(event, "metaKey", { value: true })
      clear()
      return
    }
    clear()
    deferred = { shiftKey: event.shiftKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey }
    timer = window.setTimeout(clear, 500)
  }

  target.addEventListener("keydown", keydown, { capture: true })
  return () => {
    clear()
    target.removeEventListener("keydown", keydown, { capture: true })
  }
}
