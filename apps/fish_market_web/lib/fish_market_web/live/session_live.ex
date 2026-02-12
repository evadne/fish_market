defmodule FishMarketWeb.SessionLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw
  alias FishMarket.OpenClaw.Message
  alias FishMarketWeb.SessionRoute

  @history_limit 200
  @menu_refresh_states MapSet.new(["final", "aborted", "error"])
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
      |> assign(:selected_session_key, selected_session_key)
      |> assign(:sessions, [])
      |> assign(:sessions_loading?, false)
      |> assign(:sessions_error, nil)
      |> assign(:unread_session_keys, MapSet.new())
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
      |> assign(:streaming_thinking_text, nil)
      |> assign(:streaming_run_id, nil)
      |> assign(:pending_session_key, nil)
      |> assign(:queued_messages, [])
      |> assign(:form, to_form(%{"message" => ""}, as: :chat))
      |> stream(:messages, [])
      |> sync_no_messages_state()

    socket =
      if connected?(socket) do
        OpenClaw.subscribe_gateway()
        OpenClaw.subscribe_chat()
        OpenClaw.subscribe_event("agent")
        send(self(), :load_menu_sessions)

        if is_binary(selected_session_key) do
          request_history_load(socket, selected_session_key)
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
        maybe_select_first_session(socket)
        |> (&{:noreply, &1}).()

      :invalid ->
        reject_session_selection(socket, "Invalid session URL")
        |> (&{:noreply, &1}).()

      {:ok, session_key} ->
        if selectable_session?(socket, session_key) do
          select_session(socket, session_key)
        else
          reject_session_selection(socket, "Session not found")
        end
        |> (&{:noreply, &1}).()
    end
  end

  @impl true
  def handle_event("compose-message", %{"chat" => %{"message" => raw_message}}, socket) do
    can_send_message? = String.trim(raw_message) != ""

    socket
    |> assign(:can_send_message?, can_send_message?)
    |> assign(:form, to_form(%{"message" => raw_message}, as: :chat))
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_event("send-message", %{"chat" => %{"message" => raw_message}}, socket) do
    message = String.trim(raw_message)

    cond do
      message == "" ->
        socket
        |> assign(:can_send_message?, false)
        |> (&{:noreply, &1}).()

      is_nil(socket.assigns.selected_session_key) ->
        new_session_key = build_new_session_key(nil)
        enqueue_session_creation(new_session_key)

        socket
        |> initialize_new_session(new_session_key)
        |> append_local_user_message(message)
        |> update(:queued_messages, fn messages -> messages ++ [message] end)
        |> clear_compose()
        |> assign(:send_error, nil)
        |> push_patch(to: session_path(new_session_key))
        |> (&{:noreply, &1}).()

      true ->
        selected_session_key = socket.assigns.selected_session_key

        if pending_session?(socket, selected_session_key) do
          socket
          |> append_local_user_message(message)
          |> update(:queued_messages, fn messages -> messages ++ [message] end)
          |> clear_compose()
          |> assign(:send_error, nil)
          |> (&{:noreply, &1}).()
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

                  socket
                  |> clear_compose()
                  |> assign(:send_error, nil)
                  |> (&{:noreply, &1}).()

                {:error, reason} ->
                  socket
                  |> assign(:send_error, format_reason(reason))
                  |> (&{:noreply, &1}).()
              end

            {:error, reason} ->
              socket
              |> assign(:send_error, reason)
              |> (&{:noreply, &1}).()
          end
        end
    end
  end

  @impl true
  def handle_event("new-session", _params, socket) do
    new_session_key = build_new_session_key(socket.assigns.selected_session_key)
    enqueue_session_creation(new_session_key)

    socket
    |> initialize_new_session(new_session_key)
    |> push_event("chat-input-focus", %{input_id: "chat-message-input"})
    |> push_patch(to: session_path(new_session_key))
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_event("toggle-traces", _params, socket) do
    show_traces? = not socket.assigns.show_traces?
    visible_messages = visible_messages(socket.assigns.history_messages, show_traces?)
    selected_session_key = socket.assigns.selected_session_key

    socket
    |> assign(:show_traces?, show_traces?)
    |> stream(:messages, visible_messages, reset: true)
    |> sync_no_messages_state()
    |> push_event("set-show-traces", %{enabled: show_traces?})
    |> ensure_session_verbose_for_traces(show_traces?, selected_session_key)
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_event("menu-select-session", %{"session_key" => session_key}, socket)
      when is_binary(session_key) and session_key != "" do
    select_session(socket, session_key)
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info(:load_menu_sessions, socket) do
    load_menu_sessions(socket)
    |> (&{:noreply, &1}).()
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
      socket
    else
      apply_history_result(socket, result)
    end
    |> (&{:noreply, &1}).()
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

    socket
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_gateway, :connected, _payload}, socket) do
    selected_session_key = socket.assigns.selected_session_key

    socket =
      if is_binary(selected_session_key) do
        socket
        |> flush_queued_messages(selected_session_key)
        |> request_history_load(selected_session_key)
      else
        maybe_select_first_session(socket)
      end

    maybe_schedule_menu_refresh(socket)
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_gateway, :disconnected, _payload}, socket) do
    socket
    |> assign(:history_error, "Gateway disconnected")
    |> assign(:sessions_error, "Gateway disconnected")
    |> sync_no_messages_state()
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_local_user_message, payload}, socket) do
    socket
    |> apply_local_user_message(payload)
    |> sync_no_messages_state()
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_event, "chat", payload}, socket) do
    socket
    |> apply_menu_chat_event(payload)
    |> apply_chat_event(payload)
    |> sync_no_messages_state()
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_event, "agent", payload}, socket) do
    socket
    |> apply_agent_event(payload)
    |> sync_no_messages_state()
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_event, _event, _payload}, socket) do
    {:noreply, socket}
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
      clear_unread_for_selected_session(socket, session_key)
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
      |> clear_unread_for_selected_session(session_key)
      |> assign(:pending_session_key, pending_session_key)
      |> assign(:queued_messages, [])
      |> assign(:form, to_form(%{"message" => ""}, as: :chat))
      |> stream(:messages, [], reset: true)
      |> ensure_session_verbose_for_traces(socket.assigns.show_traces?, session_key)
      |> request_history_load(session_key)
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
    |> sync_no_messages_state()
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

  defp session_path(session_key) when is_binary(session_key) do
    ~p"/session/#{SessionRoute.encode(session_key)}"
  end

  defp maybe_select_first_session(socket) do
    cond do
      not connected?(socket) ->
        clear_session_selection(socket)

      true ->
        case first_available_session_key(socket) do
          {:ok, session_key} ->
            push_patch(socket, to: session_path(session_key))

          :none ->
            clear_session_selection(socket)
        end
    end
  end

  defp first_available_session_key(socket) do
    case Enum.find_value(socket.assigns.sessions, &session_key_value/1) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        fetch_first_available_session_key()
    end
  end

  defp fetch_first_available_session_key do
    case OpenClaw.sessions_list(%{"includeGlobal" => true, "includeUnknown" => true}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        sessions
        |> Enum.sort_by(&session_updated_at/1, :desc)
        |> Enum.find_value(&session_key_value/1)
        |> case do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp session_updated_at(%{"updatedAt" => value}), do: normalize_unix_timestamp(value)

  defp session_updated_at(_session), do: 0

  defp normalize_unix_timestamp(value) when is_integer(value) and value > 0 do
    if value < 10_000_000_000 do
      value * 1000
    else
      value
    end
  end

  defp normalize_unix_timestamp(_), do: nil

  defp load_menu_sessions(socket) do
    socket = assign(socket, :sessions_loading?, true)

    case OpenClaw.sessions_list(%{"includeGlobal" => true, "includeUnknown" => true}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        sessions = Enum.sort_by(sessions, &session_updated_at/1, :desc)
        previous_selected = socket.assigns.selected_session_key
        next_selected = resolve_selected_session_key(sessions, previous_selected)

        socket =
          socket
          |> assign(:sessions, sessions)
          |> assign(:sessions_loading?, false)
          |> assign(:sessions_error, nil)
          |> assign(:selected_session_key, next_selected)
          |> clear_unread_for_selected_session(next_selected)
          |> ensure_session_placeholder(next_selected)
          |> prune_unread_sessions(sessions)

        if is_nil(next_selected) do
          maybe_select_first_session(socket)
        else
          socket
        end

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

  defp maybe_schedule_menu_refresh(socket) do
    if socket.assigns.sessions_loading? do
      socket
    else
      send(self(), :load_menu_sessions)
      socket
    end
  end

  defp apply_menu_chat_event(socket, payload) when is_map(payload) do
    session_key = map_string(payload, "sessionKey")

    if is_binary(session_key) do
      socket =
        if socket.assigns.selected_session_key == session_key do
          clear_unread_for_selected_session(socket, session_key)
        else
          update(socket, :unread_session_keys, &MapSet.put(&1, session_key))
        end

      state_value = map_string(payload, "state") || ""
      session_missing? = not has_session_key?(socket.assigns.sessions, session_key)

      if session_missing? or MapSet.member?(@menu_refresh_states, state_value) do
        maybe_schedule_menu_refresh(socket)
      else
        socket
      end
    else
      socket
    end
  end

  defp apply_menu_chat_event(socket, _payload), do: socket

  defp clear_unread_for_selected_session(socket, session_key) when is_binary(session_key) do
    update(socket, :unread_session_keys, &MapSet.delete(&1, session_key))
  end

  defp clear_unread_for_selected_session(socket, _session_key), do: socket

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
      |> Enum.map(&session_key_value/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    assign(
      socket,
      :unread_session_keys,
      MapSet.intersection(socket.assigns.unread_session_keys, valid_keys)
    )
  end

  defp has_session_key?(sessions, key) when is_binary(key) do
    Enum.any?(sessions, fn session -> session_key_value(session) == key end)
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
    session_key = map_string(payload, "sessionKey")
    text = map_string(payload, "message")
    run_id = map_string(payload, "runId")
    timestamp_ms = map_get(payload, "timestamp")

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
    session_key = map_string(payload, "sessionKey")

    if socket.assigns.selected_session_key == session_key do
      state_value = map_string(payload, "state") || ""
      run_id = map_string(payload, "runId")
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
            message = map_get(payload, "message")
            text = Message.extract_text(message)
            thinking_text = extract_message_thinking_text(message)

            socket
            |> assign(:assistant_pending?, true)
            |> assign(:streaming_run_id, run_id || tracked_run_id)
            |> maybe_assign_streaming_content(:streaming_text, text)
            |> maybe_assign_streaming_content(:streaming_thinking_text, thinking_text)

          "final" ->
            message = map_get(payload, "message")
            final_text = Message.extract_text(message)
            thinking_text = extract_message_thinking_text(message)

            socket =
              socket
              |> assign(:assistant_pending?, true)
              |> assign(:streaming_run_id, run_id || tracked_run_id)
              |> maybe_assign_streaming_content(:streaming_text, final_text)
              |> maybe_assign_streaming_content(:streaming_thinking_text, thinking_text)

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
    session_key = map_string(payload, "sessionKey")
    stream = map_string(payload, "stream")
    run_id = map_string(payload, "runId")

    if socket.assigns.selected_session_key != session_key do
      socket
    else
      case stream do
        "assistant" ->
          socket
          |> assign(:assistant_pending?, true)
          |> assign(:streaming_run_id, run_id || socket.assigns.streaming_run_id)
          |> maybe_assign_streaming_thinking(payload, run_id, stream)

        "lifecycle" ->
          data = map_get(payload, "data")

          phase =
            if is_map(data) do
              map_string(data, "phase")
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

        "thinking" ->
          maybe_assign_streaming_thinking(socket, payload, run_id, stream)

        "reasoning" ->
          maybe_assign_streaming_thinking(socket, payload, run_id, stream)

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
    |> assign(:streaming_thinking_text, nil)
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
    data = map_get(payload, "data")

    if is_map(data) do
      run_id = map_string(payload, "runId") || "run"
      sequence = map_get(payload, "seq") || "seq"
      tool_call_id = map_string(data, "toolCallId")
      phase = map_string(data, "phase") || "update"
      name = map_string(data, "name") || "(unnamed tool)"
      args = map_get(data, "args")
      result = map_get(data, "result")
      partial_result = map_get(data, "partialResult")
      error = map_get(data, "error")

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

  defp render_message_text(text) when is_binary(text) do
    text
    |> normalize_line_endings()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br>")
    |> Phoenix.HTML.raw()
  end

  defp render_message_text(_text), do: ""

  defp normalize_line_endings(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

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
    |> Enum.flat_map(fn {message, index} ->
      normalize_history_message_bundle(message, "history-#{index}")
    end)
  end

  defp normalize_history_message_bundle(message, id_prefix) when is_map(message) do
    build_thinking_trace_messages(message, id_prefix) ++
      [normalize_history_message(message, id_prefix)]
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

  defp build_thinking_trace_messages(message, id_prefix) when is_map(message) do
    timestamp_label = format_timestamp_label(Message.timestamp_ms(message))
    content = map_get(message, "content")

    if is_list(content) do
      content
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {part, index} ->
        case extract_thinking_text(part) do
          nil ->
            []

          thinking_text ->
            [
              %{
                id: "#{id_prefix}-thinking-#{index}-#{message_hash(part)}",
                role: "thinking",
                text: truncate_trace_text(thinking_text, @tool_trace_text_limit),
                timestamp_label: timestamp_label,
                trace?: true
              }
            ]
        end
      end)
    else
      []
    end
  end

  defp build_thinking_trace_messages(_message, _id_prefix), do: []

  defp extract_thinking_text(part) when is_map(part) do
    type = map_string(part, "type")

    if is_binary(type) and String.downcase(type) == "thinking" do
      map_string(part, "thinking") || map_string(part, "text")
    else
      nil
    end
  end

  defp extract_thinking_text(_part), do: nil

  defp extract_message_thinking_text(message) when is_map(message) do
    content = map_get(message, "content")

    if is_list(content) do
      content
      |> Enum.map(&extract_thinking_text/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end
    else
      nil
    end
  end

  defp extract_message_thinking_text(_message), do: nil

  defp maybe_assign_streaming_thinking(socket, payload, run_id, stream)
       when is_map(payload) and is_binary(stream) do
    case extract_streaming_thinking_update(payload, stream) do
      {:append, text} ->
        socket
        |> assign(:assistant_pending?, true)
        |> assign(:streaming_run_id, run_id || socket.assigns.streaming_run_id)
        |> append_streaming_content(:streaming_thinking_text, text)

      {:merge, text} ->
        socket
        |> assign(:assistant_pending?, true)
        |> assign(:streaming_run_id, run_id || socket.assigns.streaming_run_id)
        |> maybe_assign_streaming_content(:streaming_thinking_text, text)

      _ ->
        socket
    end
  end

  defp maybe_assign_streaming_thinking(socket, _payload, _run_id, _stream), do: socket

  defp extract_streaming_thinking_update(payload, stream)
       when is_map(payload) and is_binary(stream) do
    data = map_get(payload, "data")
    message = map_get(payload, "message")

    cond do
      stream in ["thinking", "reasoning"] ->
        extract_streaming_thinking_update_from_data(data, true) ||
          wrap_streaming_update(:merge, extract_message_thinking_text(message))

      stream == "assistant" ->
        extract_streaming_thinking_update_from_data(data, false) ||
          wrap_streaming_update(:merge, extract_message_thinking_text(message))

      true ->
        nil
    end
  end

  defp extract_streaming_thinking_update(_payload, _stream), do: nil

  defp extract_streaming_thinking_update_from_data(data, allow_text_fallback?)
       when is_map(data) and is_boolean(allow_text_fallback?) do
    wrap_streaming_update(
      :append,
      map_string(data, "thinkingDelta") || map_string(data, "reasoningDelta")
    ) ||
      wrap_streaming_update(:merge, map_string(data, "thinking") || map_string(data, "reasoning")) ||
      wrap_streaming_update(:merge, map_get(data, "message") |> extract_message_thinking_text()) ||
      wrap_streaming_update(
        :merge,
        map_get(data, "content")
        |> case do
          content when is_list(content) ->
            extract_message_thinking_text(%{"content" => content})

          _ ->
            nil
        end
      ) ||
      if(allow_text_fallback?,
        do: wrap_streaming_update(:append, map_string(data, "delta")),
        else: nil
      ) ||
      if(allow_text_fallback?,
        do: wrap_streaming_update(:append, map_string(data, "text")),
        else: nil
      )
  end

  defp extract_streaming_thinking_update_from_data(_data, _allow_text_fallback?), do: nil

  defp wrap_streaming_update(mode, text)
       when mode in [:append, :merge] and is_binary(text) and text != "",
       do: {mode, text}

  defp wrap_streaming_update(_mode, _text), do: nil

  defp append_streaming_content(socket, key, text)
       when is_atom(key) and is_binary(text) and text != "" do
    current_text = Map.get(socket.assigns, key)
    current = if is_binary(current_text), do: current_text, else: ""
    incoming = normalize_line_endings(text)

    if incoming == "" do
      socket
    else
      assign(socket, key, current <> incoming)
    end
  end

  defp append_streaming_content(socket, _key, _text), do: socket

  defp maybe_assign_streaming_content(socket, key, text)
       when is_atom(key) and is_binary(text) and text != "" do
    current_text = Map.get(socket.assigns, key)
    next_text = merge_streaming_content(current_text, text)

    if next_text == current_text or next_text == "" do
      socket
    else
      assign(socket, key, next_text)
    end
  end

  defp maybe_assign_streaming_content(socket, _key, _text), do: socket

  defp merge_streaming_content(current_text, incoming_text) when is_binary(incoming_text) do
    incoming = normalize_line_endings(incoming_text)
    current = if is_binary(current_text), do: current_text, else: ""

    cond do
      incoming == "" -> current
      current == "" -> incoming
      String.starts_with?(incoming, current) -> incoming
      String.starts_with?(current, incoming) -> current
      String.ends_with?(current, incoming) -> current
      true -> current <> incoming
    end
  end

  defp visible_messages(messages, show_traces?) when is_list(messages) do
    Enum.filter(messages, fn message -> show_traces? or not message.trace? end)
  end

  defp show_no_messages_state?(
         history_loading?,
         history_error,
         history_messages,
         assistant_pending?,
         streaming_text,
         streaming_thinking_text
       )
       when is_boolean(history_loading?) and is_list(history_messages) do
    not history_loading? and
      is_nil(history_error) and
      history_messages == [] and
      not assistant_pending? and
      not (is_binary(streaming_text) and streaming_text != "") and
      not (is_binary(streaming_thinking_text) and streaming_thinking_text != "")
  end

  defp ensure_session_verbose_for_traces(socket, show_traces?, session_key)
       when is_boolean(show_traces?) and is_binary(session_key) and session_key != "" do
    if show_traces? do
      Task.start(fn ->
        _ = OpenClaw.sessions_patch(session_key, %{"verboseLevel" => "on"})
      end)
    end

    socket
  end

  defp ensure_session_verbose_for_traces(socket, _show_traces?, _session_key), do: socket

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
        socket.assigns.streaming_text,
        socket.assigns.streaming_thinking_text
      )
    )
  end

  defp trace_message?(message, role) when is_map(message) do
    normalized_role = String.downcase(role)
    content = map_get(message, "content")
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
        case map_string(item, "type") do
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
    map_string(session, "key")
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
end
