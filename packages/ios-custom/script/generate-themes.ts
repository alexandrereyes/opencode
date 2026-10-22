import { resolveThemeVariant } from "../../ui-custom/src/theme/resolve"
import { resolveThemeVariantV2 } from "../../ui-custom/src/theme/v2/resolve"
import { hexToOklch, oklchToHex } from "../../ui-custom/src/theme/color"
import type { DesktopTheme, HexColor } from "../../ui-custom/src/theme/types"
import { join } from "node:path"

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
  icon: "icon-base",
  primary: "ios-primary",
  onPrimary: "background-base",
  onInfo: "text-on-info-base",
  success: "ios-success",
  info: "ios-info",
  error: "ios-error",
  warning: "ios-warning",
  accent: "ios-accent",
  filledButton: "button-primary-base",
  onFilledButton: "background-base",
  userBubble: "v2-user-message-background",
  userBubbleText: "v2-user-message-text",
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
      JSON.stringify({ id, name: theme.name, dark: mode === "dark", colors, avatars, roles: resolvedRoles }, null, 2) +
        "\n",
    )
    registry.push({ id, name: theme.name, dark: mode === "dark" })
  }
}
await Bun.write(join(root, "registry.json"), JSON.stringify(registry, null, 2) + "\n")
console.log(`Generated ${registry.length} theme variants`)
