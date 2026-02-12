defmodule FishMarketWeb.MenuLive do
  use FishMarketWeb, :live_component

  alias FishMarketWeb.SessionRoute

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
