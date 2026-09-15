import type { LocationGetOutput } from "@opencode/client/promise"
import type { LocalProject } from "@/shell/state/layout"
import type { Project } from "./types"
import { sameDirectory } from "@/workspaces/paths"

export function resolveProjectMetadata(
  project: Pick<LocalProject, "id" | "worktree">,
  projectID: string | undefined,
  location: LocationGetOutput | undefined,
  projects: readonly Project[],
) {
  const id = location?.project.id ?? projectID
  if (id) return projects.find((item) => item.id === id)
  const direct = projects.filter((item) => sameDirectory(item.worktree, project.worktree))
  return direct.length === 1 ? direct[0] : undefined
}
