// Local macOS runs use the installed Google Chrome instead of a downloaded Chromium build.
export const channel = process.platform === "darwin" && !process.env.CI ? "chrome" : undefined
