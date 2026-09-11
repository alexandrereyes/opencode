import type {
  SessionInfo,
  WorktreeInspection,
  WorktreeRemoveResult,
} from "@opencode/client/promise"
import { Button } from "@opencode/ui/button"
import { Checkbox } from "@opencode/ui/checkbox"
import { useDialog } from "@opencode/ui/context/dialog"
import { Dialog, DialogBody, DialogFooter, DialogHeader, DialogTitleGroup } from "@opencode/ui/dialog"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Tooltip } from "@opencode/ui/tooltip"
import { onMount, Show } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionLifecycleResult, SessionLifecycleTarget } from "@/session/lifecycle-actions"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection } from "@/runtime/server/registry"
import type { ServerCtx } from "@/runtime/server/runtime"
import { errorMessage } from "@/shell/layout/helpers"
import { showToast } from "@/shell/notifications/toast"
import { useTabs } from "@/shell/tabs/tabs"
import { containsDirectory } from "@/workspaces/paths"

type Target = {
  server: ServerConnection.Key
  ctx: ServerCtx
  projectID: string
  projectDirectory: string
  directory: string
  name: string
}

type Archive = (
  targets: readonly SessionLifecycleTarget[],
  onComplete: (result: SessionLifecycleResult) => void,
) => Promise<SessionLifecycleResult | undefined>

export function useSidebarWorktreeDelete(archive: Archive, lifecyclePending: () => boolean) {
  const dialog = useDialog()
  const language = useLanguage()
  const tabs = useTabs()
  const [state, setState] = createStore({ pending: {} as Record<string, boolean> })

  const sessions = async (
    target: Target,
    cursor?: string,
    previous: readonly SessionInfo[] = [],
  ): Promise<SessionInfo[]> => {
    const page = await target.ctx.sdk.api.session.list(
      cursor ? { cursor } : { project: target.projectID, parentID: null, limit: 100 },
    )
    const all = [...previous, ...page.data]
    if (!page.cursor.next)
      return all.filter(
        (session) => !session.time.archived && containsDirectory(target.directory, session.location.directory),
      )
    return sessions(target, page.cursor.next, all)
  }

  const cleanupErrors = (result: WorktreeRemoveResult) =>
    [result.localBranch, result.remoteBranch]
      .filter((item): item is NonNullable<typeof item> => !!item && !item.deleted)
      .map((item) => item.error ?? language.t("common.requestFailed"))

  const remove = async (
    target: Target,
    inspection: WorktreeInspection,
    options: { local: boolean; remote: boolean; force: boolean },
  ) => {
    if (state.pending[target.directory]) return { completed: false }
    setState("pending", target.directory, true)
    try {
      const linked = await sessions(target)
      const result = await target.ctx.sdk.api.worktree.delete({
        location: { directory: target.projectDirectory },
        directory: target.directory,
        force: options.force,
        identity: inspection.identity,
        branch: inspection.branch ?? null,
        remote: inspection.remoteBranch,
        deleteLocalBranch: options.local,
        deleteRemoteBranch: options.remote,
      })
      target.ctx.sync.worktrees.remove(target.projectDirectory, target.directory)
      await target.ctx.sync.worktrees.refresh(target.projectDirectory)
      tabs.store.forEach((tab) => {
        if (tab.type !== "draft" || tab.server !== target.server) return
        const directoryMatches = containsDirectory(target.directory, tab.directory)
        const worktreeMatches = tab.worktree && containsDirectory(target.directory, tab.worktree)
        if (!directoryMatches && !worktreeMatches) return
        tabs.updateDraft(tab.draftID, {
          directory: directoryMatches ? target.projectDirectory : tab.directory,
          worktree: undefined,
          branch: undefined,
        })
      })
      const archived = linked.length
        ? await archive(
            linked.map((session) => ({ server: target.server, session })),
            () => {},
          )
        : { succeeded: [], failed: [] }
      const errors = [
        ...cleanupErrors(result),
        ...(!archived
          ? [language.t("sidebar.worktree.delete.archiveBusy")]
          : archived.failed.map((item) => item.error)),
      ]
      if (errors.length) {
        showToast({
          variant: "error",
          title: language.t("sidebar.worktree.delete.partial.title"),
          description: [...new Set(errors)].join("\n"),
        })
      } else {
        showToast({ title: language.t("sidebar.worktree.delete.success", { worktree: target.name }) })
      }
      return { completed: true }
    } catch (error) {
      const forceRequired =
        typeof error === "object" &&
        error !== null &&
        "data" in error &&
        typeof error.data === "object" &&
        error.data !== null &&
        "forceRequired" in error.data &&
        error.data.forceRequired === true
      if (forceRequired) return { completed: false, forceRequired: true }
      showToast({
        variant: "error",
        title: language.t("sidebar.worktree.delete.failed.title"),
        description: errorMessage(error, language.t("common.requestFailed")),
      })
      return { completed: false }
    } finally {
      setState("pending", target.directory, false)
    }
  }

  return {
    pending: (directory: string) => state.pending[directory] === true,
    show: (target: Target) => {
      if (state.pending[target.directory] || lifecyclePending()) return
      void dialog.show(() => <WorktreeDeleteDialog target={target} remove={remove} />)
    },
  }
}

