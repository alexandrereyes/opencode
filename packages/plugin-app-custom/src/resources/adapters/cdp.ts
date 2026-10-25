/**
 * Minimal Chrome DevTools Protocol client over the browser WebSocket, with flattened target sessions. Only the
 * commands and events the Chrome adapter uses are typed here.
 */

export interface TargetInfo {
  readonly targetId: string
  readonly type: string
  readonly title: string
  readonly url: string
  readonly attached?: boolean
  readonly openerId?: string
}

export interface ScreencastMetadata {
  readonly offsetTop: number
  readonly pageScaleFactor: number
  /** CSS pixels of the visible viewport. */
  readonly deviceWidth: number
  readonly deviceHeight: number
  readonly scrollOffsetX: number
  readonly scrollOffsetY: number
  /** Seconds since the epoch. */
  readonly timestamp?: number
}

interface NavigationEntry {
  readonly id: number
  readonly url: string
  readonly title: string
}

type MouseButton = "none" | "left" | "middle" | "right"
type TouchPoint = { readonly x: number; readonly y: number; readonly id?: number }

export interface Commands {
  "Target.getTargets": { params: {}; result: { targetInfos: TargetInfo[] } }
  "Target.attachToTarget": { params: { targetId: string; flatten: true }; result: { sessionId: string } }
  "Target.detachFromTarget": { params: { sessionId: string }; result: {} }
  "Target.setDiscoverTargets": { params: { discover: boolean }; result: {} }
  "Target.getTargetInfo": { params: { targetId: string }; result: { targetInfo: TargetInfo } }
  "Target.createTarget": { params: { url: string }; result: { targetId: string } }
  "Target.activateTarget": { params: { targetId: string }; result: {} }
  "Page.enable": { params: {}; result: {} }
  "Page.startScreencast": {
    params: { format: "jpeg" | "png"; quality?: number; maxWidth?: number; maxHeight?: number; everyNthFrame?: number }
    result: {}
  }
  "Page.stopScreencast": { params: {}; result: {} }
  "Page.screencastFrameAck": { params: { sessionId: number }; result: {} }
  "Page.captureScreenshot": {
    params: {
      format: "jpeg" | "png"
      quality?: number
      optimizeForSpeed?: boolean
      clip?: { x: number; y: number; width: number; height: number; scale: number }
    }
    result: { data: string }
  }
  "Page.getLayoutMetrics": {
    params: {}
    result: { cssVisualViewport: { clientWidth: number; clientHeight: number; pageX: number; pageY: number } }
  }
  "Page.getNavigationHistory": { params: {}; result: { currentIndex: number; entries: NavigationEntry[] } }
  "Page.navigateToHistoryEntry": { params: { entryId: number }; result: {} }
  "Page.navigate": { params: { url: string }; result: { errorText?: string } }
  "Page.reload": { params: { ignoreCache?: boolean }; result: {} }
  "Runtime.evaluate": {
    params: { expression: string; returnByValue: true; silent?: boolean }
    result: { result: { value?: unknown } }
  }
  "Input.dispatchMouseEvent": {
    params: {
      type: "mousePressed" | "mouseReleased" | "mouseMoved" | "mouseWheel"
      x: number
      y: number
      button?: MouseButton
      buttons?: number
      clickCount?: number
      deltaX?: number
      deltaY?: number
      modifiers?: number
    }
    result: {}
  }
  "Input.dispatchTouchEvent": {
    params: {
      type: "touchStart" | "touchMove" | "touchEnd" | "touchCancel"
      touchPoints: TouchPoint[]
      modifiers?: number
    }
    result: {}
  }
  "Input.dispatchKeyEvent": {
    params: {
      type: "keyDown" | "rawKeyDown" | "keyUp" | "char"
      key?: string
      code?: string
      text?: string
      unmodifiedText?: string
      windowsVirtualKeyCode?: number
      modifiers?: number
    }
    result: {}
  }
  "Input.insertText": { params: { text: string }; result: {} }
}

export interface Events {
  "Page.screencastFrame": { data: string; metadata: ScreencastMetadata; sessionId: number }
  "Page.frameNavigated": { frame: { id: string; parentId?: string; url: string } }
  "Page.navigatedWithinDocument": { frameId: string; url: string }
  "Page.loadEventFired": { timestamp: number }
  "Target.targetCreated": { targetInfo: TargetInfo }
  "Target.targetDestroyed": { targetId: string }
  "Target.targetInfoChanged": { targetInfo: TargetInfo }
  "Target.detachedFromTarget": { sessionId: string; targetId?: string }
}

export class CDPError extends Error {}

interface Message {
  readonly id?: number
  readonly method?: string
  readonly params?: unknown
  readonly result?: unknown
  readonly error?: { readonly message: string }
  readonly sessionId?: string
}

export class CDP {
  private next = 1
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  private readonly listeners = new Map<string, Set<(params: unknown, sessionId?: string) => void>>()
  readonly closed: Promise<void>

  private constructor(private readonly socket: WebSocket) {
    this.closed = new Promise((resolve) => {
      socket.addEventListener("close", () => {
        for (const waiter of this.pending.values()) waiter.reject(new CDPError("CDP connection closed"))
        this.pending.clear()
        resolve()
      })
    })
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return
      const message: Message = JSON.parse(event.data)
      if (message.id !== undefined) {
        const waiter = this.pending.get(message.id)
        this.pending.delete(message.id)
        if (!waiter) return
        if (message.error) return waiter.reject(new CDPError(message.error.message))
        return waiter.resolve(message.result ?? {})
      }
      if (!message.method) return
      for (const listener of this.listeners.get(message.method) ?? []) listener(message.params, message.sessionId)
    })
  }

  /** Connects to `ws://…/devtools/browser/…`; rejects after `timeout` milliseconds. */
  static connect(url: string, timeout = 5_000) {
    return new Promise<CDP>((resolve, reject) => {
      const socket = new WebSocket(url)
      const timer = setTimeout(() => {
        socket.close()
        reject(new CDPError(`CDP connection to ${url} timed out`))
      }, timeout)
      socket.addEventListener("open", () => {
        clearTimeout(timer)
        resolve(new CDP(socket))
      })
      socket.addEventListener("error", () => {
        clearTimeout(timer)
        reject(new CDPError(`CDP connection to ${url} failed`))
      })
    })
  }

  send<M extends keyof Commands>(method: M, params: Commands[M]["params"], sessionId?: string, timeout = 10_000) {
    if (this.socket.readyState !== WebSocket.OPEN) return Promise.reject(new CDPError("CDP connection closed"))
    const id = this.next++
    return new Promise<Commands[M]["result"]>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new CDPError(`${method} timed out`))
      }, timeout)
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer)
          // The browser answers with the shape declared in `Commands` for this method.
          resolve(value as Commands[M]["result"])
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        },
      })
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }))
    })
  }

  on<E extends keyof Events>(event: E, listener: (params: Events[E], sessionId?: string) => void) {
    const set = this.listeners.get(event) ?? new Set()
    this.listeners.set(event, set)
    // Events carry the shape declared in `Events` for their method.
    const wrapped = (params: unknown, sessionId?: string) => listener(params as Events[E], sessionId)
    set.add(wrapped)
    return () => void set.delete(wrapped)
  }

  close() {
    if (this.socket.readyState === WebSocket.OPEN || this.socket.readyState === WebSocket.CONNECTING)
      this.socket.close()
    return this.closed
  }
}
