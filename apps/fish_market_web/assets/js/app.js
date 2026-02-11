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
  input.focus()
})

window.addEventListener("phx:chat-input-focus", (event) => {
  const inputId = event.detail?.input_id
  if (typeof inputId !== "string" || inputId.length === 0) return

  const input = document.getElementById(inputId)
  if (!(input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement)) return

  input.focus()
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
    requestAnimationFrame(() => this.scrollToBottom())
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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AutoScrollMessages},
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
