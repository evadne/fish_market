defmodule FishMarket.OpenClaw do
  @moduledoc """
  OpenClaw Gateway API wrapper and PubSub topic helpers.
  """

  alias FishMarket.OpenClaw.GatewayClient

  @pubsub FishMarket.PubSub
  @gateway_topic "openclaw:gateway"
  @chat_topic "openclaw:chat"

  @type error_reason :: term()

  @spec request(String.t(), map(), timeout()) :: {:ok, term()} | {:error, error_reason()}
  def request(method, params \\ %{}, timeout \\ 10_000)
      when is_binary(method) and is_map(params) and is_integer(timeout) do
    case Process.whereis(GatewayClient) do
      nil ->
        {:error, :gateway_unavailable}

      _pid ->
        try do
          GenServer.call(GatewayClient, {:request, method, params}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, {:noproc, _} -> {:error, :gateway_unavailable}
          :exit, reason -> {:error, reason}
        end
    end
  end

  @spec sessions_list(map()) :: {:ok, term()} | {:error, error_reason()}
  def sessions_list(params \\ %{}) when is_map(params) do
    defaults = %{"includeGlobal" => true, "includeUnknown" => true}
    request("sessions.list", Map.merge(defaults, params))
  end

  @spec sessions_patch(String.t(), map()) :: {:ok, term()} | {:error, error_reason()}
  def sessions_patch(session_key, patch \\ %{}) when is_binary(session_key) and is_map(patch) do
    request("sessions.patch", Map.put(patch, "key", session_key))
  end

  @spec chat_history(String.t(), pos_integer()) :: {:ok, term()} | {:error, error_reason()}
  def chat_history(session_key, limit \\ 200)
      when is_binary(session_key) and is_integer(limit) and limit > 0 do
    request("chat.history", %{"sessionKey" => session_key, "limit" => limit})
  end

  @spec chat_send(String.t(), String.t(), map()) :: {:ok, term()} | {:error, error_reason()}
  def chat_send(session_key, message, opts \\ %{})
      when is_binary(session_key) and is_binary(message) and is_map(opts) do
    deliver = map_fetch(opts, :deliver, "deliver", false)
    thinking = map_fetch(opts, :thinking, "thinking", nil)

    idempotency_key =
      map_fetch(opts, :idempotency_key, "idempotencyKey", nil) || idempotency_key()

    params =
      %{
        "sessionKey" => session_key,
        "message" => message,
        "deliver" => deliver,
        "idempotencyKey" => idempotency_key
      }
      |> maybe_put("thinking", thinking)

    request("chat.send", params)
  end

  @spec subscribe_gateway() :: :ok | {:error, term()}
  def subscribe_gateway do
    Phoenix.PubSub.subscribe(@pubsub, @gateway_topic)
  end

  @spec subscribe_chat() :: :ok | {:error, term()}
  def subscribe_chat do
    Phoenix.PubSub.subscribe(@pubsub, @chat_topic)
  end

  @spec subscribe_session(String.t()) :: :ok | {:error, term()}
  def subscribe_session(session_key) when is_binary(session_key) do
    Phoenix.PubSub.subscribe(@pubsub, session_topic(session_key))
  end

  @spec unsubscribe_session(String.t()) :: :ok
  def unsubscribe_session(session_key) when is_binary(session_key) do
    Phoenix.PubSub.unsubscribe(@pubsub, session_topic(session_key))
  end

  @spec broadcast_local_user_message(String.t(), map()) :: :ok
  def broadcast_local_user_message(session_key, payload)
      when is_binary(session_key) and is_map(payload) do
    message =
      {:openclaw_local_user_message,
       payload
       |> Map.put_new("sessionKey", session_key)
       |> Map.put_new(:sessionKey, session_key)}

    Phoenix.PubSub.broadcast(@pubsub, session_topic(session_key), message)
  end

  @spec broadcast_gateway(atom(), term()) :: :ok
  def broadcast_gateway(event, payload) when is_atom(event) do
    message = {:openclaw_gateway, event, payload}
    Phoenix.PubSub.broadcast(@pubsub, @gateway_topic, message)
  end

  @spec broadcast_event(String.t(), map()) :: :ok
  def broadcast_event(event, payload) when is_binary(event) and is_map(payload) do
    message = {:openclaw_event, event, payload}

    Phoenix.PubSub.broadcast(@pubsub, event_topic(event), message)

    if event == "chat" do
      Phoenix.PubSub.broadcast(@pubsub, @chat_topic, message)
    end

    case session_key(payload) do
      nil -> :ok
      key -> Phoenix.PubSub.broadcast(@pubsub, session_topic(key), message)
    end

    :ok
  end

  @spec gateway_topic() :: String.t()
  def gateway_topic, do: @gateway_topic

  @spec chat_topic() :: String.t()
  def chat_topic, do: @chat_topic

  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_key) when is_binary(session_key),
    do: "openclaw:session:" <> session_key

  @spec idempotency_key() :: String.t()
  def idempotency_key do
    random = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    "fm-#{System.unique_integer([:positive, :monotonic])}-#{random}"
  end

  defp event_topic(event), do: "openclaw:event:" <> event

  defp session_key(payload) when is_map(payload) do
    case Map.get(payload, "sessionKey") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp map_fetch(map, atom_key, string_key, default) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
