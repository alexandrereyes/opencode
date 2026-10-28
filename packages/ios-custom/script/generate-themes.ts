import { resolveThemeVariant } from "../../ui-custom/src/theme/resolve"
import { resolveThemeVariantV2 } from "../../ui-custom/src/theme/v2/resolve"
import { hexToOklch, oklchToHex } from "../../ui-custom/src/theme/color"
import type { DesktopTheme, HexColor } from "../../ui-custom/src/theme/types"
import { join } from "node:path"
import { composite, legible, luminance, mix } from "./theme-contrast"

const root = join(import.meta.dir, "../OpenCode/Resources/Themes")
// Alpha primitives live in CSS rather than the web resolver's returned ramp map.
const alphaTokens = Object.fromEntries(
  [
    ...(await Bun.file(join(import.meta.dir, "../../ui-custom/src/styles/tokens/colors.css")).text()).matchAll(
      /--(v2-alpha-[\w-]+):\s*(#[\da-f]{8});/gi,
    ),
  ].map((match) => [match[1]!, match[2]!]),
)
const roles = {
  background: "background-base",
  surface: "surface-base",
  surfaceRaised: "background-weak",
  highlight: "surface-base-hover",
  border: "border-weak-base",
  borderStrong: "v2-border-border-strong",
  controlBorder: "border-strong-base",
  textStrong: "text-strong",
  text: "text-base",
  textSecondary: "text-weak",
  textWeak: "text-weaker",
  textMuted: "text-weaker",
  textPreview: "text-base",
  textAccent: "ios-primary",
  glassSecondary: "text-weak",
  icon: "icon-base",
  primary: "ios-primary",
  onPrimary: "background-base",
  onInfo: "text-on-info-base",
  infoFill: "ios-info",
  success: "ios-success",
  info: "ios-info",
  error: "ios-error",
  warning: "ios-warning",
  accent: "ios-accent",
  filledButton: "button-primary-base",
  onFilledButton: "background-base",
  userBubble: "v2-user-message-background",
  userBubbleText: "v2-user-message-text",
  userBubbleSecondary: "text-weak",
  // A steer waiting behind delivered work drops the sent-message accent, like the web's `data-pending` bubble.
  userBubblePending: "v2-background-bg-layer-02",
  userBubblePendingText: "v2-text-text-base",
  userBubblePendingSecondary: "text-weak",
  inlineCode: "v2-inline-code-text",
  inlineCodeBackground: "v2-inline-code-background",
  codeSurface: "background-stronger",
  toolSurface: "v2-background-bg-layer-02",
  diffAdd: "icon-diff-add-base",
  diffDelete: "icon-diff-delete-base",
  contextTrack: "border-weak-base",
  contextFill: "text-weak",
  contextWarning: "ios-warning",
  agentBuild: "v2-agent-build-solid",
  agentExplore: "v2-agent-explore-solid",
  agentPlan: "v2-agent-plan-solid",
  agentReview: "v2-agent-review-solid",
  agentWriter: "v2-agent-writer-solid",
  agentExplicit: "v2-icon-icon-base",
  agentPrimary: "v2-text-text-accent",
  agentSecondary: "v2-text-text-muted",
  agentAccent: "v2-icon-icon-accent",
  agentError: "v2-state-fg-danger",
  agentStateSuccess: "v2-state-fg-success",
  agentStateWarning: "v2-state-fg-warning",
  agentStateInfo: "v2-state-fg-info",
  agentAsk: "icon-agent-ask-base",
  agentLegacyBuild: "icon-agent-build-base",
  agentDocs: "icon-agent-docs-base",
  agentLegacyPlan: "icon-agent-plan-base",
  agentInfo: "syntax-info",
  agentSuccess: "syntax-success",
  agentWarning: "syntax-warning",
  agentProperty: "syntax-property",
  agentConstant: "syntax-constant",
  agentAdded: "text-diff-add-base",
  agentDeleted: "text-diff-delete-base",
  agentLegacyWarning: "icon-warning-base",
  composerFile: "syntax-property",
  composerAgent: "syntax-type",
  composerSession: "v2-text-text-accent",
  composerSnippet: "v2-text-text-accent",
  composerCommand: "ios-info",
  composerSkill: "ios-accent",
  markdownBody: "markdown-text",
  markdownStrong: "text-strong",
  markdownHeading: "text-strong",
  markdownQuote: "markdown-block-quote",
  markdownQuoteBorder: "markdown-horizontal-rule",
  markdownLink: "markdown-link",
  markdownRule: "border-base",
  markdownTask: "ios-primary",
  codeText: "markdown-code-block",
  codeHeaderText: "text-base",
  codeBorder: "border-base",
  codeHeaderSeparator: "border-base",
  codeGutterSeparator: "border-base",
  codeLineNumber: "text-weak",
  tableSurface: "background-stronger",
  tableText: "markdown-text",
  tableHeaderText: "text-base",
  tableBorder: "border-base",
  tableSeparator: "border-base",
  syntaxKeyword: "syntax-keyword",
  syntaxString: "syntax-string",
  syntaxComment: "syntax-comment",
  syntaxFunction: "syntax-primitive",
  syntaxProperty: "syntax-property",
  syntaxType: "syntax-type",
  syntaxConstant: "syntax-constant",
  syntaxNumber: "syntax-constant",
  syntaxVariable: "syntax-variable",
  syntaxPunctuation: "syntax-punctuation",
  syntaxOperator: "syntax-operator",
  syntaxAdded: "text-diff-add-base",
  syntaxRemoved: "text-diff-delete-base",
  diagramBackground: "background-stronger",
  diagramText: "markdown-text",
  diagramLine: "text-weak",
  diagramAccent: "ios-primary",
  diagramMuted: "text-weak",
  diagramSurface: "surface-base",
  diagramBorder: "border-base",
  quoteHighlight: "v2-border-border-focus",
  quoteUnderline: "v2-border-border-focus",
  quoteBadge: "v2-border-border-focus",
  quoteBadgeSurface: "v2-background-bg-layer-01",
  chatAvatar: "ios-accent",
  chatAvatarSymbol: "text-strong",
} as const

const themes = new Bun.Glob("*.json")
const registry: { id: string; name: string; dark: boolean }[] = []
for await (const file of themes.scan(join(import.meta.dir, "../../ui-custom/src/theme/themes"))) {
  const theme: DesktopTheme = await Bun.file(join(import.meta.dir, "../../ui-custom/src/theme/themes", file)).json()
  for (const mode of ["dark", "light"] as const) {
    const variant = theme[mode]
    const palette = variant.palette ?? variant.seeds!
    const tokens = {
      ...alphaTokens,
      ...resolveThemeVariant(
        {
          ...variant,
          overrides: {
            ...variant.overrides,
            "ios-primary": palette.primary,
            "ios-success": palette.success,
            "ios-info": palette.info,
            "ios-error": palette.error,
            "ios-warning": palette.warning,
            "ios-accent": "accent" in palette ? (palette.accent ?? palette.info) : palette.info,
          },
        },
        mode === "dark",
      ),
      ...resolveThemeVariantV2(variant, mode === "dark"),
    }
    const resolve = (key: string): string => {
      const value = tokens[key]
      if (!value) throw new Error(`Missing theme token ${key}`)
      const reference = /^var\(--([^,)]+)\)$/.exec(value)
      return reference ? resolve(reference[1]!) : value
    }
    const resolvedRoles = {
      ...roles,
      userBubble: tokens[roles.userBubble] ? roles.userBubble : "v2-background-bg-accent",
      userBubbleText: tokens[roles.userBubbleText] ? roles.userBubbleText : "text-base",
      inlineCode: tokens[roles.inlineCode] ? roles.inlineCode : "syntax-string",
      inlineCodeBackground: tokens[roles.inlineCodeBackground]
        ? roles.inlineCodeBackground
        : "v2-background-bg-layer-02",
      highlight: mode === "dark" ? "v2-background-bg-layer-02" : roles.highlight,
      onInfo: mode === "light" ? "text-on-info-strong" : roles.onInfo,
    }
    const colors = Object.fromEntries(Object.entries(resolvedRoles).map(([role, token]) => [role, resolve(token)]))
    const surfaces = ["background", "surface", "surfaceRaised", "toolSurface", "codeSurface", "tableSurface"].map((role) =>
      composite(colors[role]!, colors.background!),
    )
    const readable = (color: string, minimum = 4.5) => legible(color, surfaces, minimum, mode === "dark")
    colors.textStrong = readable(colors.textStrong!)
    colors.text = readable(colors.text!)
    colors.textSecondary = readable(mix(colors.textSecondary!, colors.text!, 0.2), 5.5)
    colors.textMuted = readable(colors.textWeak!)
    colors.textPreview = readable(mix(colors.text!, colors.textStrong!, 0.15))
    colors.textAccent = readable(colors.primary!)
    colors.glassSecondary = legible(colors.textSecondary!, [
      ...surfaces, mix(colors.background!, colors.textStrong!, mode === "dark" ? 0.35 : 0.2),
    ], 4.5, mode === "dark")
    colors.markdownBody = mix(colors.markdownBody!, colors.textStrong!, 0.4)
    for (const role of ["success", "info", "error"] as const) {
      colors[role] = readable(mode === "dark" ? mix(colors[role]!, colors.textStrong!, 0.12) : colors[role]!)
    }
    for (const role of ["markdownBody", "markdownStrong", "markdownHeading", "markdownQuote", "markdownLink",
      "inlineCode", "codeText", "codeHeaderText", "codeLineNumber", "tableText", "tableHeaderText", "syntaxComment", "quoteBadge"] as const) {
      colors[role] = readable(colors[role]!)
    }
    for (const role of Object.keys(roles).filter((role) => role.startsWith("syntax") || role.startsWith("composer"))) {
      colors[role] = readable(colors[role]!)
    }
    colors.diffAdd = readable(colors.diffAdd!)
    colors.diffDelete = readable(colors.diffDelete!)
    const bubble = composite(colors.userBubble!, colors.background!)
    colors.userBubbleText = legible(colors.userBubbleText!, [bubble], 4.5, luminance(bubble) < 0.18)
    colors.userBubbleSecondary = legible(colors.textSecondary!, [bubble], 4.5, luminance(bubble) < 0.18)
    const pending = composite(colors.userBubblePending!, colors.background!)
    colors.userBubblePendingText = legible(colors.userBubblePendingText!, [pending], 4.5, luminance(pending) < 0.18)
    colors.userBubblePendingSecondary = legible(colors.textSecondary!, [pending], 4.5, luminance(pending) < 0.18)
    // A separate fill keeps information text legible in light themes without making its button dark.
    const infoHue = hexToOklch(colors.infoFill! as HexColor)
    colors.onInfo = oklchToHex({ ...infoHue, l: 0.14, c: Math.min(infoHue.c, 0.025) })
    colors.infoFill = legible(colors.infoFill!, [colors.onInfo], 4.5, true)
    colors.onPrimary = legible(colors.onPrimary!, [colors.primary!], 4.5, luminance(colors.primary!) < 0.18)
    colors.onFilledButton = legible(colors.onFilledButton!, [colors.filledButton!], 4.5, luminance(colors.filledButton!) < 0.18)
    // Chats beside repository sessions share one avatar: the theme's accent hue at the project avatars' lightness,
    // more saturated than their muted colors so it reads as a category, with a symbol legible on it.
    const accent = hexToOklch(colors.accent! as HexColor)
    colors.chatAvatar = oklchToHex({ ...accent, l: mode === "dark" ? 0.46 : 0.81, c: Math.min(accent.c, 0.1) })
    colors.chatAvatarSymbol = legible(colors.chatAvatarSymbol!, [colors.chatAvatar], 4.5, mode === "dark")
    colors.border = legible(colors.border!, [colors.background!], 1.4, mode === "dark")
    colors.controlBorder = legible(colors.controlBorder!, surfaces, 1.7, mode === "dark")
    const exportedRoles: Record<string, string> = { ...resolvedRoles }
    for (const role of [...Object.keys(roles).filter((role) => role.startsWith("syntax") || role.startsWith("composer")), "diffAdd", "diffDelete"]) {
      exportedRoles[role] = `ios-derived-${role}`
    }
    for (const role of ["textStrong", "text", "textSecondary", "textMuted", "textPreview", "textAccent", "glassSecondary", "success", "info", "error",
      "markdownBody", "markdownStrong", "markdownHeading", "markdownQuote", "markdownLink", "inlineCode", "codeText",
      "codeHeaderText", "codeLineNumber", "tableText", "tableHeaderText", "syntaxComment", "userBubbleText", "userBubbleSecondary",
      "userBubblePendingText", "userBubblePendingSecondary", "infoFill", "onInfo", "onPrimary", "onFilledButton", "border", "controlBorder", "quoteBadge", "chatAvatar", "chatAvatarSymbol"]) {
      exportedRoles[role] = `ios-derived-${role}`
    }
    for (const [role, value] of Object.entries(colors)) {
      if (!/^#[\da-f]{6}([\da-f]{2})?$/i.test(value))
        throw new Error(`${theme.id}/${mode}/${role}: unsupported color ${value}`)
    }
    const avatars = Object.fromEntries(
      ["lime", "orange", "purple", "cyan", "pink", "mint"].map((color) => {
        const hue = hexToOklch(resolve(`avatar-text-${color}`) as HexColor)
        // Equal perceptual lightness/chroma prevents the pale-avatar disparity in the light mockup.
        return [
          color,
          { background: oklchToHex({ ...hue, l: mode === "dark" ? 0.46 : 0.81, c: 0.055 }), text: colors.textStrong },
        ]
      }),
    )
    const id = `${theme.id}-${mode}`
    await Bun.write(
      join(root, `${id}.json`),
      JSON.stringify({ id, name: theme.name, dark: mode === "dark", colors, avatars, roles: exportedRoles }, null, 2) +
        "\n",
    )
    registry.push({ id, name: theme.name, dark: mode === "dark" })
  }
}
await Bun.write(join(root, "registry.json"), JSON.stringify(registry, null, 2) + "\n")
console.log(`Generated ${registry.length} theme variants`)
