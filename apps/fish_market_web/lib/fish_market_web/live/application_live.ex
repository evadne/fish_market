defmodule FishMarketWeb.ApplicationLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw

  @impl true
  def mount(params, _session, socket) do
    selected_session_key = normalize_session_key(params)

    socket =
      socket
      |> assign(:initial_selected_session_key, selected_session_key)
      |> assign(:selected_session_key, selected_session_key)

    if connected?(socket) do
      OpenClaw.subscribe_selection()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    session_key = normalize_session_key(params)
    socket = assign(socket, :selected_session_key, session_key)

    OpenClaw.broadcast_selection(session_key)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:openclaw_ui, :select_session, session_key}, socket)
      when is_binary(session_key) and session_key != "" do
    if socket.assigns.selected_session_key == session_key do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: session_path(session_key))}
    end
  end

  @impl true
  def handle_info({:openclaw_ui, :select_session, _session_key}, socket) do
    if is_nil(socket.assigns.selected_session_key) do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: ~p"/")}
    end
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
          {live_render(@socket, FishMarketWeb.MenuLive,
            id: "menu-live",
            sticky: true,
            session: %{"selected_session_key" => @initial_selected_session_key}
          )}

          <button
            id="page-overlay"
            type="button"
            class="fixed inset-0 z-40 hidden bg-gray-900/70 lg:hidden"
            data-sidebar-overlay
            aria-label="Close navigation"
          >
          </button>

          {live_render(@socket, FishMarketWeb.SessionLive,
            id: "session-live",
            session: %{"selected_session_key" => @initial_selected_session_key}
          )}
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp normalize_session_key(%{"session_id" => session_key})
       when is_binary(session_key) and session_key != "" do
    URI.decode(session_key)
  end

  defp normalize_session_key(_params), do: nil

  defp session_path(session_key) when is_binary(session_key), do: ~p"/session/#{session_key}"
end
