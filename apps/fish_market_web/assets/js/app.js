// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/fish_market_web"
import topbar from "../vendor/topbar"

const darkModeStorageKey = "tailkit-dark-mode"
const showTracesCookieKey = "fish_market_show_traces"
const showTracesCookieMaxAge = 60 * 60 * 24 * 365
const systemColorSchemeQuery = window.matchMedia("(prefers-color-scheme: dark)")

const normalizeDarkMode = (mode) => {
  if (mode === "dark" || mode === "on") return "on"
  if (mode === "light" || mode === "off") return "off"
  return "system"
}

const applyDarkMode = (mode) => {
  const normalizedMode = normalizeDarkMode(mode)
  const shouldUseDark =
    normalizedMode === "on" || (normalizedMode === "system" && systemColorSchemeQuery.matches)

  document.documentElement.classList.toggle("dark", shouldUseDark)
}

const persistDarkMode = (mode) => {
  const normalizedMode = normalizeDarkMode(mode)

  if (normalizedMode === "system") {
    localStorage.removeItem(darkModeStorageKey)
  } else {
    localStorage.setItem(darkModeStorageKey, normalizedMode)
  }

  applyDarkMode(normalizedMode)
}

const readCookie = (name) => {
  const encodedName = encodeURIComponent(name)
  const prefix = `${encodedName}=`
  const cookies = document.cookie ? document.cookie.split(";") : []

  for (const chunk of cookies) {
    const trimmed = chunk.trim()

    if (trimmed.startsWith(prefix)) {
      return decodeURIComponent(trimmed.slice(prefix.length))
    }
  }

  return null
}

const readShowTracesPreference = () => {
  const value = readCookie(showTracesCookieKey)
  return value === "1" || value === "true"
}

const persistShowTracesPreference = (enabled) => {
  const value = enabled ? "1" : "0"
  document.cookie =
    `${showTracesCookieKey}=${value}; Path=/; Max-Age=${showTracesCookieMaxAge}; SameSite=Lax`
}

applyDarkMode(localStorage.getItem(darkModeStorageKey) || "system")

window.addEventListener("storage", (event) => {
  if (event.key === darkModeStorageKey) {
    applyDarkMode(event.newValue || "system")
  }
})

window.addEventListener("phx:set-theme", (event) => {
  const mode =
    event.target?.dataset?.phxTheme ||
      event.target?.closest?.("[data-phx-theme]")?.dataset?.phxTheme ||
      "system"

  persistDarkMode(mode)
})

window.addEventListener("phx:chat-input-clear", (event) => {
  const inputId = event.detail?.input_id
  if (typeof inputId !== "string" || inputId.length === 0) return

  const input = document.getElementById(inputId)
  if (!(input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement)) return

  input.value = ""
  if (input instanceof HTMLTextAreaElement) {
    input.style.height = "auto"
    input.style.overflowY = "hidden"
  }
  input.focus()
})

window.addEventListener("phx:chat-input-focus", (event) => {
  const inputId = event.detail?.input_id
  if (typeof inputId !== "string" || inputId.length === 0) return

  const input = document.getElementById(inputId)
  if (!(input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement)) return

  input.focus()
})

window.addEventListener("phx:set-show-traces", (event) => {
  persistShowTracesPreference(Boolean(event.detail?.enabled))
})

const syncSystemDarkMode = () => {
  if (!localStorage.getItem(darkModeStorageKey)) {
    applyDarkMode("system")
  }
}

if (typeof systemColorSchemeQuery.addEventListener === "function") {
  systemColorSchemeQuery.addEventListener("change", syncSystemDarkMode)
} else {
  systemColorSchemeQuery.addListener(syncSystemDarkMode)
}

const applicationLayoutElements = () => {
  const container = document.getElementById("page-container")
  const sidebar = document.getElementById("page-sidebar")
  const header = document.getElementById("page-header")
  const overlay = document.getElementById("page-overlay")
  const userMenu = document.getElementById("page-user-menu")
  const userMenuToggle = document.getElementById("page-user-menu-toggle")

  return {container, sidebar, header, overlay, userMenu, userMenuToggle}
}

const setDesktopSidebar = (open) => {
  const {container, sidebar, header} = applicationLayoutElements()
  if (!container || !sidebar || !header) return

  container.classList.toggle("lg:pl-64", open)
  header.classList.toggle("lg:pl-64", open)
  sidebar.classList.toggle("lg:translate-x-0", open)
  sidebar.classList.toggle("lg:-translate-x-full", !open)
}

const setMobileSidebar = (open) => {
  const {sidebar, overlay} = applicationLayoutElements()
  if (!sidebar || !overlay) return

  sidebar.classList.toggle("translate-x-0", open)
  sidebar.classList.toggle("-translate-x-full", !open)
  overlay.classList.toggle("hidden", !open)
}

