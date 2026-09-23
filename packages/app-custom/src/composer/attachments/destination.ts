import type { Accessor } from "solid-js"
import { useServer } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { authTokenFromCredentials } from "@/runtime/server/api"
import { useWorkspaceLocation } from "@/workspaces/location"
import type { ComposerControls } from "../adapter"

export type AttachmentDestination = {
  input: { image: boolean; pdf: boolean }
  local: boolean
  upload: (file: File, report: (loaded: number) => void, signal: AbortSignal) => Promise<string>
}

export function useAttachmentDestination(controls: Accessor<ComposerControls>) {
  const server = useServer()
  const sdk = useServerSDK()
  const location = useWorkspaceLocation()
  return (): AttachmentDestination => ({
    input: controls().model.selection.current()?.capabilities.input ?? { image: false, pdf: false },
    local: server.isLocal,
    upload: async (file, report, signal) => {
      const info = await sdk.api.server.info({ signal })
      const url = new URL("/api/experimental/fs/write", server.conn.http.url)
      url.searchParams.set("location[directory]", location().directory)
      url.searchParams.set("path", `${info.paths.tmp}/uploads/${crypto.randomUUID()}/${file.name}`)
      return writeAttachment(url, file, server.conn.http.password, report, signal)
    },
  })
}

// XHR sends the File directly and exposes progress on HTTP/1 as well as HTTP/2.
export function writeAttachment(
  url: URL,
  file: File,
  password: string | undefined,
  report: (loaded: number) => void,
  signal: AbortSignal,
) {
  return new Promise<string>((resolve, reject) => {
    if (signal.aborted) return reject(new DOMException("Upload aborted", "AbortError"))
    const xhr = new XMLHttpRequest()
    const abort = () => xhr.abort()
    xhr.open("POST", url)
    xhr.responseType = "json"
    xhr.setRequestHeader("content-type", "application/octet-stream")
    if (password) xhr.setRequestHeader("authorization", `Basic ${authTokenFromCredentials({ password })}`)
    xhr.upload.addEventListener("progress", (event) => report(event.loaded))
    xhr.addEventListener("loadend", () => signal.removeEventListener("abort", abort))
    xhr.addEventListener("load", () => {
      if (xhr.status !== 200) return reject(new Error(`Upload failed with status ${xhr.status}`))
      resolve((xhr.response as { data: { path: string } }).data.path)
    })
    xhr.addEventListener("error", () => reject(new Error("Upload failed")))
    xhr.addEventListener("abort", () => reject(new DOMException("Upload aborted", "AbortError")))
    signal.addEventListener("abort", abort, { once: true })
    xhr.send(file)
  })
}
