import { useDialog } from "@opencode/ui-custom/context/dialog"
import { ServerConnection } from "@/runtime/server/registry"
import { usePlatform } from "@/runtime/platform/platform"
import { type Component, lazy } from "solid-js"
import type { LocationRef } from "@opencode/client/promise"
import { directoryPickerKind } from "./policy"

const DirectoryPickerDialog = lazy(() =>
  import("./dialog").then((module) => ({ default: module.DirectoryPickerDialog })),
)
const ProjectExplorerDialog = lazy(() =>
  import("./explorer").then((module) => ({ default: module.ProjectExplorerDialog })),
)

type DirectoryPickerInput = {
  server: ServerConnection.Any
  location?: LocationRef
  title?: string
  multiple?: boolean
  onSelect: (result: string | string[] | null) => void
}

export function useDirectoryPicker() {
  return usePicker(DirectoryPickerDialog)
}

export function useProjectPicker() {
  return usePicker(ProjectExplorerDialog)
}

function usePicker(View: Component<DirectoryPickerInput>) {
  const platform = usePlatform()
  const dialog = useDialog()

  return (input: DirectoryPickerInput) => {
    if (directoryPickerKind(platform.platform, input.server) === "native" && platform.platform === "desktop") {
      void platform.openDirectoryPickerDialog({ title: input.title, multiple: input.multiple }).then(input.onSelect)
      return
    }

    let selected = false
    const onSelect = (result: string | string[] | null) => {
      selected = result !== null
      input.onSelect(result)
    }
    const cancel = () => {
      if (!selected) input.onSelect(null)
    }
    dialog.show(() => <View {...input} onSelect={onSelect} />, cancel)
  }
}
