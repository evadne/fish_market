defmodule FishMarket.OpenClaw.GatewayClient do
  @moduledoc """
  Persistent OpenClaw Gateway WebSocket client backed by Mint + mint_web_socket.
  """

  use GenServer

  require Logger

  alias FishMarket.OpenClaw
  alias FishMarket.OpenClaw.DeviceIdentity

  @connect_delay_ms 750
  @reconnect_initial_ms 1_000
  @reconnect_max_ms 15_000
  @protocol_version 3
  @client_id "gateway-client"
  @client_mode "backend"
  @scopes [
    "operator.admin",
    "operator.approvals",
    "operator.pairing"
  ]

  @type state :: map()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def request(method, params \\ %{}, timeout \\ 10_000)
      when is_binary(method) and is_map(params) and is_integer(timeout) do
    GenServer.call(__MODULE__, {:request, method, params}, timeout)
  end

  @impl true
  def init(_opts) do
    config = load_config!()

    state = %{
      uri: config.uri,
      token: config.token,
      password: config.password,
      ws_upgrade_headers: config.ws_upgrade_headers,
      client_version: config.client_version,
      client_platform: config.client_platform,
      locale: config.locale,
      user_agent: config.user_agent,
      device_identity: config.device_identity,
      conn: nil,
      request_ref: nil,
      websocket: nil,
      upgrade_status: nil,
      upgrade_headers: [],
      connect_nonce: nil,
      connect_sent?: false,
      connect_timer_ref: nil,
      reconnect_timer_ref: nil,
      reconnect_backoff_ms: @reconnect_initial_ms,
      pending: %{},
      ready?: false,
      last_seq: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    if state.ready? do
      case send_request_frame(state, method, params, {:call, from}) do
        {:ok, next_state} ->
          {:noreply, next_state}

        {:error, reason, next_state} ->
          {:reply, {:error, reason}, disconnect(next_state, {:send_failed, reason})}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    {:noreply, connect_socket(state)}
  end

  @impl true
  def handle_info(:send_connect, state) do
    if state.websocket && not state.connect_sent? do
      case send_request_frame(state, "connect", connect_params(state), :connect) do
        {:ok, next_state} ->
          {:noreply, %{next_state | connect_sent?: true, connect_timer_ref: nil}}

        {:error, reason, next_state} ->
          {:noreply, disconnect(next_state, {:connect_request_failed, reason})}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, %{conn: nil} = state) do
    Logger.debug("[openclaw] ignoring message without connection: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        next_state = %{state | conn: conn}

        case handle_stream_responses(next_state, responses) do
          {:ok, updated_state} -> {:noreply, updated_state}
          {:disconnect, reason, updated_state} -> {:noreply, disconnect(updated_state, reason)}
        end

      {:error, conn, reason, responses} ->
        next_state = %{state | conn: conn}

        case handle_stream_responses(next_state, responses) do
          {:ok, updated_state} ->
            {:noreply, disconnect(updated_state, {:stream_error, reason})}

          {:disconnect, response_reason, updated_state} ->
            {:noreply, disconnect(updated_state, {:stream_error, reason, response_reason})}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = close_connection(state.conn)
    :ok
  end

  defp connect_socket(state) do
    state = cancel_reconnect_timer(state)

    uri = state.uri
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws

    connect_opts = [protocols: [:http1]]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, connect_opts),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(
             ws_scheme,
             conn,
             build_request_path(uri),
             state.ws_upgrade_headers
           ) do
      Logger.info("[openclaw] connected transport, awaiting websocket upgrade")

      %{
        state
        | conn: conn,
          request_ref: ref,
          ready?: false,
          connect_sent?: false,
          connect_nonce: nil
      }
    else
      {:error, reason} ->
        disconnect(state, {:connect_failed, reason})

      {:error, conn, reason} ->
        _ = close_connection(conn)
        disconnect(state, {:upgrade_failed, reason})
    end
  end

  defp handle_stream_responses(state, responses) do
    Enum.reduce_while(responses, {:ok, state}, fn response, {:ok, acc_state} ->
      case handle_stream_response(acc_state, response) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:disconnect, reason, next_state} -> {:halt, {:disconnect, reason, next_state}}
      end
    end)
  end

  defp handle_stream_response(state, {:status, ref, status}) when ref == state.request_ref do
    {:ok, %{state | upgrade_status: status}}
  end

  defp handle_stream_response(state, {:headers, ref, headers}) when ref == state.request_ref do
    {:ok, %{state | upgrade_headers: headers}}
  end

  defp handle_stream_response(state, {:done, ref}) when ref == state.request_ref do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, state.upgrade_headers) do
      {:ok, conn, websocket} ->
        Logger.info("[openclaw] websocket handshake complete")

        OpenClaw.broadcast_gateway(:socket_up, %{})

        next_state =
          state
          |> cancel_connect_timer()
          |> Map.merge(%{
            conn: conn,
            websocket: websocket,
            ready?: false,
            connect_sent?: false,
            connect_nonce: nil,
            reconnect_backoff_ms: @reconnect_initial_ms,
            upgrade_status: nil,
            upgrade_headers: []
          })
          |> schedule_connect_request()

        {:ok, next_state}

      {:error, conn, reason} ->
        {:disconnect, {:websocket_new_failed, format_upgrade_failure(reason)},
         %{state | conn: conn}}
    end
  end

  defp handle_stream_response(state, {:data, ref, data}) when ref == state.request_ref do
    decode_frames(state, data)
  end

  defp handle_stream_response(state, {:error, ref, reason}) when ref == state.request_ref do
    {:disconnect, {:request_error, reason}, state}
  end

  defp handle_stream_response(state, _other), do: {:ok, state}

  defp decode_frames(%{websocket: nil} = state, _data), do: {:ok, state}

  defp decode_frames(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        next_state = %{state | websocket: websocket}

        Enum.reduce_while(frames, {:ok, next_state}, fn frame, {:ok, acc_state} ->
          case handle_ws_frame(acc_state, frame) do
            {:ok, updated_state} -> {:cont, {:ok, updated_state}}
            {:disconnect, reason, updated_state} -> {:halt, {:disconnect, reason, updated_state}}
          end
        end)

      {:error, websocket, reason} ->
        {:disconnect, {:decode_failed, reason}, %{state | websocket: websocket}}
    end
  end

  defp handle_ws_frame(state, {:text, payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "event", "event" => event} = frame} ->
        handle_event_frame(state, event, frame)

      {:ok, %{"type" => "res"} = frame} ->
        handle_response_frame(state, frame)

      {:ok, _frame} ->
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  defp handle_ws_frame(state, {:ping, payload}) do
    case send_ws_frame(state, {:pong, payload}) do
      {:ok, next_state} -> {:ok, next_state}
      {:error, reason, next_state} -> {:disconnect, {:pong_failed, reason}, next_state}
    end
  end

  defp handle_ws_frame(state, {:close, code, reason}) do
    {:disconnect, {:remote_close, code, reason}, state}
  end

  defp handle_ws_frame(state, {:close, code}) do
    {:disconnect, {:remote_close, code}, state}
  end

  defp handle_ws_frame(state, _frame), do: {:ok, state}

  defp handle_event_frame(state, "connect.challenge", frame) do
    nonce =
      case frame do
        %{"payload" => %{"nonce" => value}} when is_binary(value) and value != "" -> value
        _ -> nil
      end

    next_state = %{state | connect_nonce: nonce}

    if next_state.websocket && not next_state.connect_sent? do
      case send_request_frame(next_state, "connect", connect_params(next_state), :connect) do
        {:ok, sent_state} ->
          {:ok, %{sent_state | connect_sent?: true} |> cancel_connect_timer()}

        {:error, reason, sent_state} ->
          {:disconnect, {:connect_request_failed, reason}, sent_state}
      end
    else
      {:ok, next_state}
    end
  end

  defp handle_event_frame(state, event, frame) do
    payload =
      case frame do
        %{"payload" => %{} = value} -> value
        _ -> %{}
      end

    seq = map_integer(frame, "seq")

    next_state =
      if is_integer(seq) do
        maybe_emit_seq_gap(state, seq)
      else
        state
      end

    OpenClaw.broadcast_event(event, payload)
    {:ok, next_state}
  end

  defp handle_response_frame(state, %{"id" => id, "ok" => ok} = frame) when is_binary(id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:ok, state}

      {:connect, pending} ->
        next_state = %{state | pending: pending}

        if ok do
          payload = Map.get(frame, "payload", %{})
          OpenClaw.broadcast_gateway(:connected, payload)
          {:ok, %{next_state | ready?: true, connect_sent?: true}}
        else
          error = Map.get(frame, "error", %{"message" => "connect failed"})
          OpenClaw.broadcast_gateway(:connect_error, error)
          {:disconnect, {:connect_rejected, error}, next_state}
        end

      {{:call, from}, pending} ->
        next_state = %{state | pending: pending}

        if ok do
          GenServer.reply(from, {:ok, Map.get(frame, "payload")})
        else
          GenServer.reply(from, {:error, Map.get(frame, "error") || :request_failed})
        end

        {:ok, next_state}
    end
  end

  defp handle_response_frame(state, _frame), do: {:ok, state}

  defp send_request_frame(state, method, params, pending_entry)
       when is_binary(method) and is_map(params) do
    request_id = request_id()

    frame = %{
      "type" => "req",
      "id" => request_id,
      "method" => method,
      "params" => params
    }

    case send_json_frame(state, frame) do
      {:ok, next_state} ->
        {:ok, put_in(next_state.pending[request_id], pending_entry)}

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp send_json_frame(state, frame) do
    case Jason.encode(frame) do
      {:ok, encoded} -> send_ws_frame(state, {:text, encoded})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp send_ws_frame(%{conn: nil} = state, _frame), do: {:error, :no_connection, state}
  defp send_ws_frame(%{request_ref: nil} = state, _frame), do: {:error, :no_request_ref, state}
  defp send_ws_frame(%{websocket: nil} = state, _frame), do: {:error, :no_websocket, state}

  defp send_ws_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, reason, %{state | conn: conn, websocket: websocket}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp connect_params(state) do
    auth =
      %{}
      |> maybe_put("token", state.token)
      |> maybe_put("password", state.password)

    device = build_device_identity(state)

    %{
      "minProtocol" => @protocol_version,
      "maxProtocol" => @protocol_version,
      "client" => %{
        "id" => @client_id,
        "version" => state.client_version,
        "platform" => state.client_platform,
        "mode" => @client_mode
      },
      "role" => "operator",
      "scopes" => @scopes,
      "caps" => ["tool-events"],
      "commands" => [],
      "permissions" => %{},
      "auth" => if(map_size(auth) == 0, do: nil, else: auth),
      "device" => device,
      "locale" => state.locale,
      "userAgent" => state.user_agent
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp build_device_identity(state) do
    identity = state.device_identity

    if identity do
      DeviceIdentity.build_connect_device(identity, %{
        role: "operator",
        scopes: @scopes,
        token: state.token,
        nonce: state.connect_nonce,
        signed_at: System.system_time(:millisecond)
      })
    end
  end

  defp schedule_connect_request(state) do
    ref = Process.send_after(self(), :send_connect, @connect_delay_ms)
    %{state | connect_timer_ref: ref}
  end

  defp maybe_emit_seq_gap(state, seq) do
    case state.last_seq do
      last when is_integer(last) and seq > last + 1 ->
        OpenClaw.broadcast_gateway(:event_gap, %{"expected" => last + 1, "received" => seq})
        %{state | last_seq: seq}

      _ ->
        %{state | last_seq: seq}
    end
  end

  defp disconnect(state, reason) do
    Logger.warning("[openclaw] disconnecting: #{inspect(reason)}")

    _ = close_connection(state.conn)

    Enum.each(state.pending, fn
      {_id, {:call, from}} -> GenServer.reply(from, {:error, :disconnected})
      _ -> :ok
    end)

    OpenClaw.broadcast_gateway(:disconnected, %{reason: inspect(reason)})

    next_state =
      state
      |> cancel_connect_timer()
      |> cancel_reconnect_timer()
      |> Map.merge(%{
        conn: nil,
        websocket: nil,
        request_ref: nil,
        ready?: false,
        connect_sent?: false,
        connect_nonce: nil,
        upgrade_status: nil,
        upgrade_headers: [],
        pending: %{},
        last_seq: nil
      })

    schedule_reconnect(next_state)
  end

  defp schedule_reconnect(state) do
    delay = state.reconnect_backoff_ms
    next_backoff = min(round(delay * 1.7), @reconnect_max_ms)
    ref = Process.send_after(self(), :connect, delay)

    OpenClaw.broadcast_gateway(:reconnecting, %{"delayMs" => delay})

    %{state | reconnect_timer_ref: ref, reconnect_backoff_ms: next_backoff}
  end

  defp cancel_connect_timer(%{connect_timer_ref: nil} = state), do: state

  defp cancel_connect_timer(state) do
    _ = Process.cancel_timer(state.connect_timer_ref)
    %{state | connect_timer_ref: nil}
  end

  defp cancel_reconnect_timer(%{reconnect_timer_ref: nil} = state), do: state

  defp cancel_reconnect_timer(state) do
    _ = Process.cancel_timer(state.reconnect_timer_ref)
    %{state | reconnect_timer_ref: nil}
  end

  defp close_connection(nil), do: :ok

  defp close_connection(conn) do
    try do
      Mint.HTTP.close(conn)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp build_request_path(uri) do
    path = if is_binary(uri.path) and uri.path != "", do: uri.path, else: "/"

    case uri.query do
      query when is_binary(query) and query != "" -> path <> "?" <> query
      _ -> path
    end
  end

  defp request_id do
    random = Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    "gw-#{System.unique_integer([:positive, :monotonic])}-#{random}"
  end

  defp load_config! do
    config = Application.get_env(:fish_market, FishMarket.OpenClaw, [])

    gateway_url =
      config
      |> Keyword.get(:gateway_url)
      |> blank_to_nil()
      |> require_env!("OPENCLAW_GATEWAY_URL")

    token = config |> Keyword.get(:gateway_token) |> blank_to_nil()
    password = config |> Keyword.get(:gateway_password) |> blank_to_nil()

    if is_nil(token) and is_nil(password) do
      raise "at least one of OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD must be set"
    end

    uri = URI.parse(gateway_url)

    unless uri.scheme in ["ws", "wss"] and is_binary(uri.host) and uri.host != "" do
      raise "OPENCLAW_GATEWAY_URL must be a valid ws:// or wss:// URL"
    end

    port = uri.port || default_port(uri.scheme)

    %{
      uri: %{uri | port: port},
      token: token,
      password: password,
      device_identity: DeviceIdentity.load_or_create_identity(config[:xdg_config_home]),
      ws_upgrade_headers: ws_upgrade_headers(),
      client_version: fish_market_version(),
      client_platform: client_platform(),
      locale: "en-US",
      user_agent: "fish-market/#{fish_market_version()}"
    }
  end

  defp fish_market_version do
    case Application.spec(:fish_market, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp client_platform do
    :os.type()
    |> Tuple.to_list()
    |> Enum.map_join("-", &Atom.to_string/1)
  end

  defp require_env!(nil, env_name), do: raise("#{env_name} is required")
  defp require_env!(value, _env_name), do: value

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp format_upgrade_failure(%Mint.WebSocket.UpgradeFailureError{} = error) do
    status = error.status_code
    location = header_value(error.headers, "location")

    details =
      if is_binary(location) do
        %{status: status, location: location}
      else
        %{status: status}
      end

    %{
      message: "websocket upgrade failed",
      details: details
    }
  end

  defp format_upgrade_failure(reason), do: reason

  defp header_value(headers, key) when is_list(headers) and is_binary(key) do
    key_down = String.downcase(key)

    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == key_down, do: value, else: nil

      _ ->
        nil
    end)
  end

  defp ws_upgrade_headers do
    client_id = System.get_env("OPENCLAW_GATEWAY_ACCESS_CLIENT_ID") |> blank_to_nil()
    client_secret = System.get_env("OPENCLAW_GATEWAY_ACCESS_CLIENT_SECRET") |> blank_to_nil()

    headers =
      []
      |> maybe_add_header("cf-access-client-id", client_id)
      |> maybe_add_header("cf-access-client-secret", client_secret)

    headers
  end

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]
end
