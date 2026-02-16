defmodule FishMarketWeb.GatewayPairingLive do
  use FishMarketWeb, :live_view

  alias FishMarket.OpenClaw

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:pairing_message, nil)
      |> assign(
        :pairing_hint,
        "Approve this device in the OpenClaw Control UI, then return to this screen."
      )

    socket =
      if connected?(socket) do
        OpenClaw.subscribe_gateway()
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:openclaw_gateway, :pairing_required, payload}, socket) do
    {:noreply,
     socket
     |> assign(:pairing_message, gateway_pairing_message(payload))
     |> assign(:pairing_hint, gateway_pairing_message_hint(payload))}
  end

  @impl true
  def handle_info({:openclaw_gateway, :connected, _payload}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_info({:openclaw_gateway, :connect_error, payload}, socket) do
    {:noreply,
     socket
     |> assign(:pairing_message, gateway_connect_error_message(payload))}
  end

  @impl true
  def handle_info({:openclaw_gateway, :disconnected, _payload}, socket) do
    {:noreply,
     socket
     |> assign(:pairing_message, "Gateway disconnected. Waiting for a reconnect after pairing.")}
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
  def handle_info({:openclaw_gateway, _event, _payload}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open-gateway", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  defp gateway_pairing_message(payload) when is_map(payload) do
    message = map_string(payload, "message")
    request_id = map_get(payload, "details") |> map_string("requestId")

    base = message || "OpenClaw is waiting for this device to be paired."

    if is_binary(request_id) do
      "#{base} Pairing request: #{request_id}"
    else
      base
    end
  end

  defp gateway_pairing_message(_), do: nil

  defp gateway_pairing_message_hint(_payload),
    do:
      "Approve this device in the OpenClaw Control UI, or alternatively, use `openclaw tui` and ask your agent to approve pending pairing requests."

  defp gateway_connect_error_message(payload) when is_map(payload) do
    map_string(payload, "message") || "Gateway returned a connection error."
  end

  defp gateway_connect_error_message(_), do: "Gateway returned a connection error."

  defp map_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
end
