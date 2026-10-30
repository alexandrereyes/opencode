// Fails when an upstream-owned file differs from the integrated upstream baseline without being listed in
// docs/upstream-integrations.md ("Customizations in upstream code" → "Changed upstream files").
import path from "node:path"

/**
 * The fork's own areas: nothing below them exists upstream, so they never need an entry. A file whose path starts
 * with one of these prefixes is custom; every other path in the repository is upstream-owned.
 */
export const customAreas = [
  "packages/plugin-app-custom/",
  "packages/ios-custom/",
  "docs/",
  ".agents/",
  "packages/cli/script/custom-",
  "packages/cli/test/custom-",
]

export const document = "docs/upstream-integrations.md"
const section = "## Customizations in upstream code"
const heading = "### Changed upstream files"

export function isCustom(file: string) {
  return customAreas.some((area) => file.startsWith(area))
}

/** One exact path per line in the first fenced block under the heading; blank lines and `#` lines are comments. */
export function listed(markdown: string) {
  const lines = markdown.split("\n")
  const start = lines.indexOf(section)
  if (start < 0) throw new Error(`${document} has no "${section}" section`)
  const end = lines.findIndex((line, index) => index > start && line.startsWith("## "))
  const body = lines.slice(start + 1, end < 0 ? undefined : end)
  const at = body.indexOf(heading)
  if (at < 0) throw new Error(`"${section}" in ${document} has no "${heading}" subsection`)
  const open = body.findIndex((line, index) => index > at && line.startsWith("```"))
  const close = body.findIndex((line, index) => index > open && line.startsWith("```"))
  if (open < 0 || close < 0) throw new Error(`"${heading}" in ${document} has no fenced block of paths`)
  const paths = body
    .slice(open + 1, close)
    .map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("#"))
  const patterns = paths.filter((line) => /[\s*?{}[\]]/.test(line))
  if (patterns.length > 0)
    throw new Error(`"${heading}" must list exact paths, one per line; not: ${patterns.join(", ")}`)
  return paths
}

/** Upstream-owned changes missing from the list, and list entries that are not (or no longer) such a change. */
export function compare(changed: readonly string[], paths: readonly string[]) {
  const upstream = changed.filter((file) => !isCustom(file))
  const documented = new Set(paths)
  const owned = new Set(upstream)
  return {
    upstream,
    undocumented: upstream.filter((file) => !documented.has(file)),
    stale: [...documented].filter((file) => !owned.has(file)),
    duplicated: paths.filter((file, index) => paths.indexOf(file) !== index),
  }
}

async function main() {
  const root = path.resolve(import.meta.dir, "../../..")
  const git = async (...args: string[]) => {
    const result = await Bun.$`git ${args}`.cwd(root).quiet().nothrow()
    if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString().trim()}`)
    return result.text()
  }
  const override = process.argv.indexOf("--base")
  if (override >= 0 && !process.argv[override + 1]) throw new Error("--base needs a revision")
  if (override < 0 && !(await git("branch", "--remotes", "--list", "upstream/dev")).trim())
    throw new Error("upstream/dev is missing: run `git fetch upstream dev`, or pass --base <sha>")
  const base = (
    override >= 0
      ? await git("rev-parse", "--verify", `${process.argv[override + 1]}^{commit}`).catch(() => {
          throw new Error(`--base ${process.argv[override + 1]} is not a commit`)
        })
      : await git("merge-base", "HEAD", "upstream/dev")
  ).trim()

  // Committed changes, then uncommitted and untracked ones, so a check before committing sees them too.
  const pairs = (output: string) =>
    output
      .split("\0")
      .slice(0, -1)
      .flatMap((value, index, values) => (index % 2 === 0 ? [[values[index + 1] ?? "", value] as const] : []))
  const statuses = new Map([
    ...pairs(await git("diff", "--name-status", "--no-renames", "-z", base, "HEAD")),
    ...pairs(await git("diff", "--name-status", "--no-renames", "-z", "HEAD")),
    ...(await git("ls-files", "--others", "--exclude-standard", "-z"))
      .split("\0")
      .filter(Boolean)
      .map((file) => [file, "?"] as const),
  ])

  const result = compare([...statuses.keys()].toSorted(), listed(await Bun.file(path.join(root, document)).text()))
  console.log(`Upstream baseline: ${base.slice(0, 10)}${override >= 0 ? "" : " (merge-base of HEAD and upstream/dev)"}`)
  console.log(`Upstream-owned files changed: ${result.upstream.length}`)
  const problems = [
    {
      title: `Undocumented changes to upstream-owned files; list each under "${heading}" in ${document}, with its reason and exit condition in the section`,
      files: result.undocumented.map((file) => `${statuses.get(file)} ${file}`),
    },
    {
      title: `Listed under "${heading}" but not changed against the baseline, or in a custom area; remove them`,
      files: result.stale,
    },
    { title: `Listed more than once under "${heading}"`, files: result.duplicated },
  ].filter((problem) => problem.files.length > 0)
  if (problems.length === 0) return console.log(`Every one of them is listed in ${document}.`)
  for (const problem of problems)
    console.error(`\n${problem.title}:\n${problem.files.map((file) => `  ${file}`).join("\n")}`)
  process.exitCode = 1
}

if (import.meta.main)
  await main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  })
