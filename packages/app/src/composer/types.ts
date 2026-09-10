import type {
  AgentPart,
  AppPart,
  ComposerStore,
  FileAttachmentPart,
  ImageAttachmentPart,
  Prompt,
  SessionPart,
  SkillPart,
  SnippetPart,
} from "./state"

export type ComposerFilePart = FileAttachmentPart
export type ComposerAgentPart = AgentPart
export type ComposerSkillPart = SkillPart
export type ComposerSnippetPart = SnippetPart
export type ComposerAppPart = AppPart
export type ComposerSessionPart = SessionPart
export type ComposerAttachment = ImageAttachmentPart
export type ComposerPrompt = Prompt
export type ComposerComment = ComposerStore["context"]["items"][number]
export type ComposerPersistedState = ComposerStore

export type ComposerHistoryEntry = {
  prompt: ComposerPrompt
  metadata?: unknown
}

export type ComposerHistory = {
  entries: (mode: "normal" | "shell") => ComposerHistoryEntry[]
  add: (prompt: ComposerPrompt, mode: "normal" | "shell") => void
  capture?: () => unknown
  restore?: (metadata: unknown) => void
}

export type ComposerOption = {
  id: string
  label: string
  providerID?: string
}

export type ComposerSuggestion = {
  id: string
  kind: "agent" | "command" | "file" | "reference" | "resource" | "skill" | "app" | "session" | "snippet"
  label: string
  title?: string
  trigger?: string
  description?: string
  search?: string
  path?: string
  keybind?: string[]
  recent?: boolean
  detail?: string
  kindLabel?: string
  mention?:
    | ComposerFilePart
    | ComposerAgentPart
    | ComposerSkillPart
    | ComposerAppPart
    | ComposerSessionPart
    | ComposerSnippetPart
}
