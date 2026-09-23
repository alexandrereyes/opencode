import { createStore } from "solid-js/store"
import type { ServerSDK } from "@/runtime/server/client"
import type { Prompt } from "@/composer/state"

const instructions = [
  "The user is asking a quick side question about the conversation so far.",
  "Answer directly and concisely in markdown from what you already know.",
  "Do not call any tools and do not take any actions.",
].join(" ")

export function createBtwSessions(generate: ServerSDK["api"]["session"]["generate"]) {
  const sessions = new Map<string, BtwModel>()
  return (sessionID: string) => {
    const current = sessions.get(sessionID)
    if (current) {
      sessions.delete(sessionID)
      sessions.set(sessionID, current)
      return current
    }
    const state = createBtwState(sessionID, generate)
    sessions.set(sessionID, state)
    if (sessions.size > 20) {
      const oldest = sessions.keys().next().value
      if (oldest) {
        sessions.get(oldest)?.cancel()
        sessions.delete(oldest)
      }
    }
    return state
  }
}

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
    draftPrompt: undefined as Prompt | undefined,
    question: "",
    answer: "",
    history: [] as { question: string; answer: string }[],
    pending: false,
    error: false,
    cancelled: false,
    focus: 0,
  })
  // `sent` holds the composer draft cleared on submit, returned to the composer
  // when the question is cancelled or fails and nothing new was typed since.
  const request = {
    controller: undefined as AbortController | undefined,
    sent: undefined as { draft: string; draftPrompt?: Prompt } | undefined,
  }
  const restoreDraft = () => {
    const sent = request.sent
    request.sent = undefined
    if (sent && !state.draft.trim()) setState({ draft: sent.draft, draftPrompt: sent.draftPrompt })
  }
  const cancel = () => {
    if (!request.controller) return
    request.controller.abort()
    request.controller = undefined
    setState({ cancelled: true, pending: false })
    restoreDraft()
  }
  const open = (draft?: string) => {
    setState({
      open: true,
      collapsed: false,
      focus: state.focus + 1,
      ...(draft !== undefined ? { draft, draftPrompt: undefined } : {}),
    })
  }
  const ask = async (value: string, sent?: { draft: string; draftPrompt?: Prompt }) => {
    const question = value.trim()
    if (!question) return open()
    request.controller?.abort()
    const controller = new AbortController()
    request.controller = controller
    request.sent = sent
    const context = state.history.length
      ? `Previous side questions and answers (reference context):\n${JSON.stringify(state.history.map((entry) => ({ question: entry.question.slice(0, 1000), answer: entry.answer.slice(0, 3000) })))}`
      : ""
    setState({
      open: true,
      collapsed: false,
      question,
      ...(sent ? { draft: "", draftPrompt: undefined } : {}),
      answer: "",
      pending: true,
      error: false,
      cancelled: false,
    })
    await generate(
      { sessionID, prompt: [instructions, context, question].filter(Boolean).join("\n\n") },
      { signal: controller.signal },
    )
      .then((result) => {
        if (request.controller !== controller) return
        const answer = result.text.trim()
        setState({ answer, error: !answer })
        if (!answer) return restoreDraft()
        request.sent = undefined
        setState("history", (history) => [...history, { question, answer }].slice(-5))
      })
      .catch(() => {
        if (request.controller !== controller) return
        setState("error", true)
        restoreDraft()
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
    active: () => state.open && !state.collapsed,
    draft: (draft: string, draftPrompt?: Prompt) => setState({ draft, draftPrompt }),
    collapse: () => setState("collapsed", true),
    dismiss: () => {
      request.sent = undefined
      cancel()
      setState({
        open: false,
        collapsed: false,
        question: "",
        answer: "",
        history: [],
        draft: "",
        draftPrompt: undefined,
        error: false,
        cancelled: false,
      })
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
