import type { useLanguage } from "@/runtime/i18n/language"
import type { SettingsProjectTab, SettingsRootTab, SettingsServerTab, SettingsView } from "./surface"

type Label = Parameters<ReturnType<typeof useLanguage>["t"]>[0]

// Metadata only: search must not mount settings pages or fetch their catalogs.
export type SettingsSearchEntry<Tab> = {
  tab: Tab
  label: Label
  target?: string
  keywords?: string
  description?: Label
  section?: Label
  subtab?: SettingsView["subtab"]
  available?: "desktop" | "browser" | "dev" | "mobile-dev"
}

export const clientSettings: SettingsSearchEntry<SettingsRootTab>[] = [
  { tab: "general", label: "settings.tab.preferences" },
  { tab: "appearance", label: "settings.general.section.appearance" },
  { tab: "notifications", label: "settings.tab.notifications" },
  { tab: "shortcuts", label: "settings.shortcuts.title", keywords: "keybind keyboard hotkey" },
  { tab: "snippets", label: "settings.snippets.title", keywords: "reusable text aliases prompts" },
  { tab: "servers", label: "status.popover.tab.servers" },
  { tab: "projects", label: "settings.tab.projects" },
  { tab: "experimental", label: "settings.tab.experimental" },
  { tab: "about", label: "settings.tab.about", keywords: "version license credits" },
  { tab: "general", label: "settings.general.row.language.title", target: "settings-language" },
  {
    tab: "general",
    label: "command.permissions.autoaccept.enable",
    target: "settings-auto-accept-permissions",
    keywords: "permissions approve allow auto accept",
  },
  {
    tab: "general",
    label: "settings.general.row.shell.title",
    target: "settings-shell",
    description: "settings.general.row.shell.description",
    keywords: "bash zsh powershell",
  },
  {
    tab: "general",
    label: "settings.general.row.terminalPlacement.title",
    target: "settings-terminal-placement",
    keywords: "terminal side bottom position",
  },
  {
    tab: "general",
    label: "settings.general.row.followUpBehavior.title",
    target: "settings-follow-up-behavior",
    keywords: "queue steer follow up",
  },
  {
    tab: "general",
    label: "settings.general.row.pinchZoom.title",
    target: "settings-pinch-zoom",
    available: "desktop",
  },
  {
    tab: "general",
    label: "session.review.wrapLines",
    target: "settings-mobile-diff-wrap",
    keywords: "diff wrap lines",
  },
  {
    tab: "general",
    label: "settings.general.row.mobileTitlebarBottom.title",
    target: "settings-mobile-titlebar-bottom",
    available: "mobile-dev",
  },
  {
    tab: "general",
    label: "settings.timeline.detail",
    target: "settings-timeline-detail",
    section: "settings.timeline.title",
    keywords: "thinking reasoning tools timeline summary detailed",
  },
  {
    tab: "general",
    label: "settings.general.row.releaseNotes.title",
    target: "settings-release-notes",
    section: "settings.general.section.updates",
    available: "desktop",
  },
  {
    tab: "general",
    label: "settings.general.row.showSearch.title",
    target: "settings-show-search",
    section: "settings.general.section.advanced",
    keywords: "command palette title bar",
  },
  {
    tab: "general",
    label: "settings.general.row.showStatus.title",
    target: "settings-show-status",
    section: "settings.general.section.advanced",
    keywords: "server status title bar",
  },
  {
    tab: "general",
    label: "settings.general.row.showCustomAgents.title",
    target: "settings-show-custom-agents",
    section: "settings.general.section.advanced",
  },
  {
    tab: "appearance",
    label: "settings.general.row.colorScheme.title",
    target: "settings-color-scheme",
    keywords: "dark mode light mode system",
  },
  { tab: "appearance", label: "settings.general.row.theme.title", target: "settings-theme" },
  {
    tab: "appearance",
    label: "settings.general.row.uiFont.title",
    target: "settings-ui-font",
    keywords: "interface typeface",
  },
  {
    tab: "appearance",
    label: "settings.general.row.font.title",
    target: "settings-code-font",
    keywords: "code typeface",
  },
  {
    tab: "appearance",
    label: "settings.general.row.terminalFont.title",
    target: "settings-terminal-font",
    keywords: "terminal typeface",
  },
  {
    tab: "notifications",
    label: "settings.general.notifications.agent.title",
    target: "settings-notifications-agent",
    section: "settings.general.section.notifications",
    description: "settings.general.notifications.agent.description",
    keywords: "desktop notifications agent",
  },
  {
    tab: "notifications",
    label: "settings.general.notifications.permissions.title",
    target: "settings-notifications-permissions",
    section: "settings.general.section.notifications",
    description: "settings.general.notifications.permissions.description",
    keywords: "desktop notifications permissions",
  },
  {
    tab: "notifications",
    label: "settings.general.notifications.errors.title",
    target: "settings-notifications-errors",
    section: "settings.general.section.notifications",
    description: "settings.general.notifications.errors.description",
    keywords: "desktop notifications errors",
  },
  {
    tab: "notifications",
    label: "settings.general.sounds.agent.title",
    target: "settings-sounds-agent",
    section: "settings.general.section.sounds",
    description: "settings.general.sounds.agent.description",
    keywords: "sound audio agent",
  },
  {
    tab: "notifications",
    label: "settings.general.sounds.permissions.title",
    target: "settings-sounds-permissions",
    section: "settings.general.section.sounds",
    description: "settings.general.sounds.permissions.description",
    keywords: "sound audio permissions",
  },
  {
    tab: "notifications",
    label: "settings.general.sounds.errors.title",
    target: "settings-sounds-errors",
    section: "settings.general.section.sounds",
    description: "settings.general.sounds.errors.description",
    keywords: "sound audio errors",
  },
  {
    tab: "experimental",
    label: "settings.general.row.browserPane.title",
    target: "settings-experimental-browser",
    available: "browser",
  },
  {
    tab: "experimental",
    label: "settings.appearance.row.tabs.title",
    target: "settings-tab-layout",
    keywords: "vertical horizontal tabs",
  },
  { tab: "experimental", label: "settings.appearance.row.projectName.title", target: "settings-show-project-name" },
  {
    tab: "experimental",
    label: "settings.general.row.showProjectIcon.title",
    target: "settings-show-project-icon",
    available: "dev",
  },
]