const setUserMenu = (open) => {
  const {userMenu, userMenuToggle} = applicationLayoutElements()
  if (!userMenu || !userMenuToggle) return

  userMenu.classList.toggle("hidden", !open)
  userMenuToggle.setAttribute("aria-expanded", String(open))
}

const closeSessionActionMenus = () => {
  document.querySelectorAll("[data-session-menu]").forEach((menu) => {
    if (menu instanceof HTMLDetailsElement) {
      menu.open = false
    }
  })
}

const initializeApplicationLayout = () => {
  const {container, sidebar, header, overlay, userMenu, userMenuToggle} = applicationLayoutElements()
  if (!container || !sidebar || !header) return

  if (!sidebar.classList.contains("lg:-translate-x-full")) {
    setDesktopSidebar(true)
  }

  setMobileSidebar(false)
  if (overlay) overlay.classList.add("hidden")
  if (userMenu) userMenu.classList.add("hidden")
  if (userMenuToggle) userMenuToggle.setAttribute("aria-expanded", "false")
}

const toggleDesktopSidebar = () => {
  const {container} = applicationLayoutElements()
  if (!container) return

  setDesktopSidebar(!container.classList.contains("lg:pl-64"))
}

const handleApplicationLayoutClick = (event) => {
  if (event.target.closest("[data-sidebar-open]")) {
    setMobileSidebar(true)
    return
  }

  if (event.target.closest("[data-sidebar-close]") || event.target.closest("[data-sidebar-overlay]")) {
    setMobileSidebar(false)
    return
  }

  if (event.target.closest("[data-sidebar-desktop-toggle]")) {
    toggleDesktopSidebar()
    return
  }

  if (event.target.closest("[data-user-menu-toggle]")) {
    const {userMenu} = applicationLayoutElements()
    setUserMenu(userMenu?.classList.contains("hidden"))
    return
  }

  if (event.target.closest("[data-session-menu]")) {
    if (event.target.closest("[data-session-menu-close]")) {
      closeSessionActionMenus()
    }

    return
  }

  closeSessionActionMenus()

  if (!event.target.closest("[data-user-menu]")) {
    setUserMenu(false)
  }
}

if (!window.__fishMarketApplicationLayoutBound) {
  window.__fishMarketApplicationLayoutBound = true
  document.addEventListener("click", handleApplicationLayoutClick)

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      setMobileSidebar(false)
      setUserMenu(false)
      closeSessionActionMenus()
    }
  })

  window.addEventListener("resize", () => {
    if (window.innerWidth >= 1024) {
      setMobileSidebar(false)
    }
  })

  window.addEventListener("phx:page-loading-stop", initializeApplicationLayout)
}

initializeApplicationLayout()

const AutoScrollMessages = {
  mounted() {
    this.bottomThreshold = 96
    this.shouldStickToBottom = true
    this.handleScroll = () => {
      this.shouldStickToBottom = this.isNearBottom()
    }
    this.el.addEventListener("scroll", this.handleScroll, {passive: true})
    requestAnimationFrame(() => this.scrollToBottom())
  },

  beforeUpdate() {
    this.shouldStickToBottom = this.isNearBottom()
  },

  updated() {
    if (!this.shouldStickToBottom) return
    this.scrollToBottom()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
  },

  isNearBottom() {
    const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    return distance <= this.bottomThreshold
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
    this.shouldStickToBottom = true
  },
}

