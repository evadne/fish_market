defmodule FishMarketWeb.MenuLive do
  use FishMarketWeb, :live_component

  alias FishMarketWeb.SessionRoute

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
              phx-click="menu-select-session"
              phx-value-session_key={session_key(session)}
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

  defp session_path(session_key) when is_binary(session_key),
    do: ~p"/session/#{SessionRoute.encode(session_key)}"

  defp session_path(_session_key), do: ~p"/"

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