function WorktreeDeleteDialog(props: {
  target: Target
  remove: (
    target: Target,
    inspection: WorktreeInspection,
    options: { local: boolean; remote: boolean; force: boolean },
  ) => Promise<{ completed: boolean; forceRequired?: boolean }>
}) {
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({
    pending: true,
    submitting: false,
    forceRequired: false,
    local: false,
    remote: false,
    inspection: undefined as WorktreeInspection | undefined,
    error: undefined as string | undefined,
  })
  onMount(() => {
    void props.target.ctx.sdk.api.worktree
      .inspect({
        location: { directory: props.target.projectDirectory },
        directory: props.target.directory,
      })
      .then((inspection) => setState({ inspection, pending: false }))
      .catch((error) =>
        setState({
          pending: false,
          error: errorMessage(error, language.t("sidebar.worktree.delete.inspectFailed")),
        }),
      )
  })
  const confirm = async () => {
    if (state.pending || state.submitting || !state.inspection) return
    const active = dialog.active
    setState("submitting", true)
    const result = await props.remove(props.target, state.inspection, {
      local: state.local,
      remote: state.remote,
      force: state.inspection.dirty || state.forceRequired,
    })
    setState("submitting", false)
    if (result.forceRequired) {
      setState("forceRequired", true)
      return
    }
    if (result.completed && dialog.active === active) dialog.close()
  }
  const dirty = () => state.inspection?.dirty || state.forceRequired
  return (
    <Dialog fit containerClass="max-w-[calc(100vw-32px)]">
      <DialogHeader hideClose>
        <DialogTitleGroup
          title={language.t("sidebar.worktree.delete.title")}
          description={language.t("sidebar.worktree.delete.confirm", { worktree: props.target.name })}
        />
      </DialogHeader>
      <DialogBody class="flex min-w-0 flex-col gap-4 px-4 pb-2">
        <div data-slot="worktree-delete-details" class="flex min-w-0 flex-col gap-3">
          <div class="flex min-w-0 flex-col gap-1">
            <span class="text-11-regular text-v2-text-text-muted">
              {language.t("sidebar.worktree.delete.branch")}
            </span>
            <span dir="auto" class="min-w-0 break-words text-[13px] leading-4 text-v2-text-text-base">
              {state.inspection?.branch ?? props.target.name}
            </span>
          </div>
          <div class="flex min-w-0 flex-col gap-1">
            <span class="text-11-regular text-v2-text-text-muted">
              {language.t("sidebar.worktree.delete.path")}
            </span>
            <code
              data-slot="worktree-delete-path"
              dir="ltr"
              class="block min-w-0 max-w-full whitespace-normal break-words font-mono text-xs leading-4 text-v2-text-text-base [overflow-wrap:anywhere]"
            >
              {props.target.directory}
            </code>
          </div>
        </div>
        <Show when={state.pending}>
          <p role="status" class="text-[13px] leading-4 text-v2-text-text-muted">
            {language.t("sidebar.worktree.delete.checking")}
          </p>
        </Show>
        <Show when={state.error}>
          {(message) => (
            <p role="alert" class="text-[13px] leading-4 text-v2-state-fg-danger">
              {message()}
            </p>
          )}
        </Show>
        <Show when={dirty()}>
          <p role="alert" class="text-[13px] leading-4 text-v2-state-fg-danger">
            {language.t("sidebar.worktree.delete.dirty")}
          </p>
        </Show>
        <Show when={state.inspection?.localBranch || state.inspection?.remoteBranch}>
          <div
            data-slot="worktree-delete-options"
            class="flex min-w-0 flex-col gap-2 [--checkbox-align:flex-start] [--checkbox-offset:2px] [&_[data-component=checkbox]]:min-w-0 [&_[data-slot=checkbox-checkbox-content]]:min-w-0 [&_[data-slot=checkbox-checkbox-label]]:[overflow-wrap:anywhere]"
          >
            <Show when={state.inspection?.localBranch}>
              {(branch) => (
                <Checkbox checked={state.local} onChange={(checked) => setState("local", checked)}>
                  {language.t("sidebar.worktree.delete.localBranch", { branch: branch().name })}
                </Checkbox>
              )}
            </Show>
            <Show when={state.inspection?.remoteBranch}>
              {(branch) => (
                <Checkbox checked={state.remote} onChange={(checked) => setState("remote", checked)}>
                  {language.t("sidebar.worktree.delete.remoteBranch", {
                    remote: branch().name,
                    branch: branch().branch,
                  })}
                </Checkbox>
              )}
            </Show>
          </div>
        </Show>
      </DialogBody>
      <DialogFooter>
        <Button variant="ghost" disabled={state.submitting} onClick={() => dialog.close()}>
          {language.t("common.cancel")}
        </Button>
        <Button variant="danger" disabled={state.pending || state.submitting || !!state.error} onClick={confirm}>
          {state.submitting
            ? language.t("sidebar.worktree.delete.pending")
            : language.t("sidebar.worktree.delete.button")}
        </Button>
      </DialogFooter>
    </Dialog>
  )
}

export function SidebarWorktreeDelete(props: { target: Target; pending: boolean; onDelete: () => void }) {
  const language = useLanguage()
  return (
    <Tooltip value={language.t("sidebar.worktree.delete.action", { worktree: props.target.name })}>
      <IconButton
        data-action="sidebar-worktree-delete"
        variant="ghost-muted"
        size="small"
        class="hover-reveal shrink-0 group-hover/worktree:opacity-100 group-focus-within/worktree:opacity-100"
        icon={<Icon name="trash" />}
        aria-label={language.t("sidebar.worktree.delete.action", { worktree: props.target.name })}
        disabled={props.pending}
        style={{ color: "var(--v2-state-fg-danger)" }}
        onPointerDown={(event) => event.stopPropagation()}
        onClick={(event) => {
          event.preventDefault()
          event.stopPropagation()
          props.onDelete()
        }}
      />
    </Tooltip>
  )
}
