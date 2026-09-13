import { describe, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { assignAttachmentFilenames, createComposerAttachments } from "@/composer/attachments/attachments"
import type { ComposerPrompt } from "@/composer/types"

function target(content = "") {
  const [store, setStore] = createStore<{ prompt: ComposerPrompt; cursor: number }>({
    prompt: [{ type: "text", content, start: 0, end: content.length }],
    cursor: content.length,
  })
  const selection = { start: content.length, end: content.length }
  const replacements: { prompt: ComposerPrompt; range: { start: number; end: number } }[] = []
  return {
    prompt: store,
    selection,
    replacements,
    capture: {
      current: () => store.prompt,
      cursor: () => store.cursor,
      set: (prompt: ComposerPrompt, cursor = store.cursor) => setStore({ prompt, cursor }),
      replace: (prompt: ComposerPrompt, range: { start: number; end: number }) => replacements.push({ prompt, range }),
      selection: () => ({ ...selection }),
    },
  }
}

function pasteEvent(file: File, text = "") {
  const transfer = new DataTransfer()
  transfer.items.add(file)
  transfer.setData("text/plain", text)
  return new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer })
}

describe("Composer attachment ownership", () => {
  test("assigns stable unique names to same-named and generic pasted images", () => {
    expect(
      assignAttachmentFilenames(
        [
          new File(["first"], "photo.png", { type: "image/png" }),
          new File(["second"], "photo.png", { type: "image/png" }),
          new File(["third"], "Screenshot.png", { type: "image/png" }),
        ],
        ["image-1.png"],
      ),
    ).toEqual(["photo.png", "photo-2.png", "image-2.png"])
  })

  test("keeps an async attachment with the Composer where it started", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const first = target()
        const second = target()
        const stored = Promise.withResolvers<{ id: string; url: string }>()
        let active = first.capture
        const attachments = createComposerAttachments({
          capture: () => active,
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "C:/repo",
          isDialogActive: () => false,
          warn() {},
          duplicate() {},
          onError: rejectTest,
          store: () => stored.promise,
        })

        const pending = attachments.addAttachments([new File(["image"], "image.png", { type: "image/png" })])
        active = second.capture
        stored.resolve({ id: "blob-1", url: "blob:test" })
        void pending.then(() => {
          expect(first.prompt.prompt.some((part) => part.type === "image" && part.blob.id === "blob-1")).toBe(true)
          expect(second.prompt.prompt.some((part) => part.type === "image")).toBe(false)
          dispose()
          resolveTest()
        }, rejectTest)
      })
    })
  })

  test("reads the tracked selection after asynchronous storage completes", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const draft = target("before after")
        draft.selection.start = 7
        draft.selection.end = 7
        const stored = Promise.withResolvers<{ id: string; url: string }>()
        const attachments = createComposerAttachments({
          capture: () => draft.capture,
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "/repo",
          isDialogActive: () => false,
          warn() {},
          duplicate() {},
          onError: rejectTest,
          store: () => stored.promise,
        })

        const pending = attachments.handlePaste(pasteEvent(new File(["one"], "photo.png", { type: "image/png" })))
        draft.capture.set([{ type: "text", content: "prefix before after", start: 0, end: 19 }], 14)
        draft.selection.start = 14
        draft.selection.end = 14
        stored.resolve({ id: "blob-1", url: "blob:one" })
        void pending.then(() => {
          expect(draft.replacements[0]?.range).toEqual({ start: 14, end: 14 })
          expect(draft.replacements[0]?.prompt).toMatchObject([
            { type: "text", content: "[photo.png] " },
            { type: "image", id: expect.any(String), filename: "photo.png" },
          ])
          dispose()
          resolveTest()
        }, rejectTest)
      })
    })
  })

  test("reserves filenames across concurrent image pastes", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const draft = target()
        const stores = [
          Promise.withResolvers<{ id: string; url: string }>(),
          Promise.withResolvers<{ id: string; url: string }>(),
        ]
        let index = 0
        const attachments = createComposerAttachments({
          capture: () => draft.capture,
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "/repo",
          isDialogActive: () => false,
          warn() {},
          duplicate() {},
          onError: rejectTest,
          store: () => stores[index++]!.promise,
        })

        const first = attachments.handlePaste(pasteEvent(new File(["one"], "photo.png", { type: "image/png" })))
        const second = attachments.handlePaste(pasteEvent(new File(["two"], "photo.png", { type: "image/png" })))
        stores[1].resolve({ id: "blob-2", url: "blob:two" })
        stores[0].resolve({ id: "blob-1", url: "blob:one" })
        void Promise.all([first, second]).then(() => {
          const images = draft.replacements.flatMap((replacement) =>
            replacement.prompt.filter((part) => part.type === "image"),
          )
          expect(images.map((image) => image.filename).toSorted((a, b) => a.localeCompare(b))).toEqual([
            "photo-2.png",
            "photo.png",
          ])
          expect(new Set(images.map((image) => image.id)).size).toBe(2)
          dispose()
          resolveTest()
        }, rejectTest)
      })
    })
  })

  test("keeps pasted text and warns when every file is unsupported", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const draft = target("before after")
        draft.selection.start = 7
        draft.selection.end = 7
        let warnings = 0
        const attachments = createComposerAttachments({
          capture: () => draft.capture,
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "/repo",
          isDialogActive: () => false,
          warn: () => warnings++,
          duplicate() {},
          onError: rejectTest,
        })

        void attachments.handlePaste(pasteEvent(new File([new Uint8Array([0, 1, 2])], "bad.bin"), "kept")).then(() => {
          expect(warnings).toBe(1)
          expect(draft.replacements).toEqual([
            {
              prompt: [{ type: "text", content: "kept", start: 0, end: 4 }],
              range: { start: 7, end: 7 },
            },
          ])
          dispose()
          resolveTest()
        }, rejectTest)
      })
    })
  })

  test("keeps pasted text without adding a citation when every image is a duplicate", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const draft = target("before after")
        draft.selection.start = 7
        draft.selection.end = 7
        draft.capture.set([
          { type: "text", content: "before after", start: 0, end: 12 },
          {
            type: "image",
            id: "existing",
            filename: "photo.png",
            mime: "image/png",
            blob: { id: "same", url: "blob:same" },
          },
        ])
        let duplicates = 0
        let warnings = 0
        const attachments = createComposerAttachments({
          capture: () => draft.capture,
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "/repo",
          isDialogActive: () => false,
          warn: () => warnings++,
          duplicate: () => duplicates++,
          onError: rejectTest,
          store: async () => ({ id: "same", url: "blob:same" }),
        })

        void attachments
          .handlePaste(pasteEvent(new File(["same"], "photo.png", { type: "image/png" }), "kept"))
          .then(() => {
            expect(duplicates).toBe(1)
            expect(warnings).toBe(0)
            expect(draft.replacements[0]?.prompt).toEqual([{ type: "text", content: "kept", start: 0, end: 4 }])
            dispose()
            resolveTest()
          }, rejectTest)
      })
    })
  })

  test("releases the tracked selection when native clipboard reading fails", async () => {
    await new Promise<void>((resolveTest, rejectTest) => {
      createRoot((dispose) => {
        const draft = target()
        let releases = 0
        const attachments = createComposerAttachments({
          capture: () => ({
            ...draft.capture,
            trackSelection: () => ({ current: draft.capture.selection, release: () => releases++ }),
          }),
          editor: () => document.createElement("div"),
          focusEditor() {},
          addPart: () => false,
          setDraggingType() {},
          directory: () => "/repo",
          isDialogActive: () => false,
          warn() {},
          duplicate() {},
          onError() {},
          readClipboardImage: () => Promise.reject(new Error("clipboard unavailable")),
        })
        const event = new ClipboardEvent("paste", {
          bubbles: true,
          cancelable: true,
          clipboardData: new DataTransfer(),
        })

        void attachments.handlePaste(event).then(
          () => rejectTest(new Error("Expected clipboard failure")),
          () => {
            expect(releases).toBe(1)
            dispose()
            resolveTest()
          },
        )
      })
    })
  })
})
