import { defineConfig } from "@playwright/test"
import { fileURLToPath } from "node:url"
import { componentConfig } from "../storybook/playwright/config"
import { channel } from "./playwright.channel"

export default defineConfig(componentConfig(fileURLToPath(new URL(".", import.meta.url))), { use: { channel } })
