defmodule FishMarketWeb.MenuLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw

  @refresh_states MapSet.new(["final", "aborted", "error"])

  @impl true
  def mount(_params, session, socket) do
    selected_session_key = initial_selected_session_key(session)

    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:sessions_loading?, false)
      |> assign(:sessions_error, nil)
      |> assign(:selected_session_key, selected_session_key)
      |> assign(:unread_session_keys, MapSet.new())

    if connected?(socket) do
      OpenClaw.subscribe_gateway()
      OpenClaw.subscribe_chat()
      OpenClaw.subscribe_selection()
      send(self(), :load_sessions)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_sessions, socket) do
    {:noreply, load_sessions(socket)}
  end

  @impl true
  def handle_info({:openclaw_gateway, :connected, _payload}, socket) do
    {:noreply, load_sessions(socket)}
  end

  @impl true
  def handle_info({:openclaw_gateway, :disconnected, payload}, socket) do
    {:noreply, assign(socket, :sessions_error, connection_error(payload))}
  end

  @impl true
  def handle_info({:openclaw_ui, :select_session, session_key}, socket)
      when is_binary(session_key) and session_key != "" do
    session_known? = has_session_key?(socket.assigns.sessions, session_key)

    socket =
      socket
      |> select_session(session_key)
      |> ensure_session_placeholder(session_key)

    if session_known? do
      {:noreply, socket}
    else
      {:noreply, maybe_schedule_refresh(socket)}
    end
  end

  @impl true
  def handle_info({:openclaw_ui, :select_session, _session_key}, socket) do
    {:noreply, assign(socket, :selected_session_key, nil)}
  end

  @impl true
  def handle_info({:openclaw_event, "chat", payload}, socket) do
    session_key = payload_session_key(payload)

    if is_binary(session_key) do
      socket =
        if socket.assigns.selected_session_key == session_key do
          socket
        else
          update(socket, :unread_session_keys, &MapSet.put(&1, session_key))
        end

      state_value = payload_state(payload)
      session_missing? = not has_session_key?(socket.assigns.sessions, session_key)

      socket =
        if session_missing? or MapSet.member?(@refresh_states, state_value) do
          maybe_schedule_refresh(socket)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:openclaw_event, _event, _payload}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav
      id="page-sidebar"
      class="fixed top-0 bottom-0 left-0 z-50 flex h-full w-full -translate-x-full flex-col border-r border-gray-800 bg-gray-800 text-gray-200 transition-transform duration-500 ease-out lg:w-64 lg:translate-x-0"
      aria-label="Main Sidebar Navigation"
    >
      <div class="flex h-16 w-full flex-none items-center justify-between bg-gray-600/25 px-4 lg:justify-center">
        <.link
          patch={~p"/"}
          id="menu-brand-link"
          class="group inline-flex items-center gap-2 text-lg font-bold tracking-wide text-gray-100 hover:text-gray-300"
        >
          <.icon
            name="hero-cube-transparent-mini"
            class="size-5 text-purple-400 transition group-hover:scale-110"
          />
          <span>Fish Market</span>
        </.link>

        <div class="flex items-center gap-2 lg:hidden">
          <button
            id="menu-mobile-close"
            type="button"
            class="inline-flex items-center justify-center gap-2 rounded-lg border border-gray-700 bg-gray-800 px-3 py-2 text-sm leading-5 font-semibold text-gray-300 hover:border-gray-600 hover:text-gray-200 hover:shadow-xs"
            data-sidebar-close
            aria-label="Close sidebar"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
      </div>

      <div class="overflow-y-auto">
        <div class="w-full p-4">
          <div class="mb-3 px-3 text-xs font-semibold tracking-wider text-gray-500 uppercase">
            Sessions
          </div>

          <nav id="menu-sessions-list" class="space-y-1" aria-label="Session Navigation">
            <div
              :if={@sessions_loading?}
              id="menu-sessions-loading"
              class="rounded-lg border border-gray-700 bg-gray-700/30 px-3 py-2 text-xs text-gray-300"
            >
              Loading sessions...
            </div>

            <div
              :if={@sessions_error}
              id="menu-sessions-error"
              class="rounded-lg border border-red-700/60 bg-red-900/30 px-3 py-2 text-xs text-red-200"
            >
              {@sessions_error}
            </div>

            <div
              :if={@sessions == [] and not @sessions_loading? and is_nil(@sessions_error)}
              id="menu-empty-sessions"
              class="rounded-lg border border-gray-700 bg-gray-700/30 px-3 py-2 text-xs text-gray-400"
            >
              No active sessions yet.
            </div>

            <.link
              :for={session <- @sessions}
              id={"menu-session-" <> session_dom_id(session_key(session))}
              patch={session_path(session_key(session))}
              class={[
                "group flex w-full items-center justify-between gap-2 rounded-lg border border-transparent px-2.5 py-2 text-left text-sm font-medium active:border-gray-600",
                @selected_session_key == session_key(session) && "bg-gray-700/75 text-white",
                @selected_session_key != session_key(session) &&
                  "text-gray-200 hover:bg-gray-700/75 hover:text-white"
              ]}
            >
              <span class="flex min-w-0 grow flex-col">
                <span class="truncate">{session_label(session)}</span>
                <span class="truncate text-xs text-gray-500">{session_key(session)}</span>
                <span class="truncate text-[10px] text-gray-500">
                  {session_updated_at_label(session)}
                </span>
              </span>

              <span class="flex flex-none items-center gap-2">
                <span class="rounded-md border border-gray-700 px-1.5 py-0.5 text-[10px] leading-4 text-gray-400">
                  {session_kind(session)}
                </span>

                <span
                  :if={MapSet.member?(@unread_session_keys, session_key(session))}
                  class="inline-flex rounded-full border border-purple-700 bg-purple-700 px-1.5 py-0.5 text-xs leading-4 font-semibold text-purple-50"
                >
                  new
                </span>
              </span>
            </.link>
          </nav>
        </div>
      </div>
    </nav>
    """
  end

  defp load_sessions(socket) do
    socket = assign(socket, :sessions_loading?, true)

    case OpenClaw.sessions_list(%{"includeGlobal" => true, "includeUnknown" => true}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        sessions = Enum.sort_by(sessions, &updated_at/1, :desc)
        previous_selected = socket.assigns.selected_session_key
        next_selected = resolve_selected_session_key(sessions, previous_selected)

        socket =
          socket
          |> assign(:sessions, sessions)
          |> assign(:sessions_loading?, false)
          |> assign(:sessions_error, nil)
          |> assign(:selected_session_key, next_selected)
          |> ensure_session_placeholder(next_selected)
          |> prune_unread_sessions(sessions)

        if is_binary(next_selected) and next_selected != previous_selected do
          OpenClaw.broadcast_selection(next_selected)
        end

        socket

      {:ok, _payload} ->
        socket
        |> assign(:sessions_loading?, false)
        |> assign(:sessions_error, "invalid sessions.list payload")

      {:error, reason} ->
        socket
        |> assign(:sessions_loading?, false)
        |> assign(:sessions_error, format_reason(reason))
    end
  end

  defp maybe_schedule_refresh(socket) do
    if socket.assigns.sessions_loading? do
      socket
    else
      send(self(), :load_sessions)
      socket
    end
  end

  defp select_session(socket, session_key) when is_binary(session_key) do
    socket
    |> assign(:selected_session_key, session_key)
    |> update(:unread_session_keys, &MapSet.delete(&1, session_key))
  end

  defp ensure_session_placeholder(socket, session_key) when is_binary(session_key) do
    if has_session_key?(socket.assigns.sessions, session_key) do
      socket
    else
      placeholder_session = %{
        "key" => session_key,
        "label" => "New session",
        "displayName" => "New session",
        "kind" => "direct",
        "updatedAt" => System.system_time(:millisecond)
      }

      update(socket, :sessions, fn sessions -> [placeholder_session | sessions] end)
    end
  end

  defp ensure_session_placeholder(socket, _session_key), do: socket

  defp resolve_selected_session_key([], previous_selected) when is_binary(previous_selected),
    do: previous_selected

  defp resolve_selected_session_key([], _previous), do: nil

  defp resolve_selected_session_key(_sessions, previous_selected)
       when is_binary(previous_selected),
       do: previous_selected

  defp resolve_selected_session_key(_sessions, _previous), do: nil

  defp prune_unread_sessions(socket, sessions) do
    valid_keys =
      sessions
      |> Enum.map(&session_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    assign(
      socket,
      :unread_session_keys,
      MapSet.intersection(socket.assigns.unread_session_keys, valid_keys)
    )
  end

  defp has_session_key?(sessions, key) when is_binary(key) do
    Enum.any?(sessions, fn session -> session_key(session) == key end)
  end

  defp session_key(session) when is_map(session) do
    map_string(session, "key") || map_string(session, :key)
  end

  defp session_label(session) do
    map_string(session, "label") ||
      map_string(session, :label) ||
      map_string(session, "displayName") ||
      map_string(session, :displayName) ||
      session_key(session) ||
      "(unknown)"
  end

  defp session_kind(session) do
    map_string(session, "kind") || map_string(session, :kind) || "unknown"
  end

  defp session_dom_id(nil), do: "unknown"

  defp session_dom_id(session_key) do
    session_key
    |> :erlang.phash2()
    |> Integer.to_string()
  end

  defp session_path(session_key) when is_binary(session_key), do: ~p"/session/#{session_key}"
  defp session_path(_session_key), do: ~p"/"

  defp initial_selected_session_key(%{"selected_session_key" => session_key})
       when is_binary(session_key) and session_key != "" do
    session_key
  end

  defp initial_selected_session_key(_session), do: nil

  defp updated_at(session) do
    map_integer(session, "updatedAt")
    |> normalize_unix_timestamp()
    |> Kernel.||(map_integer(session, :updatedAt) |> normalize_unix_timestamp())
    |> Kernel.||(0)
  end

  defp session_updated_at_label(session) do
    case updated_at(session) do
      0 ->
        "updated time unavailable"

      timestamp_ms ->
        case DateTime.from_unix(timestamp_ms, :millisecond) do
          {:ok, datetime} -> "updated " <> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
          _ -> "updated time unavailable"
        end
    end
  end

  defp payload_session_key(payload) do
    map_string(payload, "sessionKey") || map_string(payload, :sessionKey)
  end

  defp payload_state(payload) do
    map_string(payload, "state") || map_string(payload, :state) || ""
  end

  defp connection_error(%{reason: reason}) when is_binary(reason), do: reason
  defp connection_error(_payload), do: "Gateway disconnected"

  defp format_reason(%{"message" => message}) when is_binary(message), do: message
  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason), do: inspect(reason)

  defp map_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp map_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp normalize_unix_timestamp(value) when is_integer(value) and value > 0 do
    if value < 10_000_000_000 do
      value * 1000
    else
      value
    end
  end

  defp normalize_unix_timestamp(_), do: nil
end
