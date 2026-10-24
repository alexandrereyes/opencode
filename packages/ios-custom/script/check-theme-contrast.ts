import { join } from "node:path"
import { composite, contrast, mix } from "./theme-contrast"

const root = join(import.meta.dir, "../OpenCode/Resources/Themes")
const results = []
for await (const file of new Bun.Glob("*-*.json").scan(root)) {
  const theme = await Bun.file(join(root, file)).json() as { id: string; dark: boolean; colors: Record<string, string> }
  const colors = theme.colors
  const surfaces = ["background", "surface", "surfaceRaised", "toolSurface", "codeSurface", "tableSurface"].map((role) =>
    composite(colors[role]!, colors.background!),
  )
  const ratios = Object.fromEntries([
    ...["text", "textStrong", "textSecondary", "textMuted", "textPreview", "textAccent", "markdownBody",
      "markdownStrong", "markdownHeading", "markdownQuote", "markdownLink", "inlineCode", "codeText", "codeHeaderText",
       "codeLineNumber", "tableText", "tableHeaderText", "syntaxComment", "success", "info", "error", "quoteBadge"].map((role) =>
      [role, Math.min(...surfaces.map((surface) => contrast(colors[role]!, surface)))],
    ),
    ...Object.keys(colors).filter((role) => role.startsWith("syntax") || role.startsWith("composer") || role === "diffAdd" || role === "diffDelete")
      .map((role) => [role, Math.min(...surfaces.map((surface) => contrast(colors[role]!, surface)))]),
    ["userBubbleText", contrast(colors.userBubbleText!, composite(colors.userBubble!, colors.background!))],
    ["userBubbleSecondary", contrast(colors.userBubbleSecondary!, composite(colors.userBubble!, colors.background!))],
    ["userBubblePendingText", contrast(colors.userBubblePendingText!, composite(colors.userBubblePending!, colors.background!))],
    ["userBubblePendingSecondary", contrast(colors.userBubblePendingSecondary!, composite(colors.userBubblePending!, colors.background!))],
    ["onInfo", contrast(colors.onInfo!, colors.infoFill!)],
    ["onPrimary", contrast(colors.onPrimary!, colors.primary!)],
    ["onFilledButton", contrast(colors.onFilledButton!, colors.filledButton!)],
    ["glassSecondary", contrast(colors.glassSecondary!, mix(colors.background!, colors.textStrong!, theme.dark ? 0.35 : 0.2))],
  ])
  results.push({ id: theme.id, ratios })
}
const failures = results.flatMap((theme) => Object.entries(theme.ratios)
  .filter(([, ratio]) => ratio < 4.5).map(([role, ratio]) => `${theme.id}/${role}: ${ratio.toFixed(2)}`))
console.log(JSON.stringify({ variants: results.length, failures, themes: results }, null, 2))
if (failures.length) process.exitCode = 1
