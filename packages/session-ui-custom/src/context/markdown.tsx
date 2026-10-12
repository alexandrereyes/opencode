import { createContext, useContext, type ParentProps } from "solid-js"

export type ReadMarkdownImage = (path: string, signal: AbortSignal) => Promise<Blob | undefined>
export type OpenMarkdownLocalFile = (path: string) => void
/**
 * Whether an inline-code path names a file that exists. Inline code is styled as a file link only when this says yes;
 * without it, inline code stays plain.
 */
export type MarkdownLocalFileExists = (path: string) => boolean | Promise<boolean>
export type OpenMarkdownSession = (sessionID: string) => void
/** Whether a session ID mentioned in Markdown names a session the host can open. Only those IDs become links. */
export type MarkdownSessionExists = (sessionID: string) => boolean | Promise<boolean>

const context = createContext<{
  readonly readImage?: ReadMarkdownImage
  readonly openLocalFile?: OpenMarkdownLocalFile
  readonly localFileExists?: MarkdownLocalFileExists
  readonly openSession?: OpenMarkdownSession
  readonly sessionExists?: MarkdownSessionExists
}>()

export function MarkdownProvider(
  props: ParentProps<{
    readImage?: ReadMarkdownImage
    openLocalFile?: OpenMarkdownLocalFile
    localFileExists?: MarkdownLocalFileExists
    openSession?: OpenMarkdownSession
    sessionExists?: MarkdownSessionExists
  }>,
) {
  const parent = useMarkdown()
  return (
    <context.Provider
      value={{
        get readImage() {
          return props.readImage
        },
        get openLocalFile() {
          return props.openLocalFile
        },
        get localFileExists() {
          return props.localFileExists
        },
        // Nested providers scope files to a directory; sessions belong to the server, so they inherit.
        get openSession() {
          return props.openSession ?? parent?.openSession
        },
        get sessionExists() {
          return props.sessionExists ?? parent?.sessionExists
        },
      }}
    >
      {props.children}
    </context.Provider>
  )
}

export const useMarkdown = () => useContext(context)
