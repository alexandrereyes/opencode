import { createEffect, on, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { TextShimmer } from "@opencode/ui-custom/text-shimmer"
import { useLanguage } from "@/runtime/i18n/language"
import { sameActivity, type AssistantActivity } from "./assistant-activity"

// Keeps each status readable when tools finish in quick succession.
const minimumDisplay = 1200

const toolKeys = {
  read: "session.assistantStatus.read",
  write: "session.assistantStatus.write",
  edit: "session.assistantStatus.edit",
  patch: "session.assistantStatus.patch",
  "file-diff": "session.assistantStatus.fileDiff",
  shell: "session.assistantStatus.shell",
  execute: "session.assistantStatus.execute",
  grep: "session.assistantStatus.grep",
  glob: "session.assistantStatus.glob",
  subagent: "session.assistantStatus.subagent",
  webfetch: "session.assistantStatus.webfetch",
  websearch: "session.assistantStatus.websearch",
  skill: "session.assistantStatus.skill",
  question: "session.assistantStatus.question",
} as const

const genericKeys = [
  "session.assistantStatus.generic.working",
  "session.assistantStatus.generic.processing",
  "session.assistantStatus.generic.preparing",
  "session.assistantStatus.generic.warmingUp",
  "session.assistantStatus.generic.turningGears",
  "session.assistantStatus.generic.computing",
  "session.assistantStatus.generic.calculating",
  "session.assistantStatus.generic.analyzing",
  "session.assistantStatus.generic.spinningWheels",
  "session.assistantStatus.generic.calibrating",
  "session.assistantStatus.generic.synthesizing",
  "session.assistantStatus.generic.connectingDots",
  "session.assistantStatus.generic.inspectingLogic",
  "session.assistantStatus.generic.weighingOptions",
] as const

export function AssistantStatus(props: { activity: AssistantActivity; model?: { providerID: string; name: string } }) {
  const language = useLanguage()
  const [shown, setShown] = createStore({ activity: props.activity, at: Date.now() })
  let timer: ReturnType<typeof setTimeout> | undefined
  onCleanup(() => clearTimeout(timer))
  createEffect(
    on(
      () => props.activity,
      (next) => {
        if (sameActivity(next, shown.activity)) return
        // A generic phrase never replaces a specific status that is already shown.
        if (next.type === "generic") return
        clearTimeout(timer)
        const show = () => setShown({ activity: next, at: Date.now() })
        const wait = minimumDisplay - (Date.now() - shown.at)
        if (wait <= 0) return show()
        timer = setTimeout(show, wait)
      },
      { defer: true },
    ),
  )

  const label = () => {
    const model = props.model?.name
    if (!model) return language.t("session.timeline.working")
    const activity = shown.activity
    if (activity.type === "permission") return language.t("session.assistantStatus.permission", { model })
    if (activity.type === "thinking") return language.t("session.assistantStatus.thinking", { model })
    if (activity.type === "composing") return language.t("session.assistantStatus.composing", { model })
    if (activity.type === "calling")
      return language.t("session.assistantStatus.calling", { model, tool: activity.tool })
    if (activity.type === "generic") return language.t(genericKeys[activity.phrase] ?? genericKeys[0], { model })
    if (Object.hasOwn(toolKeys, activity.tool))
      return language.t(toolKeys[activity.tool as keyof typeof toolKeys], { model })
    return language.t("session.assistantStatus.tool", { model, tool: activity.tool })
  }

  return (
    <div
      data-component="session-working"
      data-activity={shown.activity.type}
      role="status"
      aria-live={shown.activity.type === "permission" ? "assertive" : "polite"}
      class="flex max-w-full shrink-0 items-center gap-1.5"
    >
      <Show when={props.model?.providerID}>
        {(providerID) => (
          <ProviderIcon id={providerID()} class="size-3.5 shrink-0 text-v2-icon-icon-muted" aria-hidden="true" />
        )}
      </Show>
      <TextShimmer text={label()} active class="min-w-0 overflow-hidden" />
    </div>
  )
}
