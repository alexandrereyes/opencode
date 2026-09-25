import { For, Show } from "solid-js"
import { FileIcon } from "@opencode/ui-custom/file-icon"
import { ScrollView } from "@opencode/ui-custom/scroll-view"
import { getFilename } from "@opencode/util/path"
import type { DirectoryEntry } from "@/workspaces/files/model"
import { useLanguage } from "@/runtime/i18n/language"
import { useArtifactOpener } from "./open-artifact"

export function DirectoryView(props: { path: string; entries: DirectoryEntry[] }) {
  const artifacts = useArtifactOpener()
  const language = useLanguage()
  return (
    <ScrollView class="min-h-0 flex-1">
      <div data-component="directory-view" class="flex flex-col gap-0.5 px-3 py-3">
        <div class="px-1.5 pb-2 text-12-regular text-text-weak break-all">{props.path}</div>
        <Show
          when={props.entries.length > 0}
          fallback={<div class="px-1.5 text-12-regular text-text-weak">{language.t("file.directory.empty")}</div>}
        >
          <For each={props.entries}>
            {(entry) => (
              <button
                type="button"
                class="w-full min-w-0 h-6 flex items-center gap-x-1.5 rounded-md px-1.5 text-start hover:bg-surface-raised-base-hover active:bg-surface-base-active transition-colors cursor-pointer"
                onClick={() => void artifacts.open(entry.path)}
              >
                <FileIcon node={entry} class="size-4 shrink-0" />
                <span class="flex-1 min-w-0 text-12-medium text-text-weak whitespace-nowrap truncate">
                  {getFilename(entry.path)}
                </span>
              </button>
            )}
          </For>
        </Show>
      </div>
    </ScrollView>
  )
}
