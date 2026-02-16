defmodule FishMarketWeb.SessionLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw
  alias FishMarket.OpenClaw.Message
  alias FishMarketWeb.SessionRoute

  @history_limit 200
  @menu_refresh_states MapSet.new(["final", "aborted", "error"])
  @tool_trace_text_limit 12_000
  @think_levels ["", "off", "minimal", "low", "medium", "high"]
  @binary_think_levels ["", "off", "on"]
  @verbose_level_options [
    {"inherit", ""},
    {"off (explicit)", "off"},
    {"on", "on"},
    {"full", "full"}
  ]
  # NOTE: Temporary compatibility shim.
  # OpenClaw gateway `models.list` currently does not expose per-model thinking-level capabilities.
  # `sessions.patch` enforces xhigh support server-side, so we mirror known xhigh-capable refs here
  # to avoid presenting invalid options in the UI.
  # TODO: Remove this hardcoded list once `models.list` exposes capabilities (e.g. thinkingLevels/supportsXHigh).
  @xhigh_model_refs MapSet.new([
                      "openai/gpt-5.2",
                      "openai-codex/gpt-5.3-codex",
                      "openai-codex/gpt-5.2-codex",
                      "openai-codex/gpt-5.1-codex",
                      "github-copilot/gpt-5.2-codex",
                      "github-copilot/gpt-5.2"
                    ])
  @xhigh_model_ids MapSet.new([
                     "gpt-5.2",
                     "gpt-5.3-codex",
                     "gpt-5.2-codex",
                     "gpt-5.1-codex"
                   ])

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
      |> assign(:models_catalog, [])
      |> assign(:models_catalog_loaded?, false)
      |> assign(:models_loading?, false)
      |> assign(:models_error, nil)
      |> assign(:model_select_options, [])
      |> assign(:thinking_select_options, [])
      |> assign(:verbosity_select_options, @verbose_level_options)
      |> assign(:model_form, to_form(%{"model" => ""}, as: :session_model))
      |> assign(:thinking_form, to_form(%{"thinking_level" => ""}, as: :session_thinking))
      |> assign(:verbosity_form, to_form(%{"verbose_level" => ""}, as: :session_verbosity))
      |> assign(:label_form, to_form(%{"label" => ""}, as: :session_label))
      |> assign(:deleting_session_keys, MapSet.new())
      |> assign(:form, to_form(%{"message" => ""}, as: :chat))
      |> stream(:messages, [])
      |> sync_no_messages_state()
      |> sync_session_controls()

    socket =
      if connected?(socket) do
        OpenClaw.subscribe_gateway()
        OpenClaw.subscribe_chat()
        OpenClaw.subscribe_event("agent")
        send(self(), :load_menu_sessions)
        send(self(), :load_models_catalog)

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
  def handle_event("change-session-model", %{"session_model" => %{"model" => model_ref}}, socket)
      when is_binary(model_ref) do
    session_key = socket.assigns.selected_session_key
    model_patch = if model_ref == "", do: nil, else: model_ref

    if is_binary(session_key) do
      case OpenClaw.sessions_patch(session_key, %{"model" => model_patch}) do
        {:ok, _payload} ->
          socket
          |> optimistic_update_session_model(session_key, model_patch)
          |> sync_session_controls()
          |> maybe_schedule_menu_refresh()
          |> (&{:noreply, &1}).()

        {:error, reason} ->
          socket
          |> put_flash(:error, "Failed to change model: #{format_reason(reason)}")
          |> (&{:noreply, &1}).()
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "change-session-thinking",
        %{"session_thinking" => %{"thinking_level" => thinking_level}},
        socket
      )
      when is_binary(thinking_level) do
    session_key = socket.assigns.selected_session_key

    if is_binary(session_key) do
      provider =
        socket
        |> selected_session()
        |> selected_session_model_provider()

      thinking_patch = normalize_thinking_patch_value(thinking_level, provider)

      case OpenClaw.sessions_patch(session_key, %{"thinkingLevel" => thinking_patch}) do
        {:ok, _payload} ->
          socket
          |> optimistic_update_session_thinking(session_key, thinking_patch)
          |> sync_session_controls()
          |> maybe_schedule_menu_refresh()
          |> (&{:noreply, &1}).()

        {:error, reason} ->
          socket
          |> put_flash(:error, "Failed to change thinking level: #{format_reason(reason)}")
          |> (&{:noreply, &1}).()
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "change-session-verbosity",
        %{"session_verbosity" => %{"verbose_level" => verbose_level}},
        socket
      )
      when is_binary(verbose_level) do
    session_key = socket.assigns.selected_session_key

    if is_binary(session_key) do
      verbose_patch = if verbose_level == "", do: nil, else: verbose_level

      case OpenClaw.sessions_patch(session_key, %{"verboseLevel" => verbose_patch}) do
        {:ok, _payload} ->
          socket
          |> optimistic_update_session_verbosity(session_key, verbose_patch)
          |> sync_session_controls()
          |> maybe_schedule_menu_refresh()
          |> (&{:noreply, &1}).()

        {:error, reason} ->
          socket
          |> put_flash(:error, "Failed to change verbosity: #{format_reason(reason)}")
          |> (&{:noreply, &1}).()
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change-session-label", params, socket) do
    raw_label = extract_label_param(params)

    if is_binary(raw_label) do
      session_key = socket.assigns.selected_session_key

      if is_binary(session_key) do
        label = String.trim(raw_label)
        label_patch = if label == "", do: nil, else: label

        if current_session_label(socket) == label_patch do
          {:noreply, socket}
        else
          case OpenClaw.sessions_patch(session_key, %{"label" => label_patch}) do
            {:ok, _payload} ->
              socket
              |> optimistic_update_session_label(session_key, label_patch)
              |> sync_session_controls()
              |> maybe_schedule_menu_refresh()
              |> (&{:noreply, &1}).()

            {:error, reason} ->
              socket
              |> put_flash(:error, "Failed to change session label: #{format_reason(reason)}")
              |> (&{:noreply, &1}).()
          end
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("menu-select-session", %{"session_key" => session_key}, socket)
      when is_binary(session_key) and session_key != "" do
    select_session(socket, session_key)
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_event("delete-session", %{"session_key" => session_key}, socket)
      when is_binary(session_key) and session_key != "" do
    sessions_snapshot = socket.assigns.sessions
    selected_snapshot = socket.assigns.selected_session_key

    next_session_key =
      adjacent_session_key_after_delete(sessions_snapshot, session_key)

    sessions_without_deleted =
      Enum.reject(sessions_snapshot, fn session ->
        session_key_value(session) == session_key
      end)

    socket =
      socket
      |> put_flash(:info, "Deleting session #{session_key}...")
      |> assign(:sessions, sessions_without_deleted)
      |> assign(:pending_session_key, nil)
      |> update(:deleting_session_keys, fn deleting_session_keys ->
        MapSet.put(deleting_session_keys, session_key)
      end)

    socket =
      if selected_snapshot == session_key do
        if is_binary(next_session_key) do
          socket
          |> select_session(next_session_key)
          |> push_patch(to: session_path(next_session_key))
        else
          socket
          |> clear_session_selection()
          |> push_patch(to: ~p"/")
        end
      else
        socket
      end

    send(self(), {:session_delete_finished, session_key, sessions_snapshot, selected_snapshot})

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:session_delete_finished, session_key, sessions_snapshot, selected_snapshot},
        socket
      )
      when is_binary(session_key) do
    case OpenClaw.sessions_delete(session_key, %{"deleteTranscript" => true}) do
      {:ok, %{"ok" => true}} ->
        {:noreply,
         socket
         |> update(:deleting_session_keys, fn deleting_session_keys ->
           MapSet.delete(deleting_session_keys, session_key)
         end)
         |> assign(:sessions_error, nil)
         |> maybe_schedule_menu_refresh()}

      {:error, reason} ->
        socket =
          restore_deleted_session_on_error(
            socket,
            session_key,
            sessions_snapshot,
            selected_snapshot
          )

        {:noreply,
         socket
         |> update(:deleting_session_keys, fn deleting_session_keys ->
           MapSet.delete(deleting_session_keys, session_key)
         end)
         |> put_flash(:error, "Failed to delete session: #{format_reason(reason)}")}
    end
  end

  @impl true
  def handle_info(:load_menu_sessions, socket) do
    load_menu_sessions(socket)
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info(:load_models_catalog, socket) do
    cond do
      socket.assigns.models_catalog_loaded? ->
        {:noreply, socket}

      socket.assigns.models_loading? ->
        {:noreply, socket}

      true ->
        liveview_pid = self()

        Task.start(fn ->
          result = OpenClaw.models_list()
          send(liveview_pid, {:models_catalog_loaded, result})
        end)

        {:noreply, assign(socket, :models_loading?, true)}
    end
  end

  @impl true
  def handle_info({:models_catalog_loaded, result}, socket) do
    socket =
      case result do
        {:ok, %{"models" => models}} when is_list(models) ->
          socket
          |> assign(:models_catalog, normalize_models_catalog(models))
          |> assign(:models_catalog_loaded?, true)
          |> assign(:models_loading?, false)
          |> assign(:models_error, nil)
          |> sync_session_controls()

        {:ok, _payload} ->
          socket
          |> assign(:models_loading?, false)
          |> assign(:models_error, "invalid models.list payload")

        {:error, reason} ->
          socket
          |> assign(:models_loading?, false)
          |> assign(:models_error, format_reason(reason))
      end

    {:noreply, socket}
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
          |> maybe_schedule_menu_refresh()

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
        |> assign(:sessions_error, nil)
        |> flush_queued_messages(selected_session_key)
        |> request_history_load(selected_session_key)
      else
        socket
        |> assign(:sessions_error, nil)
        |> maybe_select_first_session()
      end

    socket
    |> maybe_schedule_models_catalog_load()
    |> maybe_schedule_menu_refresh()
    |> (&{:noreply, &1}).()
  end

  @impl true
  def handle_info({:openclaw_gateway, :pairing_required, _payload}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/gateway/pairing")}
  end

  @impl true
  def handle_info({:openclaw_gateway, :socket_up, _payload}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:openclaw_gateway, :reconnecting, _payload}, socket) do
    {:noreply, socket}
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
  def handle_info({:openclaw_gateway, _event, _payload}, socket) do
    {:noreply, socket}
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
      |> sync_session_controls()
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
    |> sync_session_controls()
  end

  defp restore_deleted_session_on_error(
         socket,
         deleted_session_key,
         sessions_snapshot,
         selected_snapshot
       )
       when is_binary(deleted_session_key) and is_list(sessions_snapshot) do
    current_selected = socket.assigns.selected_session_key

    restore_selected? =
      is_nil(current_selected) ||
        current_selected == deleted_session_key ||
        current_selected == selected_snapshot

    socket
    |> assign(:sessions, sessions_snapshot)
    |> assign(:pending_session_key, nil)
    |> then(fn
      socket when restore_selected? and is_binary(selected_snapshot) ->
        socket
        |> select_session(selected_snapshot)
        |> push_patch(to: session_path(selected_snapshot))

      socket ->
        socket
    end)
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
    socket =
      socket
      |> assign(:sessions_loading?, true)
      |> assign(:sessions_error, nil)

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
          |> sync_session_controls()

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

  defp maybe_schedule_models_catalog_load(socket) do
    if socket.assigns.models_catalog_loaded? or socket.assigns.models_loading? do
      socket
    else
      send(self(), :load_models_catalog)
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

  defp resolve_selected_session_key([], _previous), do: nil

  defp resolve_selected_session_key(_sessions, previous_selected)
       when is_binary(previous_selected) and previous_selected == "", do: nil

  defp resolve_selected_session_key(sessions, previous_selected)
       when is_binary(previous_selected) do
    if has_session_key?(sessions, previous_selected), do: previous_selected, else: nil
  end

  defp resolve_selected_session_key(_sessions, _previous), do: nil

  defp adjacent_session_key_after_delete(sessions, deleted_key)
       when is_list(sessions) and is_binary(deleted_key) and deleted_key != "" do
    index = Enum.find_index(sessions, &(session_key_value(&1) == deleted_key))

    case index do
      nil ->
        nil

      0 ->
        sessions |> Enum.at(1) |> session_key_value()

      index when is_integer(index) ->
        sessions
        |> Enum.at(index - 1)
        |> session_key_value()
        |> Kernel.||(sessions |> Enum.at(index + 1) |> session_key_value())
    end
  end

  defp adjacent_session_key_after_delete(_sessions, _deleted_key), do: nil

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
            thinking_text = extract_message_thinking_text(message)

            socket
            |> assign(:assistant_pending?, true)
            |> assign(:streaming_run_id, run_id || tracked_run_id)
            |> apply_assistant_streaming_text_update(payload)
            |> maybe_assign_streaming_content(:streaming_thinking_text, thinking_text)

          "final" ->
            message = map_get(payload, "message")
            thinking_text = extract_message_thinking_text(message)

            socket =
              socket
              |> assign(:assistant_pending?, true)
              |> assign(:streaming_run_id, run_id || tracked_run_id)
              |> apply_assistant_streaming_text_update(payload)
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
    |> ensure_session_placeholder(new_session_key)
    |> sync_no_messages_state()
    |> sync_session_controls()
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
        existing_message = Enum.at(socket.assigns.history_messages, index)
        merged_message = merge_history_message(existing_message, message)
        updated_messages = List.replace_at(socket.assigns.history_messages, index, merged_message)
        socket = assign(socket, :history_messages, updated_messages)

        if socket.assigns.show_traces? or not Map.get(merged_message, :trace?, false) do
          stream_insert(socket, :messages, merged_message)
        else
          socket
        end
        |> sync_no_messages_state()
    end
  end

  defp merge_history_message(existing_message, incoming_message)
       when is_map(existing_message) and is_map(incoming_message) do
    if tool_trace_message?(existing_message) or tool_trace_message?(incoming_message) do
      incoming_message
      |> Map.put(
        :timestamp_label,
        coalesce_non_empty(
          Map.get(incoming_message, :timestamp_label),
          Map.get(existing_message, :timestamp_label)
        )
      )
      |> Map.put(
        :text,
        coalesce_non_empty(Map.get(incoming_message, :text), Map.get(existing_message, :text))
      )
      |> Map.put(
        :tool_name,
        coalesce_non_empty(
          Map.get(incoming_message, :tool_name),
          Map.get(existing_message, :tool_name)
        )
      )
      |> Map.put(
        :tool_argument_rows,
        coalesce_non_empty_list(
          Map.get(incoming_message, :tool_argument_rows),
          Map.get(existing_message, :tool_argument_rows)
        )
      )
    else
      incoming_message
    end
  end

  defp merge_history_message(_existing_message, incoming_message), do: incoming_message

  defp coalesce_non_empty(primary, fallback) when is_binary(primary) do
    if String.trim(primary) == "" do
      fallback
    else
      primary
    end
  end

  defp coalesce_non_empty(primary, _fallback) when not is_nil(primary), do: primary
  defp coalesce_non_empty(_primary, fallback), do: fallback

  defp coalesce_non_empty_list(primary, fallback) when is_list(primary) do
    if primary == [] do
      if is_list(fallback), do: fallback, else: []
    else
      primary
    end
  end

  defp coalesce_non_empty_list(_primary, fallback) when is_list(fallback), do: fallback
  defp coalesce_non_empty_list(_primary, _fallback), do: []

  defp build_tool_trace_message(payload) when is_map(payload) do
    data = map_get(payload, "data")

    if is_map(data) do
      run_id = map_string(payload, "runId") || "run"
      sequence = map_get(payload, "seq") || "seq"
      tool_call_id = map_string(data, "toolCallId")
      phase = map_string(data, "phase") || "update"
      name = map_string(data, "name") || "(unnamed tool)"
      args = map_get(data, "args") || map_get(data, "arguments")
      result = map_get(data, "result")
      partial_result = map_get(data, "partialResult")
      error = map_get(data, "error")
      tool_argument_rows = tool_argument_rows(args)

      text =
        build_tool_trace_text(%{
          phase: phase,
          result: result,
          partial_result: partial_result,
          error: error
        })

      if message_text_present?(text) or tool_argument_rows != [] do
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
          tool_name: name,
          tool_argument_rows: tool_argument_rows,
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
         phase: phase,
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
      "phase: #{phase}",
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

  defp sync_session_controls(socket) do
    selected_session = selected_session(socket)
    selected_model_ref = selected_session_model_ref(selected_session) || ""

    selected_provider =
      model_provider_from_ref(selected_model_ref) ||
        selected_session_model_provider(selected_session)

    selected_model_id =
      model_id_from_ref(selected_model_ref) ||
        selected_session_model_id(selected_session)

    selected_thinking = selected_session_thinking_level(selected_session)
    selected_thinking_display = thinking_level_display(selected_thinking, selected_provider)
    selected_verbosity = selected_session_verbose_level(selected_session)

    socket
    |> assign(:selected_session, selected_session)
    |> assign(
      :model_select_options,
      build_model_select_options(socket.assigns.models_catalog, selected_model_ref)
    )
    |> assign(
      :thinking_select_options,
      build_thinking_select_options(
        selected_provider,
        selected_model_id,
        selected_thinking_display
      )
    )
    |> assign(
      :verbosity_select_options,
      build_verbosity_select_options(selected_verbosity)
    )
    |> assign(:model_form, to_form(%{"model" => selected_model_ref}, as: :session_model))
    |> assign(
      :thinking_form,
      to_form(%{"thinking_level" => selected_thinking_display}, as: :session_thinking)
    )
    |> assign(
      :verbosity_form,
      to_form(%{"verbose_level" => selected_verbosity}, as: :session_verbosity)
    )
    |> assign(
      :label_form,
      to_form(%{"label" => selected_session_label(selected_session) || ""}, as: :session_label)
    )
  end

  defp selected_session(socket) do
    selected_session_key = socket.assigns.selected_session_key

    Enum.find(socket.assigns.sessions, fn session ->
      session_key_value(session) == selected_session_key
    end)
  end

  defp selected_session_model_ref(session) when is_map(session) do
    provider = map_string(session, "modelProvider")
    model = map_string(session, "model")

    if is_binary(provider) and is_binary(model) do
      "#{provider}/#{model}"
    else
      nil
    end
  end

  defp selected_session_model_ref(_session), do: nil

  defp selected_session_model_provider(session) when is_map(session) do
    map_string(session, "modelProvider")
  end

  defp selected_session_model_provider(_session), do: nil

  defp selected_session_model_id(session) when is_map(session) do
    map_string(session, "model")
  end

  defp selected_session_model_id(_session), do: nil

  defp current_session_label(socket) when is_map(socket.assigns) do
    socket
    |> selected_session()
    |> selected_session_label()
  end

  defp selected_session_label(session) when is_map(session) do
    Map.get(session, "label")
  end

  defp selected_session_label(_session), do: nil

  defp extract_label_param(%{"session_label" => %{"label" => raw_label}})
       when is_binary(raw_label),
       do: raw_label

  defp extract_label_param(%{"value" => raw_label}) when is_binary(raw_label), do: raw_label
  defp extract_label_param(_params), do: nil

  defp selected_session_thinking_level(session) when is_map(session) do
    map_string(session, "thinkingLevel") || ""
  end

  defp selected_session_thinking_level(_session), do: ""

  defp selected_session_verbose_level(session) when is_map(session) do
    map_string(session, "verboseLevel") || ""
  end

  defp selected_session_verbose_level(_session), do: ""

  defp build_model_select_options(models_catalog, selected_model_ref)
       when is_list(models_catalog) do
    options =
      models_catalog
      |> Enum.map(fn model ->
        provider = map_string(model, "provider")
        model_id = map_string(model, "id")
        name = map_string(model, "name")
        value = "#{provider}/#{model_id}"

        label =
          if is_binary(name) and name != "" and name != model_id do
            "#{name} (#{value})"
          else
            value
          end

        {label, value}
      end)

    values = MapSet.new(Enum.map(options, &elem(&1, 1)))

    options =
      if is_binary(selected_model_ref) and selected_model_ref != "" and
           not MapSet.member?(values, selected_model_ref) do
        [{"#{selected_model_ref} (current)", selected_model_ref} | options]
      else
        options
      end

    [{"inherit", ""} | options]
  end

  defp build_model_select_options(_models_catalog, _selected_model_ref), do: [{"inherit", ""}]

  defp build_thinking_select_options(selected_provider, selected_model, selected_value)
       when is_binary(selected_value) do
    options =
      thinking_level_options(selected_provider, selected_model)
      |> with_selected_option(selected_value)

    Enum.map(options, fn value ->
      label = if value == "", do: "inherit", else: value
      {label, value}
    end)
  end

  defp build_thinking_select_options(selected_provider, selected_model, _selected_value) do
    build_thinking_select_options(selected_provider, selected_model, "")
  end

  defp build_verbosity_select_options(selected_value) when is_binary(selected_value) do
    options =
      if selected_value == "" or selected_value in Enum.map(@verbose_level_options, &elem(&1, 1)) do
        @verbose_level_options
      else
        @verbose_level_options ++ [{selected_value, "#{selected_value} (custom)"}]
      end

    Enum.map(options, fn {label, value} ->
      label =
        if value == "" and label == "" do
          "inherit"
        else
          label
        end

      {label, value}
    end)
  end

  defp build_verbosity_select_options(_selected_value), do: @verbose_level_options

  defp thinking_level_options(provider, model) do
    cond do
      binary_thinking_provider?(provider) ->
        @binary_think_levels

      supports_xhigh_thinking?(provider, model) ->
        @think_levels ++ ["xhigh"]

      true ->
        @think_levels
    end
  end

  defp thinking_level_display(value, provider) when is_binary(value) do
    if binary_thinking_provider?(provider) and value not in ["", "off"] do
      "on"
    else
      value
    end
  end

  defp thinking_level_display(_value, _provider), do: ""

  defp normalize_thinking_patch_value(value, provider) when is_binary(value) do
    cond do
      value == "" ->
        nil

      binary_thinking_provider?(provider) and value == "on" ->
        "low"

      true ->
        value
    end
  end

  defp binary_thinking_provider?(provider) when is_binary(provider) do
    normalized =
      provider
      |> String.trim()
      |> String.downcase()

    normalized in ["zai", "z.ai", "z-ai"]
  end

  defp binary_thinking_provider?(_provider), do: false

  defp with_selected_option(options, selected_value)
       when is_list(options) and is_binary(selected_value) do
    if selected_value != "" and selected_value not in options do
      options ++ [selected_value]
    else
      options
    end
  end

  defp model_provider_from_ref(model_ref) when is_binary(model_ref) do
    case String.split(model_ref, "/", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        provider

      _ ->
        nil
    end
  end

  defp model_id_from_ref(model_ref) when is_binary(model_ref) do
    case String.split(model_ref, "/", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        model_id

      _ ->
        nil
    end
  end

  defp model_id_from_ref(_model_ref), do: nil

  defp supports_xhigh_thinking?(provider, model) when is_binary(model) do
    normalized_model =
      model
      |> String.trim()
      |> String.downcase()

    if normalized_model == "" do
      false
    else
      normalized_provider =
        provider
        |> to_string()
        |> String.trim()
        |> String.downcase()

      if normalized_provider != "" do
        MapSet.member?(@xhigh_model_refs, "#{normalized_provider}/#{normalized_model}")
      else
        MapSet.member?(@xhigh_model_ids, normalized_model)
      end
    end
  end

  defp supports_xhigh_thinking?(_provider, _model), do: false

  defp normalize_models_catalog(models) when is_list(models) do
    models
    |> Enum.reduce([], fn model, acc ->
      provider = map_string(model, "provider")
      model_id = map_string(model, "id")
      name = map_string(model, "name")

      if is_binary(provider) and is_binary(model_id) do
        [%{"provider" => provider, "id" => model_id, "name" => name || model_id} | acc]
      else
        acc
      end
    end)
    |> Enum.uniq_by(fn model -> {model["provider"], model["id"]} end)
    |> Enum.sort_by(fn model -> {model["provider"], model["id"]} end)
  end

  defp optimistic_update_session_model(socket, session_key, model_ref)
       when is_binary(session_key) do
    {provider, model} =
      case model_provider_from_ref(model_ref) do
        nil ->
          {nil, nil}

        provider ->
          case String.split(model_ref, "/", parts: 2) do
            [_provider, model_id] when model_id != "" -> {provider, model_id}
            _ -> {nil, nil}
          end
      end

    update_session_entry(socket, session_key, fn session ->
      session
      |> Map.put("modelProvider", provider)
      |> Map.put("model", model)
      |> Map.put("updatedAt", System.system_time(:millisecond))
    end)
  end

  defp optimistic_update_session_model(socket, _session_key, _model_ref), do: socket

  defp optimistic_update_session_thinking(socket, session_key, thinking_level)
       when is_binary(session_key) do
    update_session_entry(socket, session_key, fn session ->
      session
      |> Map.put("thinkingLevel", thinking_level)
      |> Map.put("updatedAt", System.system_time(:millisecond))
    end)
  end

  defp optimistic_update_session_thinking(socket, _session_key, _thinking_level), do: socket

  defp optimistic_update_session_label(socket, session_key, label) when is_binary(session_key) do
    update_session_entry(socket, session_key, fn session ->
      session
      |> maybe_set_session_label(label)
      |> Map.put("updatedAt", System.system_time(:millisecond))
    end)
  end

  defp optimistic_update_session_label(socket, _session_key, _label), do: socket

  defp optimistic_update_session_verbosity(socket, session_key, verbose_level)
       when is_binary(session_key) do
    update_session_entry(socket, session_key, fn session ->
      session
      |> Map.put("verboseLevel", verbose_level)
      |> Map.put("updatedAt", System.system_time(:millisecond))
    end)
  end

  defp optimistic_update_session_verbosity(socket, _session_key, _verbose_level), do: socket

  defp maybe_set_session_label(session, value) when is_map(session) and is_binary(value) do
    Map.put(session, "label", value)
  end

  defp maybe_set_session_label(session, _value) when is_map(session),
    do: Map.delete(session, "label")

  defp update_session_entry(socket, session_key, updater)
       when is_binary(session_key) and is_function(updater, 1) do
    update(socket, :sessions, fn sessions ->
      Enum.map(sessions, fn session ->
        if session_key_value(session) == session_key do
          updater.(session)
        else
          session
        end
      end)
    end)
  end

  defp session_subtitle(_selected_session, true, _error, _pending_session_key),
    do: "Loading session history..."

  defp session_subtitle(_selected_session, _loading?, error, _pending_session_key)
       when is_binary(error),
       do: error

  defp session_subtitle(selected_session, _loading?, _error, _pending_session_key)
       when is_map(selected_session) do
    session_subtitle_label(selected_session)
  end

  defp session_subtitle(nil, _loading?, _error, pending_session_key)
       when is_binary(pending_session_key),
       do: "Preparing new session..."

  defp session_subtitle(nil, _loading?, _error, _pending_session_key),
    do: "Pick a session from the menu to inspect history."

  defp session_subtitle_label(selected_session) when is_map(selected_session) do
    case map_string(selected_session, "displayName") do
      nil -> map_string(selected_session, "key")
      name -> name
    end
  end

  defp session_subtitle_label(_selected_session), do: ""

  defp format_reason(%{"message" => message}) when is_binary(message), do: message
  defp format_reason(%{message: message}) when is_binary(message), do: message
  defp format_reason(reason), do: inspect(reason)

  defp message_role_label(%{error?: true}), do: "assistant error"

  defp message_role_label(%{role: role}) when is_binary(role) do
    case String.downcase(role) do
      value when value in ["toolcall", "tool_call"] -> "tool call"
      value when value in ["toolresult", "tool_result"] -> "tool result"
      value -> value
    end
  end

  defp message_role_label(_message), do: "assistant"

  defp message_container_class(%{error?: true}) do
    "mr-auto border-red-300 bg-red-50 text-red-900 dark:border-red-800/60 dark:bg-red-950/30 dark:text-red-100"
  end

  defp message_container_class(%{role: "user"}) do
    "ml-auto border-purple-200 bg-purple-50 text-gray-900 dark:border-purple-800/60 dark:bg-purple-900/30 dark:text-gray-100"
  end

  defp message_container_class(%{role: role}) when is_binary(role) do
    if String.downcase(role) == "user" do
      message_container_class(%{role: "user"})
    else
      "mr-auto border-gray-200 bg-white text-gray-900 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
    end
  end

  defp message_container_class(_message) do
    "mr-auto border-gray-200 bg-white text-gray-900 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-100"
  end

  defp tool_trace_message?(message) when is_map(message) do
    is_binary(Map.get(message, :tool_name))
  end

  defp tool_trace_message?(_message), do: false

  defp message_text_present?(%{text: text}) when is_binary(text), do: String.trim(text) != ""
  defp message_text_present?(text) when is_binary(text), do: String.trim(text) != ""
  defp message_text_present?(_), do: false

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

  defp tool_argument_rows(arguments) when is_map(arguments) do
    arguments
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} ->
      %{
        key: to_string(key),
        value: format_trace_value(value)
      }
    end)
  end

  defp tool_argument_rows(arguments) when is_list(arguments) do
    arguments
    |> Enum.with_index(1)
    |> Enum.map(fn {value, index} ->
      %{
        key: Integer.to_string(index),
        value: format_trace_value(value)
      }
    end)
  end

  defp tool_argument_rows(nil), do: []

  defp tool_argument_rows(value) do
    [
      %{
        key: "value",
        value: format_trace_value(value)
      }
    ]
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
    case build_content_history_messages(message, id_prefix) do
      [] ->
        normalized_message = normalize_history_message(message, id_prefix)

        if skip_primary_history_message?(normalized_message) do
          []
        else
          [normalized_message]
        end

      entries ->
        entries
    end
  end

  # Preserve original content[] ordering so traces render exactly as emitted
  # (e.g. thinking -> text -> thinking).
  defp build_content_history_messages(message, id_prefix) when is_map(message) do
    timestamp_label = format_timestamp_label(Message.timestamp_ms(message))
    role = Message.role(message)
    content = map_get(message, "content")

    if is_list(content) do
      {entries, pending_text_parts, pending_text_start} =
        content
        |> Enum.with_index(1)
        |> Enum.reduce({[], [], nil}, fn {part, index}, {entries, pending_parts, pending_start} ->
          case content_part_history_entry(part, id_prefix, index, role, timestamp_label) do
            {:text, text_part} ->
              if String.trim(text_part) == "" do
                {entries, pending_parts, pending_start}
              else
                next_pending_start = pending_start || index
                {entries, pending_parts ++ [text_part], next_pending_start}
              end

            {:entry, entry} ->
              entries =
                flush_pending_text_entry(
                  entries,
                  pending_parts,
                  pending_start,
                  id_prefix,
                  role,
                  timestamp_label
                )

              {entries ++ [entry], [], nil}

            :ignore ->
              {entries, pending_parts, pending_start}
          end
        end)

      flush_pending_text_entry(
        entries,
        pending_text_parts,
        pending_text_start,
        id_prefix,
        role,
        timestamp_label
      )
    else
      []
    end
  end

  defp flush_pending_text_entry(entries, [], _start, _id_prefix, _role, _timestamp_label),
    do: entries

  defp flush_pending_text_entry(
         entries,
         text_parts,
         start_index,
         id_prefix,
         role,
         timestamp_label
       )
       when is_list(entries) and is_list(text_parts) do
    text = Enum.join(text_parts, "\n")

    entries ++
      [
        %{
          id: "#{id_prefix}-text-#{start_index || 0}-#{message_hash(text)}",
          role: role,
          text: text,
          timestamp_label: timestamp_label,
          trace?: trace_role?(role)
        }
      ]
  end

  defp content_part_history_entry(part, id_prefix, index, role, timestamp_label)
       when is_map(part) and is_integer(index) and index > 0 do
    cond do
      thinking_text = extract_thinking_text(part) ->
        {:entry,
         %{
           id: "#{id_prefix}-thinking-#{index}-#{message_hash(part)}",
           role: "thinking",
           text: truncate_trace_text(thinking_text, @tool_trace_text_limit),
           timestamp_label: timestamp_label,
           trace?: true
         }}

      tool_call = extract_tool_call_part(part) ->
        {:entry,
         %{
           id: "#{id_prefix}-toolcall-#{index}-#{message_hash(part)}",
           role: "toolcall",
           text: nil,
           tool_name: tool_call.name,
           tool_argument_rows: tool_argument_rows(tool_call.arguments),
           timestamp_label: timestamp_label,
           trace?: true
         }}

      tool_result_text = extract_tool_result_text(part) ->
        {:entry,
         %{
           id: "#{id_prefix}-toolresult-#{index}-#{message_hash(part)}",
           role: "toolresult",
           text: tool_result_text,
           timestamp_label: timestamp_label,
           trace?: true
         }}

      text_part = extract_text_part(part, role) ->
        {:text, text_part}

      true ->
        :ignore
    end
  end

  defp content_part_history_entry(_part, _id_prefix, _index, _role, _timestamp_label), do: :ignore

  defp normalize_history_message(message, id_prefix) when is_map(message) do
    timestamp_ms = Message.timestamp_ms(message)
    role = Message.role(message)
    error_message = Message.assistant_error_message(message)
    text = error_message || Message.preview_text(message)

    %{
      id: "#{id_prefix}-#{message_hash(message)}",
      role: role,
      text: text,
      timestamp_label: format_timestamp_label(timestamp_ms),
      error?: Message.assistant_error?(message),
      trace?: trace_message?(message, role)
    }
  end

  defp skip_primary_history_message?(%{trace?: true, text: text})
       when is_binary(text),
       do: String.trim(text) == ""

  defp skip_primary_history_message?(_message), do: false

  defp extract_thinking_text(part) when is_map(part) do
    type = map_string(part, "type")

    if is_binary(type) and String.downcase(type) == "thinking" do
      map_string(part, "thinking") || map_string(part, "text")
    else
      nil
    end
  end

  defp extract_thinking_text(_part), do: nil

  defp extract_tool_call_part(part) when is_map(part) do
    type = map_string(part, "type")

    if is_binary(type) and String.downcase(type) in ["toolcall", "tool_call"] do
      %{
        name: map_string(part, "name") || "(unnamed tool)",
        arguments: map_get(part, "arguments") || map_get(part, "args")
      }
    else
      nil
    end
  end

  defp extract_tool_call_part(_part), do: nil

  defp extract_tool_result_text(part) when is_map(part) do
    type = map_string(part, "type")

    if is_binary(type) and String.downcase(type) in ["toolresult", "tool_result"] do
      text = map_string(part, "text")
      result = map_get(part, "result") || map_get(part, "output") || map_get(part, "content")

      cond do
        is_binary(text) and text != "" ->
          text

        is_nil(result) ->
          "(tool result)"

        true ->
          format_trace_value(result)
      end
    else
      nil
    end
  end

  defp extract_tool_result_text(_part), do: nil

  defp extract_text_part(part, role) when is_map(part) and is_binary(role) do
    type =
      part
      |> map_string("type")
      |> case do
        value when is_binary(value) -> String.downcase(value)
        _ -> nil
      end

    if type in ["text", "input_text", "output_text"] and is_binary(map_string(part, "text")) do
      Message.extract_text(%{"role" => role, "content" => [part]}) || map_string(part, "text")
    else
      nil
    end
  end

  defp extract_text_part(_part, _role), do: nil

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

  defp apply_assistant_streaming_text_update(socket, payload) when is_map(payload) do
    case extract_assistant_streaming_text_update(payload) do
      {:append, text} ->
        append_streaming_content(socket, :streaming_text, text)

      {:replace, text} ->
        replace_streaming_content(socket, :streaming_text, text)

      _ ->
        socket
    end
  end

  defp apply_assistant_streaming_text_update(socket, _payload), do: socket

  defp extract_assistant_streaming_text_update(payload) when is_map(payload) do
    data = map_get(payload, "data")
    message = map_get(payload, "message")

    case extract_streaming_delta_text(data) do
      delta when is_binary(delta) ->
        {:append, delta}

      _ ->
        case extract_streaming_snapshot_text(data, message) do
          snapshot when is_binary(snapshot) -> {:replace, snapshot}
          _ -> nil
        end
    end
  end

  defp extract_assistant_streaming_text_update(_payload), do: nil

  defp extract_streaming_delta_text(data) when is_map(data) do
    data
    |> map_get("delta")
    |> non_empty_binary()
  end

  defp extract_streaming_delta_text(_data), do: nil

  defp extract_streaming_snapshot_text(data, message) do
    extract_streaming_snapshot_text_from_data(data) || Message.extract_text(message)
  end

  defp extract_streaming_snapshot_text_from_data(data) when is_map(data) do
    non_empty_binary(map_get(data, "text")) ||
      map_get(data, "message")
      |> Message.extract_text()
  end

  defp extract_streaming_snapshot_text_from_data(_data), do: nil

  defp non_empty_binary(value) when is_binary(value) and value != "", do: value
  defp non_empty_binary(_value), do: nil

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
        do: wrap_streaming_update(:merge, map_string(data, "text")),
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

  defp replace_streaming_content(socket, key, text)
       when is_atom(key) and is_binary(text) and text != "" do
    current_text = Map.get(socket.assigns, key)
    incoming = normalize_line_endings(text)

    if incoming == current_text do
      socket
    else
      assign(socket, key, incoming)
    end
  end

  defp replace_streaming_content(socket, _key, _text), do: socket

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
    content = map_get(message, "content")
    visible_text = Message.extract_text(message)
    has_visible_text = is_binary(visible_text) and String.trim(visible_text) != ""
    has_trace_content = contains_trace_content?(content)

    trace_role?(role) or (has_trace_content and not has_visible_text)
  end

  defp trace_message?(_message, _role), do: false

  defp trace_role?(role) when is_binary(role) do
    String.downcase(role) in ["tool", "toolresult", "tool_result", "function"]
  end

  defp trace_role?(_role), do: false

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
    "agent:main:session-#{session_id_suffix()}"
  end

  defp build_new_session_key(current_session_key) when is_binary(current_session_key) do
    case String.split(current_session_key, ":", parts: 3) do
      ["agent", agent_id, _tail] ->
        "agent:#{agent_id}:session-#{session_id_suffix()}"

      _ ->
        "agent:main:session-#{session_id_suffix()}"
    end
  end

  defp session_id_suffix do
    "#{System.system_time(:millisecond)}-#{build_session_suffix()}"
  end

  defp build_session_suffix do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
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
