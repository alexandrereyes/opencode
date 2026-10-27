export function serverConfig(plugin: string) {
  return {
    update: "disable" as const,
    plugins: [plugin],
  }
}