const ChatComposer = {
  mounted() {
    this.isComposing = false
    this.isFocused = false
    this.stickToBottomWhileComposing = true
    this.bottomThreshold = 96
    this.maxRows = 10
    this.messagesWrapper = () => document.getElementById("session-messages-wrapper")
    this.isWrapperNearBottom = () => {
      const wrapper = this.messagesWrapper()
      if (!(wrapper instanceof HTMLElement)) return false
      const distance = wrapper.scrollHeight - wrapper.scrollTop - wrapper.clientHeight
      return distance <= this.bottomThreshold
    }
    this.scrollWrapperToBottom = () => {
      const wrapper = this.messagesWrapper()
      if (!(wrapper instanceof HTMLElement)) return
      wrapper.scrollTop = wrapper.scrollHeight
    }
    this.resizeComposer = () => {
      const shouldAnchorBottom =
        this.isFocused && (this.stickToBottomWhileComposing || this.isWrapperNearBottom())

      const computed = window.getComputedStyle(this.el)
      const lineHeight = Number.parseFloat(computed.lineHeight) || 20
      const verticalPadding =
        (Number.parseFloat(computed.paddingTop) || 0) + (Number.parseFloat(computed.paddingBottom) || 0)
      const verticalBorder =
        (Number.parseFloat(computed.borderTopWidth) || 0) +
        (Number.parseFloat(computed.borderBottomWidth) || 0)
      const maxHeight = Math.ceil(lineHeight * this.maxRows + verticalPadding + verticalBorder)

      this.el.style.height = "auto"
      const nextHeight = Math.min(this.el.scrollHeight, maxHeight)
      this.el.style.height = `${nextHeight}px`
      this.el.style.overflowY = this.el.scrollHeight > maxHeight ? "auto" : "hidden"

      if (shouldAnchorBottom) {
        this.scrollWrapperToBottom()
      }
    }
    this.handleCompositionStart = () => {
      this.isComposing = true
    }
    this.handleCompositionEnd = () => {
      this.isComposing = false
    }
    this.handleKeyDown = (event) => {
      if (event.key !== "Enter") return
      if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return
      if (event.isComposing || this.isComposing) return

      const form = this.el.form
      if (!(form instanceof HTMLFormElement)) return

      event.preventDefault()
      form.requestSubmit()
    }
    this.handleInput = () => {
      this.resizeComposer()
    }
    this.handleFocus = () => {
      this.isFocused = true
      this.stickToBottomWhileComposing = this.isWrapperNearBottom()
      this.resizeComposer()
    }
    this.handleBlur = () => {
      this.isFocused = false
    }
    this.handleMessagesScroll = () => {
      if (!this.isFocused) return
      this.stickToBottomWhileComposing = this.isWrapperNearBottom()
    }
    this.handleWindowResize = () => {
      this.resizeComposer()
    }

    this.el.addEventListener("compositionstart", this.handleCompositionStart)
    this.el.addEventListener("compositionend", this.handleCompositionEnd)
    this.el.addEventListener("keydown", this.handleKeyDown)
    this.el.addEventListener("input", this.handleInput)
    this.el.addEventListener("focus", this.handleFocus)
    this.el.addEventListener("blur", this.handleBlur)
    window.addEventListener("resize", this.handleWindowResize)
    const wrapper = this.messagesWrapper()
    if (wrapper instanceof HTMLElement) {
      wrapper.addEventListener("scroll", this.handleMessagesScroll, {passive: true})
    }
    requestAnimationFrame(() => this.resizeComposer())
  },

  updated() {
    this.resizeComposer()
  },

  destroyed() {
    this.el.removeEventListener("compositionstart", this.handleCompositionStart)
    this.el.removeEventListener("compositionend", this.handleCompositionEnd)
    this.el.removeEventListener("keydown", this.handleKeyDown)
    this.el.removeEventListener("input", this.handleInput)
    this.el.removeEventListener("focus", this.handleFocus)
    this.el.removeEventListener("blur", this.handleBlur)
    window.removeEventListener("resize", this.handleWindowResize)
    const wrapper = this.messagesWrapper()
    if (wrapper instanceof HTMLElement) {
      wrapper.removeEventListener("scroll", this.handleMessagesScroll)
    }
  },
}

const SessionRelativeTimestamps = {
  mounted() {
    this.formatter = new Intl.RelativeTimeFormat(navigator.language || "en-US", {
      numeric: "auto",
    })
    this.handle = null

    this.updateTimestamps = () => {
      const nodes = this.el.querySelectorAll("[data-session-updated-at]")
      const nowMs = Date.now()

      let minimumNextDelay = 300_000

      nodes.forEach((node) => {
        const value = Number(node.dataset.sessionUpdatedAt)
        const textNode = node.querySelector(".session-updated-at-text")
        if (!textNode) return

        if (!Number.isFinite(value) || value <= 0) {
          textNode.textContent = "time unavailable"
          return
        }

        const diffMs = value - nowMs
        const seconds = Math.round(diffMs / 1000)
        const absSeconds = Math.abs(seconds)

        let unit
        let magnitude
        let nextDelay = 300_000

        if (absSeconds < 60) {
          unit = "second"
          magnitude = seconds
          nextDelay = 1_000
        } else if (absSeconds < 3600) {
          unit = "minute"
          magnitude = Math.round(seconds / 60)
          nextDelay = 60_000
        } else if (absSeconds < 86_400) {
          unit = "hour"
          magnitude = Math.round(seconds / 3600)
          nextDelay = 60_000
        } else {
          unit = "day"
          magnitude = Math.round(seconds / 86_400)
          nextDelay = 300_000
        }

        textNode.textContent = this.formatter.format(magnitude, unit)
        minimumNextDelay = Math.min(minimumNextDelay, nextDelay)
      })

      if (nodes.length > 0 && minimumNextDelay > 0) {
        this.handle = window.setTimeout(this.updateTimestamps, minimumNextDelay)
      }
    }

    this.updateTimestamps()
  },

  updated() {
    if (this.handle) {
      window.clearTimeout(this.handle)
      this.handle = null
    }
    this.updateTimestamps()
  },

  destroyed() {
    if (this.handle) {
      window.clearTimeout(this.handle)
      this.handle = null
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    show_traces: readShowTracesPreference(),
  }),
  hooks: {
    ...colocatedHooks,
    AutoScrollMessages,
    ChatComposer,
    SessionRelativeTimestamps,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
