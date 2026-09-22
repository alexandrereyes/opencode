import { exportPerformanceHistory } from "@/runtime/diagnostics/performance"
import { useLanguage } from "@/runtime/i18n/language"
import { usePlatform } from "@/runtime/platform/platform"
import { useCommand, type CommandOption } from "./command"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { DialogSsh } from "@/servers/ssh/dialog"

export function DesktopCommands() {
  const command = useCommand()
  const language = useLanguage()
  const platform = usePlatform()
  const dialog = useDialog()

  command.register("desktop", () => {
    const commands: CommandOption[] = [
      {
        id: "performance.export",
        title: language.t("command.performance.export"),
        category: language.t("command.category.settings"),
        onSelect: () => exportPerformanceHistory(platform.version),
      },
    ]
    if (platform.sshServers)
      commands.push({
        id: "server.ssh.add",
        title: language.t("ssh.add"),
        category: language.t("command.category.server"),
        onSelect: () => void dialog.push(() => <DialogSsh openProject />),
      })
    if (platform.platform !== "desktop" || !platform.exportDebugLogs) return commands
    commands.push({
      id: "logs.export",
      title: language.t("command.logs.export"),
      category: language.t("command.category.settings"),
      onSelect: () => void platform.exportDebugLogs?.(),
    })
    return commands
  })

  return null
}
