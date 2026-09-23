import { createEffect, createMemo, For, Match, on, onCleanup, Show, Switch, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui-custom/button"
import { Markdown } from "@opencode/session-ui-custom/markdown"
import { MarkdownProvider, useMarkdown } from "@opencode/session-ui-custom/context/markdown"
import { getDirectory, getFilename } from "@opencode/util/path"
import { useLanguage } from "@/runtime/i18n/language"
import type { FileContent } from "@/runtime/server/types"
import { artifactKind, blobUrlFromContent, parseDelimited } from "@/workspaces/files/artifact"
import { useArtifactOpener } from "./open-artifact"
import "./artifact-view.css"

export function ArtifactView(props: { path: string; content: FileContent; source: JSX.Element }) {
  const language = useLanguage()
  const [state, setState] = createStore({ source: false, failed: false, zoom: false })
  createEffect(
    on(
      () => props.content,
      () => setState({ source: false, failed: false, zoom: false }),
    ),
  )
  const kind = createMemo(() => artifactKind(props.path))
  const previewable = () => ["svg", "html", "markdown", "mermaid", "table"].includes(kind())
  const binary = () => state.failed || (props.content.type === "binary" && !props.content.mimeType)
  const url = createMemo(() => {
    const value = blobUrlFromContent(props.content)
    onCleanup(() => URL.revokeObjectURL(value))
    return value
  })
  return (
    <div data-component="artifact-view">
      <div data-slot="artifact-toolbar">
        <Show when={previewable()}>
          <Button
            size="small"
            variant={state.source ? "ghost" : "neutral"}
            aria-pressed={!state.source}
            onClick={() => setState("source", false)}
          >
            {language.t("file.view.preview")}
          </Button>
          <Button
            size="small"
            variant={state.source ? "neutral" : "ghost"}
            aria-pressed={state.source}
            onClick={() => setState("source", true)}
          >
            {language.t("file.view.source")}
          </Button>
        </Show>
        <Show when={!binary()}>
          <a class="ms-auto text-13-regular" href={url()} download={getFilename(props.path)}>
            {language.t("file.view.download")}
          </a>
        </Show>
      </div>
      <Show when={!state.source} fallback={props.source}>
        <Switch>
          <Match when={binary()}>
            <div data-slot="artifact-empty">{language.t("file.view.binary")}</div>
          </Match>
          <Match when={kind() === "image" || kind() === "svg"}>
            <div data-slot="artifact-media" data-zoom={state.zoom}>
              <button
                aria-label={language.t("file.view.zoom")}
                aria-pressed={state.zoom}
                onClick={() => setState("zoom", !state.zoom)}
              >
                <img src={url()} alt={getFilename(props.path)} onError={() => setState("failed", true)} />
              </button>
            </div>
          </Match>
          <Match when={kind() === "audio"}>
            <div data-slot="artifact-media">
              <audio controls src={url()} onError={() => setState("failed", true)} />
            </div>
          </Match>
          <Match when={kind() === "video"}>
            <div data-slot="artifact-media">
              <video controls playsinline preload="metadata" src={url()} onError={() => setState("failed", true)} />
            </div>
          </Match>
          <Match when={kind() === "pdf" || kind() === "html"}>
            <iframe
              title={getFilename(props.path)}
              src={url()}
              sandbox={kind() === "html" ? "allow-scripts allow-popups allow-forms allow-modals" : undefined}
              referrerPolicy="no-referrer"
            />
          </Match>
          <Match when={kind() === "markdown"}>
            <ArtifactMarkdown path={props.path} text={props.content.content} />
          </Match>
          <Match when={kind() === "mermaid"}>
            <div data-slot="artifact-document">
              <Markdown text={`\`\`\`mermaid\n${props.content.content}\n\`\`\``} />
            </div>
          </Match>
          <Match when={kind() === "table"}>
            <ArtifactTable path={props.path} text={props.content.content} />
          </Match>
          <Match when={kind() === "font"}>
            <ArtifactFont url={url()} onError={() => setState("failed", true)} />
          </Match>
        </Switch>
      </Show>
    </div>
  )
}

function ArtifactMarkdown(props: { path: string; text: string }) {
  const parent = useMarkdown()
  const artifacts = useArtifactOpener()
  const dir = () => (props.path.includes("/") || props.path.includes("\\") ? getDirectory(props.path) : "")
  return (
    <MarkdownProvider
      readImage={(src, signal) =>
        parent?.readImage?.(artifacts.resolve(src, dir()), signal) ?? Promise.resolve(undefined)
      }
      openLocalFile={(href) => void artifacts.open(href, dir())}
    >
      <div data-slot="artifact-document">
        <Markdown text={props.text} />
      </div>
    </MarkdownProvider>
  )
}

function ArtifactTable(props: { path: string; text: string }) {
  const language = useLanguage()
  const parsed = createMemo(() => parseDelimited(props.text, props.path.toLowerCase().endsWith(".tsv") ? "\t" : ","))
  const header = () => Array.from({ length: parsed().columns }, (_, index) => parsed().rows[0]?.[index] ?? "")
  return (
    <div data-slot="artifact-document">
      <table>
        <thead>
          <tr>
            <For each={header()}>{(cell) => <th>{cell}</th>}</For>
          </tr>
        </thead>
        <tbody>
          <For each={parsed().rows.slice(1)}>
            {(row) => (
              <tr>
                <For each={header()}>{(_, column) => <td>{row[column()] ?? ""}</td>}</For>
              </tr>
            )}
          </For>
        </tbody>
      </table>
      <Show when={parsed().total > parsed().rows.length}>
        <p>{language.t("file.view.table.truncated", { shown: parsed().rows.length - 1, total: parsed().total - 1 })}</p>
      </Show>
    </div>
  )
}

function ArtifactFont(props: { url: string; onError: () => void }) {
  const language = useLanguage()
  const family = `artifact-${Math.random().toString(36).slice(2)}`
  createEffect(() => {
    const face = new FontFace(family, `url(${props.url})`)
    document.fonts.add(face)
    void face.load().catch(props.onError)
    onCleanup(() => document.fonts.delete(face))
  })
  return (
    <div data-slot="artifact-document" style={{ "font-family": family }}>
      <For each={[12, 16, 24, 40, 64]}>
        {(size) => (
          <p style={{ "font-size": `${size}px`, "overflow-wrap": "anywhere" }}>{language.t("file.view.fontSample")}</p>
        )}
      </For>
    </div>
  )
}
