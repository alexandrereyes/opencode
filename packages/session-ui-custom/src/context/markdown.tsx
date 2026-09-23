import { createContext, useContext, type ParentProps } from "solid-js"

export type ReadMarkdownImage = (path: string, signal: AbortSignal) => Promise<Blob | undefined>
export type OpenMarkdownLocalFile = (path: string) => void

const context = createContext<{
  readonly readImage?: ReadMarkdownImage
  readonly openLocalFile?: OpenMarkdownLocalFile
}>()

export function MarkdownProvider(
  props: ParentProps<{ readImage?: ReadMarkdownImage; openLocalFile?: OpenMarkdownLocalFile }>,
) {
  return (
    <context.Provider
      value={{
        get readImage() {
          return props.readImage
        },
        get openLocalFile() {
          return props.openLocalFile
        },
      }}
    >
      {props.children}
    </context.Provider>
  )
}

export const useMarkdown = () => useContext(context)
