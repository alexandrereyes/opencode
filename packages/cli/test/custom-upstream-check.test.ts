import { expect, test } from "bun:test"
import { compare, isCustom, listed } from "../script/custom-upstream-check"

const markdown = (block: string, extra = "") => `# Upstream integrations

## Customizations in upstream code

\`\`\`text
packages/core/src/ignored-before-the-subsection.ts
\`\`\`

### Changed upstream files

Paths below.

\`\`\`text
${block}
\`\`\`
${extra}
## Upstream source branch

### Changed upstream files

\`\`\`text
packages/core/src/ignored-in-another-section.ts
\`\`\`
`

test("custom areas are exactly the fork's own prefixes; everything else is upstream-owned", () => {
  for (const file of [
    "packages/plugin-app-custom/src/sessions/index.ts",
    "packages/ios-custom/OpenCodeKit/Sources/OpenCodeKit/Voice.swift",
    "docs/upstream-integrations.md",
    ".agents/skills/opencode-custom/SKILL.md",
    "packages/cli/script/custom-upstream-check.ts",
    "packages/cli/test/custom-upstream-check.test.ts",
  ])
    expect(isCustom(file)).toBe(true)
  for (const file of [
    "AGENTS.md",
    "package.json",
    "packages/core/src/plugin/host.ts",
    "packages/cli/script/build.ts",
    "packages/cli/test/debug-paths.test.ts",
    "packages/app/docs/notes.md",
    "packages/plugin-app/src/index.ts",
    "services/www/src/docs/content/build/plugins/server.mdx",
  ])
    expect(isCustom(file)).toBe(false)
})

test("the list is the first fenced block of the subsection, without comments or blank lines", () => {
  expect(
    listed(
      markdown("# Group\npackages/core/src/plugin/host.ts\n\n  AGENTS.md  \npatches/@expo%2Fserve-sim@0.10.3.patch"),
    ),
  ).toEqual(["packages/core/src/plugin/host.ts", "AGENTS.md", "patches/@expo%2Fserve-sim@0.10.3.patch"])
  expect(listed(markdown("AGENTS.md", "\n```text\npackages/core/src/later-block.ts\n```\n"))).toEqual(["AGENTS.md"])
})

test("the list rejects globs and fails clearly when its section, subsection or block is missing", () => {
  expect(() => listed(markdown("packages/plugin/src/{job,mcp}.ts"))).toThrow("exact paths")
  expect(() => listed(markdown("packages/plugin/src/*.ts"))).toThrow("exact paths")
  expect(() => listed(markdown("packages/core/src/a.ts packages/core/src/b.ts"))).toThrow("exact paths")
  expect(() => listed("# Upstream integrations\n")).toThrow('no "## Customizations in upstream code" section')
  expect(() => listed("## Customizations in upstream code\n\nText.\n\n## Next\n")).toThrow(
    'no "### Changed upstream files" subsection',
  )
  expect(() => listed("## Customizations in upstream code\n\n### Changed upstream files\n\nNo block.\n")).toThrow(
    "no fenced block",
  )
})

test("comparison reports undocumented upstream files, stale and duplicated entries, and ignores custom areas", () => {
  expect(
    compare(
      ["AGENTS.md", "docs/custom-master-session.md", "packages/core/src/session.ts", "packages/core/src/new.ts"],
      [
        "AGENTS.md",
        "packages/core/src/session.ts",
        "packages/core/src/reverted.ts",
        "docs/custom-master-session.md",
        "AGENTS.md",
      ],
    ),
  ).toEqual({
    upstream: ["AGENTS.md", "packages/core/src/session.ts", "packages/core/src/new.ts"],
    undocumented: ["packages/core/src/new.ts"],
    stale: ["packages/core/src/reverted.ts", "docs/custom-master-session.md"],
    duplicated: ["AGENTS.md"],
  })
  expect(compare(["packages/ios-custom/README.md"], [])).toEqual({
    upstream: [],
    undocumented: [],
    stale: [],
    duplicated: [],
  })
})
