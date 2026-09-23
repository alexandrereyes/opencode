import { createStore } from "solid-js/store"
import type { ServerSDK } from "@/runtime/server/client"

const instructions = [
  "The user is asking a quick side question about the conversation so far.",
  "Answer directly and concisely in markdown from what you already know.",
  "Do not call any tools and do not take any actions.",
].join(" ")

export function btwQuestion(text: string) {
  const match = /^\/btw(?:\s+([\s\S]*))?$/.exec(text.trim())
  return match ? (match[1]?.trim() ?? "") : undefined
}

// Presentation inspired by OpenChamber's MIT-licensed useBtwStore/BtwPanel.
// Generation is transient: no fork, durable messages, or session selection writes.
export function createBtwState(sessionID: string, generate: ServerSDK["api"]["session"]["generate"]) {
  const [state, setState] = createStore({
    open: false,
    collapsed: false,
    draft: "",
    question: "",
    answer: "",
    pending: false,
    error: false,
    focus: 0,
  })
  const request = { controller: undefined as AbortController | undefined }
  const cancel = () => {
    request.controller?.abort()
    request.controller = undefined
    setState("pending", false)
  }
  const open = (draft?: string) => {
    setState({ open: true, collapsed: false, focus: state.focus + 1, ...(draft !== undefined ? { draft } : {}) })
  }
  const ask = async (value = state.draft) => {
    const question = value.trim()
    if (!question) return open()
    cancel()
    const controller = new AbortController()
    request.controller = controller
    setState({ open: true, collapsed: false, question, draft: question, answer: "", pending: true, error: false })
    await generate({ sessionID, prompt: `${instructions}\n\n${question}` }, { signal: controller.signal })
      .then((result) => {
        if (request.controller !== controller) return
        const answer = result.text.trim()
        setState({ answer, error: !answer })
      })
      .catch(() => {
        if (request.controller === controller) setState("error", true)
      })
      .finally(() => {
        if (request.controller !== controller) return
        request.controller = undefined
        setState("pending", false)
      })
  }
  return {
    state,
    open,
    ask,
    cancel,
    draft: (draft: string) => setState("draft", draft),
    collapse: () => setState("collapsed", true),
    dismiss: () => {
      cancel()
      setState({ open: false, collapsed: false, question: "", answer: "", draft: "", error: false })
    },
    submitSlash: (text: string) => {
      const question = btwQuestion(text)
      if (question === undefined) return false
      if (question) void ask(question)
      if (!question) open()
      return true
    },
  }
}

export type BtwModel = ReturnType<typeof createBtwState>