export const serverSettings: SettingsSearchEntry<SettingsServerTab>[] = [
  { tab: "projects", label: "settings.tab.projects" },
  { tab: "workspaces", label: "settings.tab.workspaces", keywords: "workspaces disk usage cleanup delete" },
  { tab: "providers", label: "settings.providers.title", keywords: "connect api key credentials" },
  {
    tab: "models",
    label: "settings.models.title",
    keywords: "model picker visibility favorites favourite manual explicit",
  },
  { tab: "extensions", label: "settings.tab.extensions" },
  {
    tab: "extensions",
    subtab: "mcps",
    label: "settings.extensions.tab.mcps",
    keywords: "model context protocol tools",
  },
  { tab: "extensions", subtab: "plugins", label: "status.popover.tab.plugins" },
  { tab: "extensions", subtab: "skills", label: "settings.extensions.tab.skills" },
]

// Project editing remains explicitly saved in its dialog. Only live contextual pages are indexed.
export const projectSettings: SettingsSearchEntry<SettingsProjectTab>[] = [
  { tab: "general", label: "settings.general.section.general" },
  { tab: "workspaces", label: "settings.tab.workspaces", keywords: "workspaces disk usage cleanup delete" },
  { tab: "extensions", label: "settings.tab.extensions" },
  {
    tab: "extensions",
    subtab: "mcps",
    label: "settings.extensions.tab.mcps",
    keywords: "model context protocol tools",
  },
  { tab: "extensions", subtab: "plugins", label: "status.popover.tab.plugins" },
  { tab: "extensions", subtab: "skills", label: "settings.extensions.tab.skills" },
  {
    tab: "extensions",
    subtab: "lsps",
    label: "project.settings.extensions.tab.lsps",
    keywords: "language servers",
  },
]
