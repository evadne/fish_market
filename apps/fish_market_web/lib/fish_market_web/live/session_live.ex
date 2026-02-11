defmodule FishMarketWeb.SessionLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw
  alias FishMarket.OpenClaw.Message
  alias FishMarketWeb.SessionRoute

  @history_limit 200
  @tool_trace_text_limit 12_000

  @impl true
  def mount(params, _session, socket) do
    selected_session_key =
      case normalize_session_selection(params) do
        {:ok, session_key} -> session_key
        _ -> nil
      end

    show_traces? = initial_show_traces_preference(socket)

    socket =
      socket
      |> assign(:initial_selected_session_key, selected_session_key)
      |> assign(:selected_session_key, selected_session_key)
      |> assign(:menu_live_pid, nil)
      |> assign(:history_loading?, false)
      |> assign(:history_request_id, nil)
      |> assign(:history_error, nil)
      |> assign(:send_error, nil)
      |> assign(:can_send_message?, false)
      |> assign(:show_traces?, show_traces?)
      |> assign(:show_no_messages_state?, false)
      |> assign(:history_messages, [])
      |> assign(:assistant_pending?, false)
      |> assign(:streaming_text, nil)
      |> assign(:streaming_run_id, nil)
      |> assign(:subscribed_session_key, nil)
      |> assign(:pending_session_key, nil)
      |> assign(:queued_messages, [])
      |> assign(:form, to_form(%{"message" => ""}, as: :chat))
      |> stream(:messages, [])
      |> sync_no_messages_state()

    socket =
      if connected?(socket) do
        OpenClaw.subscribe_gateway()

        if is_binary(selected_session_key) do
          socket
          |> ensure_session_subscription(selected_session_key)
          |> request_history_load(selected_session_key)
        else
          socket
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case normalize_session_selection(params) do
      :none ->
        {:noreply, clear_session_selection(socket)}

      :invalid ->
        {:noreply, reject_session_selection(socket, "Invalid session URL")}

      {:ok, session_key} ->
        if selectable_session?(socket, session_key) do
          {:noreply, select_session(socket, session_key)}
        else
          {:noreply, reject_session_selection(socket, "Session not found")}
        end
    end
  end

  @impl true
  def handle_event("compose-message", %{"chat" => %{"message" => raw_message}}, socket) do
    can_send_message? = String.trim(raw_message) != ""

    {:noreply,
     socket
     |> assign(:can_send_message?, can_send_message?)
     |> assign(:form, to_form(%{"message" => raw_message}, as: :chat))}
  end

  @impl true
  def handle_event("send-message", %{"chat" => %{"message" => raw_message}}, socket) do
    message = String.trim(raw_message)

    cond do
      message == "" ->
        {:noreply, assign(socket, :can_send_message?, false)}

      is_nil(socket.assigns.selected_session_key) ->
        new_session_key = build_new_session_key(nil)
        enqueue_session_creation(new_session_key)

        {:noreply,
         socket
         |> initialize_new_session(new_session_key)
         |> ensure_session_subscription(new_session_key)
         |> append_local_user_message(message)
         |> update(:queued_messages, fn messages -> messages ++ [message] end)
         |> clear_compose()
         |> assign(:send_error, nil)
         |> notify_menu_selection(new_session_key)
         |> push_patch(to: session_path(new_session_key))}

      true ->
        selected_session_key = socket.assigns.selected_session_key

        if pending_session?(socket, selected_session_key) do
          {:noreply,
           socket
           |> append_local_user_message(message)
           |> update(:queued_messages, fn messages -> messages ++ [message] end)
           |> clear_compose()
           |> assign(:send_error, nil)}
        else
          case validate_selected_session_for_send(selected_session_key) do
            :ok ->
              run_id = OpenClaw.idempotency_key()

              case OpenClaw.chat_send(selected_session_key, message, %{idempotency_key: run_id}) do
                {:ok, _payload} ->
                  OpenClaw.broadcast_local_user_message(selected_session_key, %{
                    "sessionKey" => selected_session_key,
                    "runId" => run_id,
                    "message" => message,
                    "timestamp" => System.system_time(:millisecond)
                  })

                  {:noreply,
                   socket
                   |> clear_compose()
                   |> assign(:send_error, nil)}

                {:error, reason} ->
                  {:noreply, assign(socket, :send_error, format_reason(reason))}
              end

            {:error, reason} ->
              {:noreply, assign(socket, :send_error, reason)}
          end
        end
    end
  end

  @impl true
  def handle_event("new-session", _params, socket) do
    new_session_key = build_new_session_key(socket.assigns.selected_session_key)
    enqueue_session_creation(new_session_key)

    {:noreply,
     socket
     |> initialize_new_session(new_session_key)
     |> ensure_session_subscription(new_session_key)
     |> notify_menu_selection(new_session_key)
     |> push_event("chat-input-focus", %{input_id: "chat-message-input"})
     |> push_patch(to: session_path(new_session_key))}
  end

  @impl true
  def handle_event("toggle-traces", _params, socket) do
    show_traces? = not socket.assigns.show_traces?
    visible_messages = visible_messages(socket.assigns.history_messages, show_traces?)

    {:noreply,
     socket
     |> assign(:show_traces?, show_traces?)
     |> stream(:messages, visible_messages, reset: true)
     |> sync_no_messages_state()
     |> push_event("set-show-traces", %{enabled: show_traces?})}
  end

  @impl true
  def handle_info({:menu_live, :mounted, menu_pid}, socket) when is_pid(menu_pid) do
    {:noreply,
     socket
     |> assign(:menu_live_pid, menu_pid)
     |> notify_menu_selection(socket.assigns.selected_session_key)}
  end

  @impl true
  def handle_info({:load_history, session_key, request_id}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      result = OpenClaw.chat_history(session_key, @history_limit)
      send(liveview_pid, {:history_loaded, session_key, request_id, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:history_loaded, session_key, request_id, result}, socket) do
    if stale_history_response?(socket, session_key, request_id) do
      {:noreply, socket}
    else
      {:noreply, apply_history_result(socket, result)}
    end
  end

  @impl true
  def handle_info({:new_session_created, session_key, result}, socket) do
    had_queued_messages? = socket.assigns.queued_messages != []

    socket =
      if socket.assigns.pending_session_key == session_key do
        assign(socket, :pending_session_key, nil)
      else
        socket
      end

    socket =
      case result do
        {:ok, _payload} ->
          socket

        {:error, reason} ->
          assign(socket, :send_error, "Failed to create session: #{format_reason(reason)}")
      end

    socket =
      if socket.assigns.selected_session_key == session_key do
        socket = flush_queued_messages(socket, session_key)

        if had_queued_messages? do
          socket
        else
          request_history_load(socket, session_key)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:openclaw_gateway, :connected, _payload}, socket) do
    selected_session_key = socket.assigns.selected_session_key

    socket =
      if is_binary(selected_session_key) do
        socket
        |> ensure_session_subscription(selected_session_key)
        |> flush_queued_messages(selected_session_key)
        |> request_history_load(selected_session_key)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:openclaw_gateway, :disconnected, _payload}, socket) do
    {:noreply,
     socket |> assign(:history_error, "Gateway disconnected") |> sync_no_messages_state()}
  end

  @impl true
  def handle_info({:openclaw_local_user_message, payload}, socket) do
    {:noreply, socket |> apply_local_user_message(payload) |> sync_no_messages_state()}
  end

  @impl true
  def handle_info({:openclaw_event, "chat", payload}, socket) do
    {:noreply, socket |> apply_chat_event(payload) |> sync_no_messages_state()}
  end

  @impl true
  def handle_info({:openclaw_event, "agent", payload}, socket) do
    {:noreply, socket |> apply_agent_event(payload) |> sync_no_messages_state()}
  end

  @impl true
  def handle_info({:openclaw_event, _event, _payload}, socket) do
    {:noreply, socket}
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

          <header
            id="page-header"
            class="fixed top-0 right-0 left-0 z-30 flex h-16 flex-none items-center bg-white shadow-xs lg:pl-64 dark:bg-gray-800"
          >
            <div class="mx-auto flex w-full max-w-10xl justify-between px-4 lg:px-8">
              <div class="flex items-center gap-2">
                <div class="hidden lg:block">
                  <button
                    id="sidebar-desktop-toggle"
                    type="button"
                    class="inline-flex items-center justify-center gap-2 rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm leading-5 font-semibold text-gray-800 hover:border-gray-300 hover:text-gray-900 hover:shadow-xs dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300 dark:hover:border-gray-600 dark:hover:text-gray-200"
                    data-sidebar-desktop-toggle
                    aria-label="Toggle sidebar"
                  >
                    <.icon name="hero-bars-3" class="size-5" />
                  </button>
                </div>

                <div class="lg:hidden">
                  <button
                    id="sidebar-mobile-open"
                    type="button"
                    class="inline-flex items-center justify-center gap-2 rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm leading-5 font-semibold text-gray-800 hover:border-gray-300 hover:text-gray-900 hover:shadow-xs dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300 dark:hover:border-gray-600 dark:hover:text-gray-200"
                    data-sidebar-open
                    aria-label="Open sidebar"
                  >
                    <.icon name="hero-bars-3" class="size-5" />
                  </button>
                </div>
              </div>

              <div class="flex items-center gap-2">
                <button
                  id="header-new-session-button"
                  type="button"
                  phx-click="new-session"
                  class="inline-flex items-center justify-center rounded-lg border border-purple-700 bg-purple-700 px-3 py-2 text-sm leading-5 font-semibold text-purple-50 hover:border-purple-600 hover:bg-purple-600 focus:outline-hidden focus:ring-3 focus:ring-purple-500/50"
                >
                  New Session
                </button>
              </div>
            </div>
          </header>

          <main id="page-content" class="mt-16 flex h-[calc(100dvh-4rem)] max-w-full flex-col">
            <div class="mx-auto flex min-h-0 w-full max-w-10xl flex-1 flex-col p-4 lg:p-8">
              <section
                id="session-content"
                class="flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl border border-gray-200 bg-white shadow-xs dark:border-gray-700 dark:bg-gray-800"
              >
                <div class="border-b border-gray-200 px-4 py-3 dark:border-gray-700 lg:px-6">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <h2
                        id="session-title"
                        class="text-sm font-semibold text-gray-900 dark:text-gray-100"
                      >
                        Session
                      </h2>
                      <p id="session-subtitle" class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                        {session_subtitle(
                          @selected_session_key,
                          @history_loading?,
                          @history_error,
                          @pending_session_key
                        )}
                      </p>
                    </div>

                    <button
                      id="session-traces-toggle"
                      type="button"
                      phx-click="toggle-traces"
                      class={[
                        "inline-flex h-8 items-center justify-center gap-1.5 rounded-lg border px-3 text-xs font-semibold",
                        @show_traces? &&
                          "border-purple-700 bg-purple-700 text-purple-50 hover:border-purple-600 hover:bg-purple-600",
                        not @show_traces? &&
                          "border-gray-300 bg-white text-gray-700 hover:border-gray-400 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:border-gray-500 dark:hover:bg-gray-800"
                      ]}
                    >
                      <.icon name="hero-information-circle-mini" class="size-4" />
                      <span>Traces</span>
                    </button>
                  </div>
                </div>

                <div
                  id="session-messages-wrapper"
                  phx-hook="AutoScrollMessages"
                  class="min-h-0 flex-1 overflow-y-auto bg-gray-50 px-4 py-4 dark:bg-gray-900/30 lg:px-6"
                >
                  <div
                    :if={@history_loading?}
                    id="session-history-loading"
                    class="mb-3 inline-flex items-center gap-2 rounded-lg border border-gray-200 bg-white px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400"
                  >
                    <span class="inline-block size-3.5 animate-spin rounded-full border-2 border-gray-300 border-t-purple-600 dark:border-gray-600 dark:border-t-purple-400">
                    </span>
                    <span>Loading history...</span>
                  </div>

                  <div
                    :if={@history_error}
                    id="session-history-error"
                    class="mb-3 rounded-lg border border-red-300 bg-red-50 px-3 py-2 text-xs text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
                  >
                    {@history_error}
                  </div>

                  <div
                    :if={@show_no_messages_state?}
                    id="session-messages-empty-state"
                    class="flex min-h-full items-center justify-center rounded-xl border-2 border-dashed border-gray-200 bg-gray-50 py-64 text-gray-400 dark:border-gray-700 dark:bg-gray-800"
                  >
                    No Messages
                  </div>

                  <div
                    :if={not @show_no_messages_state?}
                    id="session-messages"
                    class="space-y-3"
                  >
                    <div id="session-messages-stream" phx-update="stream" class="space-y-3">
                      <article
                        :for={{id, message} <- @streams.messages}
                        id={id}
                        class={[
                          "max-w-3xl rounded-lg border px-4 py-3 text-sm",
                          message.role == "user" &&
                            "ml-auto border-purple-200 bg-purple-50 text-gray-900 dark:border-purple-800/60 dark:bg-purple-900/30 dark:text-gray-100",
                          message.role != "user" &&
                            "mr-auto border-gray-200 bg-white text-gray-900 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
                        ]}
                      >
                        <div class="mb-1 flex items-center justify-between gap-3 text-[11px] text-gray-500 dark:text-gray-400">
                          <span class="font-semibold uppercase tracking-wide">{message.role}</span>
                          <span class="font-medium">
                            {message.timestamp_label || "time unavailable"}
                          </span>
                        </div>
                        <div class="whitespace-pre-wrap break-words">{message.text}</div>
                      </article>
                    </div>

                    <article
                      :if={
                        is_binary(@selected_session_key) and
                          (@assistant_pending? or @streaming_text)
                      }
                      id="session-streaming-message"
                      class="mr-auto max-w-3xl rounded-lg border border-gray-200 bg-white px-4 py-3 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
                    >
                      <div class="mb-1 flex items-center justify-between gap-3 text-[11px] text-gray-500 dark:text-gray-400">
                        <span class="font-semibold uppercase tracking-wide">assistant</span>
                        <span class="font-medium">streaming...</span>
                      </div>
                      <div class="whitespace-pre-wrap break-words">{@streaming_text}</div>
                      <div
                        :if={not (is_binary(@streaming_text) and @streaming_text != "")}
                        class="inline-flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400"
                      >
                        <span class="inline-block size-3.5 animate-spin rounded-full border-2 border-gray-300 border-t-purple-600 dark:border-gray-600 dark:border-t-purple-400">
                        </span>
                        <span>Assistant is thinking...</span>
                      </div>
                    </article>
                  </div>
                </div>

                <div class="border-t border-gray-200 px-4 py-4 dark:border-gray-700 lg:px-6">
                  <.form
                    for={@form}
                    id="chat-message-form"
                    phx-change="compose-message"
                    phx-submit="send-message"
                    class="flex items-center gap-3"
                  >
                    <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
                      <.input
                        field={@form[:message]}
                        id="chat-message-input"
                        type="text"
                        placeholder="Send a message to this session"
                        class="block h-10 w-full rounded-lg border border-gray-300 px-3 text-sm leading-5 text-gray-900 placeholder-gray-400 focus:border-purple-500 focus:ring-3 focus:ring-purple-500/50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100 dark:placeholder-gray-400"
                      />
                    </div>

                    <button
                      id="chat-send-button"
                      type="submit"
                      disabled={!@can_send_message?}
                      class={[
                        "inline-flex h-10 items-center justify-center rounded-lg border px-4 text-sm font-semibold",
                        @can_send_message? &&
                          "border-purple-700 bg-purple-700 text-purple-50 hover:border-purple-600 hover:bg-purple-600",
                        not @can_send_message? &&
                          "cursor-not-allowed border-gray-300 bg-gray-200 text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-500"
                      ]}
                    >
                      Send
                    </button>
                  </.form>

                  <p
                    :if={@send_error}
                    id="chat-send-error"
                    class="mt-2 text-xs text-red-600 dark:text-red-400"
                  >
                    {@send_error}
                  </p>
                </div>
              </section>
            </div>
          </main>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp normalize_session_selection(%{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    case SessionRoute.decode(session_id) do
      {:ok, session_key} -> {:ok, session_key}
      :error -> :invalid
    end
  end

  defp normalize_session_selection(_params), do: :none

  defp select_session(socket, session_key) when is_binary(session_key) do
    if socket.assigns.selected_session_key == session_key do
      socket
      |> ensure_session_subscription(session_key)
      |> notify_menu_selection(session_key)
    else
      pending_session_key =
        if socket.assigns.pending_session_key == session_key do
          session_key
        else
          nil
        end

      socket
      |> assign(:selected_session_key, session_key)
      |> assign(:send_error, nil)
      |> assign(:can_send_message?, false)
      |> assign(:history_messages, [])
      |> reset_streaming_state()
      |> assign(:pending_session_key, pending_session_key)
      |> assign(:queued_messages, [])
      |> assign(:form, to_form(%{"message" => ""}, as: :chat))
      |> stream(:messages, [], reset: true)
      |> ensure_session_subscription(session_key)
      |> request_history_load(session_key)
      |> notify_menu_selection(session_key)
    end
  end

  defp clear_session_selection(socket) do
    socket
    |> assign(:selected_session_key, nil)
    |> assign(:send_error, nil)
    |> assign(:can_send_message?, false)
    |> assign(:history_messages, [])
    |> assign(:history_request_id, nil)
    |> assign(:history_loading?, false)
    |> assign(:history_error, nil)
    |> reset_streaming_state()
    |> assign(:pending_session_key, nil)
    |> assign(:queued_messages, [])
    |> assign(:form, to_form(%{"message" => ""}, as: :chat))
    |> stream(:messages, [], reset: true)
    |> ensure_session_subscription(nil)
    |> sync_no_messages_state()
    |> notify_menu_selection(nil)
  end

  defp reject_session_selection(socket, message) do
    socket
    |> clear_session_selection()
    |> put_flash(:error, message)
    |> push_patch(to: ~p"/")
  end

  defp selectable_session?(socket, session_key) when is_binary(session_key) do
    cond do
      not SessionRoute.valid_session_key?(session_key) ->
        false

      socket.assigns.pending_session_key == session_key ->
        true

      not connected?(socket) ->
        true

      true ->
        case session_exists?(session_key) do
          true -> true
          false -> false
          :unknown -> true
        end
    end
  end

  defp selectable_session?(_socket, _session_key), do: false

  defp session_exists?(session_key) when is_binary(session_key) do
    case OpenClaw.sessions_list(%{"includeGlobal" => true, "includeUnknown" => true}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        Enum.any?(sessions, fn session -> session_key_value(session) == session_key end)

      _ ->
        :unknown
    end
  end

  defp notify_menu_selection(socket, session_key) do
    if is_pid(socket.assigns.menu_live_pid) do
      send(socket.assigns.menu_live_pid, {:menu_ui, :selected_session, session_key})
    end

    socket
  end

  defp session_path(session_key) when is_binary(session_key) do
    ~p"/session/#{SessionRoute.encode(session_key)}"
  end

  defp apply_history_result(socket, result) do
    socket = reset_streaming_state(socket)

    case result do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        normalized = normalize_history_messages(messages)
        visible = visible_messages(normalized, socket.assigns.show_traces?)

        socket
        |> assign(:history_loading?, false)
        |> assign(:history_error, nil)
        |> assign(:history_messages, normalized)
        |> stream(:messages, visible, reset: true)

      {:ok, _payload} ->
        socket
        |> assign(:history_loading?, false)
        |> assign(:history_error, "invalid chat.history payload")

      {:error, reason} ->
        socket
        |> assign(:history_loading?, false)
        |> assign(:history_error, format_reason(reason))
    end
    |> sync_no_messages_state()
  end

  defp request_history_load(socket, session_key) when is_binary(session_key) do
    request_id = System.unique_integer([:positive, :monotonic])
    send(self(), {:load_history, session_key, request_id})

    socket
    |> assign(:history_request_id, request_id)
    |> assign(:history_loading?, true)
    |> assign(:history_error, nil)
    |> sync_no_messages_state()
  end

  defp append_local_user_message(socket, message) do
    timestamp_ms = System.system_time(:millisecond)

    item = %{
      id: "local-#{System.unique_integer([:positive, :monotonic])}",
      role: "user",
      text: message,
      timestamp_label: format_timestamp_label(timestamp_ms),
      trace?: false
    }

    insert_history_message(socket, item)
  end

  defp apply_local_user_message(socket, payload) when is_map(payload) do
    session_key = map_string(payload, "sessionKey") || map_string(payload, :sessionKey)
    text = map_string(payload, "message") || map_string(payload, :message)
    run_id = map_string(payload, "runId") || map_string(payload, :runId)
    timestamp_ms = map_get(payload, "timestamp") || map_get(payload, :timestamp)

    cond do
      socket.assigns.selected_session_key != session_key ->
        socket

      not is_binary(text) ->
        socket

      true ->
        message_id =
          if is_binary(run_id) do
            "local-user-#{run_id}"
          else
            "local-user-#{System.unique_integer([:positive, :monotonic])}"
          end

        upsert_history_message(socket, %{
          id: message_id,
          role: "user",
          text: text,
          timestamp_label: format_timestamp_label(timestamp_ms),
          trace?: false
        })
    end
  end

  defp apply_local_user_message(socket, _payload), do: socket

  defp apply_chat_event(socket, payload) when is_map(payload) do
    session_key = map_string(payload, "sessionKey") || map_string(payload, :sessionKey)

    if socket.assigns.selected_session_key == session_key do
      state_value = map_string(payload, "state") || map_string(payload, :state) || ""
      run_id = map_string(payload, "runId") || map_string(payload, :runId)
      tracked_run_id = socket.assigns.streaming_run_id

      run_mismatch? =
        is_binary(run_id) and is_binary(tracked_run_id) and run_id != tracked_run_id

      if run_mismatch? do
        case state_value do
          value when value in ["final", "aborted", "error"] ->
            socket
            |> reset_streaming_state()
            |> request_history_load(session_key)

          _ ->
            socket
        end
      else
        case state_value do
          "delta" ->
            text = payload |> map_get("message") |> Message.extract_text()

            socket =
              socket
              |> assign(:assistant_pending?, true)
              |> assign(:streaming_run_id, run_id || tracked_run_id)

            if is_binary(text) and text != "" do
              current_text = socket.assigns.streaming_text || ""

              next_text =
                if current_text == "" or String.length(text) >= String.length(current_text) do
                  text
                else
                  current_text
                end

              assign(socket, :streaming_text, next_text)
            else
              socket
            end

          "final" ->
            final_text = payload |> map_get("message") |> Message.extract_text()

            socket =
              socket
              |> assign(:assistant_pending?, true)
              |> assign(:streaming_run_id, run_id || tracked_run_id)

            socket =
              if is_binary(final_text) and final_text != "" do
                assign(socket, :streaming_text, final_text)
              else
                socket
              end

            request_history_load(socket, session_key)

          "aborted" ->
            socket
            |> reset_streaming_state()
            |> request_history_load(session_key)

          "error" ->
            socket
            |> reset_streaming_state()
            |> assign(:send_error, map_string(payload, "errorMessage") || "chat error")
            |> request_history_load(session_key)

          _ ->
            socket
        end
      end
    else
      socket
    end
  end

  defp apply_chat_event(socket, _payload), do: socket

  defp insert_history_message(socket, message) when is_map(message) do
    socket = update(socket, :history_messages, fn messages -> messages ++ [message] end)

    if socket.assigns.show_traces? or not Map.get(message, :trace?, false) do
      stream_insert(socket, :messages, message)
    else
      socket
    end
    |> sync_no_messages_state()
  end

  defp apply_agent_event(socket, payload) when is_map(payload) do
    session_key = map_string(payload, "sessionKey") || map_string(payload, :sessionKey)
    stream = map_string(payload, "stream") || map_string(payload, :stream)
    run_id = map_string(payload, "runId") || map_string(payload, :runId)

    if socket.assigns.selected_session_key != session_key do
      socket
    else
      case stream do
        "assistant" ->
          socket
          |> assign(:assistant_pending?, true)
          |> assign(:streaming_run_id, run_id || socket.assigns.streaming_run_id)

        "lifecycle" ->
          data = map_get(payload, "data") || map_get(payload, :data)

          phase =
            if is_map(data) do
              map_string(data, "phase") || map_string(data, :phase)
            else
              nil
            end

          tracked_run_id = socket.assigns.streaming_run_id

          cond do
            phase in ["start", "prepare"] ->
              socket
              |> assign(:assistant_pending?, true)
              |> assign(:streaming_run_id, run_id || tracked_run_id)

            phase in ["end", "error"] and (is_nil(tracked_run_id) or tracked_run_id == run_id) ->
              reset_streaming_state(socket)

            true ->
              socket
          end

        "tool" ->
          socket =
            socket
            |> assign(:assistant_pending?, true)
            |> assign(:streaming_run_id, run_id || socket.assigns.streaming_run_id)

          case build_tool_trace_message(payload) do
            nil -> socket
            message -> upsert_history_message(socket, message)
          end

        "compaction" ->
          socket

        _ ->
          socket
      end
    end
  end

  defp apply_agent_event(socket, _payload), do: socket

  defp pending_session?(socket, session_key) do
    is_binary(session_key) and socket.assigns.pending_session_key == session_key
  end

  defp validate_selected_session_for_send(session_key) when is_binary(session_key) do
    cond do
      not SessionRoute.valid_session_key?(session_key) ->
        {:error, "Cannot send: invalid session key"}

      true ->
        case OpenClaw.sessions_list(%{"includeGlobal" => true, "includeUnknown" => true}) do
          {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
            if Enum.any?(sessions, fn session -> session_key_value(session) == session_key end) do
              :ok
            else
              {:error, "Cannot send: session does not exist"}
            end

          _ ->
            {:error, "Cannot verify session before sending"}
        end
    end
  end

  defp validate_selected_session_for_send(_session_key),
    do: {:error, "Cannot send without a session"}

  defp initialize_new_session(socket, new_session_key) when is_binary(new_session_key) do
    socket
    |> assign(:selected_session_key, new_session_key)
    |> assign(:pending_session_key, new_session_key)
    |> assign(:send_error, nil)
    |> assign(:history_error, nil)
    |> assign(:history_loading?, false)
    |> assign(:history_request_id, nil)
    |> reset_streaming_state()
    |> assign(:can_send_message?, false)
    |> assign(:history_messages, [])
    |> assign(:queued_messages, [])
    |> assign(:form, to_form(%{"message" => ""}, as: :chat))
    |> stream(:messages, [], reset: true)
    |> sync_no_messages_state()
  end

  defp ensure_session_subscription(socket, session_key) when is_binary(session_key) do
    previous_session_key = socket.assigns.subscribed_session_key

    cond do
      previous_session_key == session_key ->
        socket

      is_binary(previous_session_key) ->
        OpenClaw.unsubscribe_session(previous_session_key)
        OpenClaw.subscribe_session(session_key)
        assign(socket, :subscribed_session_key, session_key)

      true ->
        OpenClaw.subscribe_session(session_key)
        assign(socket, :subscribed_session_key, session_key)
    end
  end

  defp ensure_session_subscription(socket, _session_key) do
    previous_session_key = socket.assigns.subscribed_session_key

    if is_binary(previous_session_key) do
      OpenClaw.unsubscribe_session(previous_session_key)
      assign(socket, :subscribed_session_key, nil)
    else
      socket
    end
  end

  defp clear_compose(socket) do
    socket
    |> assign(:can_send_message?, false)
    |> assign(:form, to_form(%{"message" => ""}, as: :chat))
    |> push_event("chat-input-clear", %{input_id: "chat-message-input"})
  end

  defp reset_streaming_state(socket) do
    socket
    |> assign(:assistant_pending?, false)
    |> assign(:streaming_text, nil)
    |> assign(:streaming_run_id, nil)
  end

  defp upsert_history_message(socket, message) when is_map(message) do
    message_id = Map.get(message, :id)

    case Enum.find_index(socket.assigns.history_messages, &(&1.id == message_id)) do
      nil ->
        insert_history_message(socket, message)

      index ->
        updated_messages = List.replace_at(socket.assigns.history_messages, index, message)
        socket = assign(socket, :history_messages, updated_messages)

        if socket.assigns.show_traces? or not Map.get(message, :trace?, false) do
          stream_insert(socket, :messages, message)
        else
          socket
        end
        |> sync_no_messages_state()
    end
  end

  defp build_tool_trace_message(payload) when is_map(payload) do
    data = map_get(payload, "data") || map_get(payload, :data)

    if is_map(data) do
      run_id = map_string(payload, "runId") || map_string(payload, :runId) || "run"
      sequence = map_get(payload, "seq") || map_get(payload, :seq) || "seq"
      tool_call_id = map_string(data, "toolCallId") || map_string(data, :toolCallId)
      phase = map_string(data, "phase") || map_string(data, :phase) || "update"
      name = map_string(data, "name") || map_string(data, :name) || "(unnamed tool)"
      args = map_get(data, "args") || map_get(data, :args)
      result = map_get(data, "result") || map_get(data, :result)
      partial_result = map_get(data, "partialResult") || map_get(data, :partialResult)
      error = map_get(data, "error") || map_get(data, :error)

      text =
        build_tool_trace_text(%{
          name: name,
          phase: phase,
          args: args,
          result: result,
          partial_result: partial_result,
          error: error
        })

      if is_binary(text) and String.trim(text) != "" do
        id =
          if is_binary(tool_call_id) and tool_call_id != "" do
            "tool-stream-#{run_id}-#{tool_call_id}"
          else
            "tool-stream-#{run_id}-#{sequence}"
          end

        %{
          id: id,
          role: "toolresult",
          text: text,
          timestamp_label: format_timestamp_label(Message.timestamp_ms(payload)),
          trace?: true
        }
      else
        nil
      end
    else
      nil
    end
  end

  defp build_tool_trace_text(%{
         name: name,
         phase: phase,
         args: args,
         result: result,
         partial_result: partial_result,
         error: error
       }) do
    output =
      cond do
        phase == "result" -> result
        phase == "update" -> partial_result || result
        true -> nil
      end

    sections = [
      "---",
      "name: #{name}",
      "phase: #{phase}",
      format_trace_section("args", args),
      format_trace_section("output", output),
      format_trace_section("error", error)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> truncate_trace_text(@tool_trace_text_limit)
  end

  defp format_trace_section(_label, nil), do: nil

  defp format_trace_section(label, value) do
    rendered = format_trace_value(value)

    if rendered == "" do
      nil
    else
      "#{label}:\n#{rendered}"
    end
  end

  defp format_trace_value(value) when is_binary(value), do: String.trim(value)
  defp format_trace_value(value) when is_boolean(value), do: to_string(value)
  defp format_trace_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_trace_value(value) when is_float(value), do: :erlang.float_to_binary(value)

  defp format_trace_value(value) when is_list(value) or is_map(value) do
    maybe_text =
      if is_map(value) do
        Message.extract_text(value)
      else
        nil
      end

    cond do
      is_binary(maybe_text) and String.trim(maybe_text) != "" ->
        String.trim(maybe_text)

      true ->
        case Jason.encode(value, pretty: true) do
          {:ok, json} -> json
          _ -> inspect(value)
        end
    end
  end

  defp format_trace_value(value), do: inspect(value)

  defp truncate_trace_text(text, limit)
       when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "\n\n... truncated ..."
    end
  end

  defp enqueue_session_creation(session_key) when is_binary(session_key) do
    liveview_pid = self()

    Task.start(fn ->
      result = OpenClaw.sessions_patch(session_key)
      send(liveview_pid, {:new_session_created, session_key, result})
    end)
  end

  defp flush_queued_messages(socket, session_key) when is_binary(session_key) do
    messages = socket.assigns.queued_messages

    {sent_messages, error_reason} =
      Enum.reduce_while(messages, {[], nil}, fn message, {sent, _error} ->
        case OpenClaw.chat_send(session_key, message) do
          {:ok, _payload} ->
            {:cont, {[message | sent], nil}}

          {:error, reason} ->
            {:halt, {Enum.reverse(sent), reason}}
        end
      end)

    remaining_messages = Enum.drop(messages, length(sent_messages))
    socket = assign(socket, :queued_messages, remaining_messages)

    if is_nil(error_reason),
      do: socket,
      else: assign(socket, :send_error, format_reason(error_reason))
  end

  defp session_subtitle(nil, _loading?, _error, _pending_session_key),
    do: "Pick a session from the menu to inspect history."

  defp session_subtitle(session_key, _loading?, _error, pending_session_key)
       when is_binary(session_key) and session_key == pending_session_key do
    "Preparing new session..."
  end

  defp session_subtitle(_session_key, true, _error, _pending_session_key),
    do: "Loading session history..."

  defp session_subtitle(_session_key, _loading?, error, _pending_session_key)
       when is_binary(error),
       do: error

  defp session_subtitle(session_key, _loading?, _error, _pending_session_key) do
    "Streaming updates for #{session_key}"
  end

  defp format_reason(%{"message" => message}) when is_binary(message), do: message
  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason), do: inspect(reason)

  defp format_timestamp_label(nil), do: "time unavailable"

  defp format_timestamp_label(timestamp_ms) when not is_integer(timestamp_ms),
    do: "time unavailable"

  defp format_timestamp_label(timestamp_ms) when timestamp_ms <= 0 do
    "time unavailable"
  end

  defp format_timestamp_label(timestamp_ms) do
    case DateTime.from_unix(timestamp_ms, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "time unavailable"
    end
  end

  defp message_hash(message) do
    message
    |> :erlang.phash2()
    |> Integer.to_string()
  end

  defp normalize_history_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {message, index} ->
      normalize_history_message(message, "history-#{index}")
    end)
  end

  defp normalize_history_message(message, id_prefix) when is_map(message) do
    timestamp_ms = Message.timestamp_ms(message)
    role = Message.role(message)
    text = Message.preview_text(message)

    %{
      id: "#{id_prefix}-#{message_hash(message)}",
      role: role,
      text: text,
      timestamp_label: format_timestamp_label(timestamp_ms),
      trace?: trace_message?(message, role)
    }
  end

  defp visible_messages(messages, show_traces?) when is_list(messages) do
    Enum.filter(messages, fn message -> show_traces? or not message.trace? end)
  end

  defp show_no_messages_state?(
         history_loading?,
         history_error,
         history_messages,
         assistant_pending?,
         streaming_text
       )
       when is_boolean(history_loading?) and is_list(history_messages) do
    not history_loading? and
      is_nil(history_error) and
      history_messages == [] and
      not assistant_pending? and
      not (is_binary(streaming_text) and streaming_text != "")
  end

  defp initial_show_traces_preference(socket) do
    if connected?(socket) do
      socket
      |> get_connect_params()
      |> parse_show_traces_preference()
    else
      false
    end
  end

  defp parse_show_traces_preference(%{"show_traces" => value})
       when value in [true, "true", "1"],
       do: true

  defp parse_show_traces_preference(_params), do: false

  defp sync_no_messages_state(socket) do
    assign(
      socket,
      :show_no_messages_state?,
      show_no_messages_state?(
        socket.assigns.history_loading?,
        socket.assigns.history_error,
        socket.assigns.history_messages,
        socket.assigns.assistant_pending?,
        socket.assigns.streaming_text
      )
    )
  end

  defp trace_message?(message, role) when is_map(message) do
    normalized_role = String.downcase(role)
    content = map_get(message, "content") || map_get(message, :content)
    visible_text = Message.extract_text(message)
    has_visible_text = is_binary(visible_text) and String.trim(visible_text) != ""
    has_trace_content = contains_trace_content?(content)

    normalized_role in ["tool", "toolresult", "tool_result", "function"] or
      (has_trace_content and not has_visible_text)
  end

  defp trace_message?(_message, _role), do: false

  defp contains_trace_content?(content) when is_list(content) do
    Enum.any?(content, fn item ->
      if is_map(item) do
        case map_string(item, "type") || map_string(item, :type) do
          value when is_binary(value) ->
            String.downcase(value) in [
              "thinking",
              "toolcall",
              "tool_call",
              "toolresult",
              "tool_result"
            ]

          _ ->
            false
        end
      else
        false
      end
    end)
  end

  defp contains_trace_content?(_), do: false

  defp build_new_session_key(nil) do
    unique_suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    "agent:main:session-#{unique_suffix}"
  end

  defp build_new_session_key(current_session_key) when is_binary(current_session_key) do
    unique_suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    case String.split(current_session_key, ":", parts: 3) do
      ["agent", agent_id, tail] ->
        base_slug =
          tail
          |> String.split(":", trim: true)
          |> List.last()
          |> normalize_session_slug()

        "agent:#{agent_id}:#{base_slug}-#{unique_suffix}"

      _ ->
        "agent:main:session-#{unique_suffix}"
    end
  end

  defp normalize_session_slug(nil), do: "session"

  defp normalize_session_slug(value) when is_binary(value) do
    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/u, "-")
      |> String.trim("-_")

    if slug == "", do: "session", else: slug
  end

  defp map_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp stale_history_response?(socket, session_key, request_id) do
    socket.assigns.selected_session_key != session_key or
      socket.assigns.history_request_id != request_id
  end

  defp session_key_value(session) when is_map(session) do
    map_string(session, "key") || map_string(session, :key)
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
end
