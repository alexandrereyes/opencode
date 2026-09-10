import { startTransition } from "solid-js"
import { Schema } from "effect"
import type { SessionInfo } from "@opencode/client/promise"
import { useDialog } from "@opencode/ui/context/dialog"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection } from "@/runtime/server/registry"
import { usePlatform } from "@/runtime/platform/platform"
import { useLanguage } from "@/runtime/i18n/language"
import { useTabs } from "@/shell/tabs/tabs"
import type { LocalProject } from "@/shell/state/layout"
import { errorMessage } from "@/shell/layout/helpers"
import { showToast } from "@/shell/notifications/toast"
import { useSshAuthenticate } from "@/servers/ssh/authenticate"

// Shared navigation is deliberately independent of Home's selection and effects.
export function useProjectNavigation() {
  const global = useGlobal()
  const tabs = useTabs()
  return {
    openProjectNewSession(conn: ServerConnection.Any, directory: string) {
      const ctx = global.ensureServerCtx(conn)
      ctx.projects.open(directory)
      ctx.projects.touch(directory)
      return tabs.newDraft({ server: ServerConnection.key(conn), directory })
    },
    openProjectSession(conn: ServerConnection.Any, directory: string, session: SessionInfo) {
      const ctx = global.ensureServerCtx(conn)
      void ctx.data.session.message.sync(session.id).catch(() => undefined)
      void startTransition(() => {
        const tab = tabs.addSessionTab({ server: ServerConnection.key(conn), sessionId: session.id })
        tabs.select(tab)
        ctx.data.session.remember(session)
        ctx.projects.open(directory)
        ctx.projects.touch(directory)
      })
    },
  }
}

export function useProjectActions() {
  const global = useGlobal()
  const platform = usePlatform()
  const language = useLanguage()
  const dialog = useDialog()
  const authenticate = useSshAuthenticate()
  const navigation = useProjectNavigation()
  const failed = (cause: unknown) =>
    showToast({
      title: language.t("common.requestFailed"),
      description: errorMessage(cause, language.t("common.requestFailed")),
    })
  const canReveal = (conn: ServerConnection.Any) =>
    platform.platform === "desktop" && !!platform.openPath && ServerConnection.local(conn)

  return {
    openNewSession(conn: ServerConnection.Any, directory: string) {
      const open = () => void navigation.openProjectNewSession(conn, directory).catch(failed)
      if (authenticate(conn, open)) return
      open()
    },
    get canImportSession() {
      return !!platform.openAttachmentPickerDialog
    },
    importSession(conn: ServerConnection.Any, project: { worktree: string }) {
      if (!platform.openAttachmentPickerDialog) return
      void platform
        .openAttachmentPickerDialog(
          { title: language.t("command.session.import"), accept: ["application/json"], extensions: ["json"] },
          async (file) => {
            const { SessionTransfer } = await import("@opencode/schema/session-transfer")
            const data = await Schema.decodeUnknownPromise(Schema.fromJsonString(SessionTransfer.Data))(
              await file.text(),
            )
            const api = global.ensureServerCtx(conn).sdk.api.session
            const imported = await api.import({
              ...Schema.encodeSync(SessionTransfer.Data)(data),
              location: { directory: project.worktree },
            } as Parameters<typeof api.import>[0])
            navigation.openProjectSession(conn, project.worktree, imported)
          },
        )
        .catch(failed)
    },
    edit(conn: ServerConnection.Any, project: LocalProject) {
      void import("@/settings/workspaces/project-dialog")
        .then(({ DialogEditProject }) => {
          void dialog.show(() => <DialogEditProject server={conn} project={project} />)
        })
        .catch(failed)
    },
    canReveal,
    reveal(conn: ServerConnection.Any, project: { worktree: string }) {
      if (!platform.openPath || !canReveal(conn)) return
      void platform.openPath(project.worktree).catch(failed)
    },
  }
}
