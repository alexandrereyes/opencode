export function serverConfig(plugin: string) {
  return {
    update: "disable" as const,
    plugins: [plugin],
    mcp: {
      servers: {
        "safari-devtools": {
          type: "local" as const,
          command: ["/usr/bin/safaridriver", "--mcp"],
        },
      },
    },
  }
}
