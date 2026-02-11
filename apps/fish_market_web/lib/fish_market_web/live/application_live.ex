defmodule FishMarketWeb.ApplicationLive do
  use FishMarketWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="application-live" class="bg-gray-100 dark:bg-gray-900 dark:text-gray-100">
        <div
          id="page-container"
          class="mx-auto flex min-h-dvh w-full min-w-80 flex-col bg-gray-100 lg:pl-64 dark:bg-gray-900 dark:text-gray-100"
        >
          {live_render(@socket, FishMarketWeb.MenuLive, id: "menu-live")}

          <button
            id="page-overlay"
            type="button"
            class="fixed inset-0 z-40 hidden bg-gray-900/70 lg:hidden"
            data-sidebar-overlay
            aria-label="Close navigation"
          >
          </button>

          {live_render(@socket, FishMarketWeb.SessionLive, id: "session-live")}
        </div>
      </div>
    </Layouts.app>
    """
  end
end
