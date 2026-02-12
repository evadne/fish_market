defmodule FishMarket.OpenClaw.Message do
  @moduledoc """
  Helpers for extracting display text from OpenClaw chat message payloads.
  """

  @type chat_message :: map()

  @spec extract_text(term()) :: String.t() | nil
  def extract_text(message) when is_map(message) do
    role = map_string(message, "role") || ""

    cond do
      is_binary(map_get(message, "content")) ->
        content = map_get(message, "content")
        apply_text_filters(content, role)

      is_list(map_get(message, "content")) ->
        message
        |> map_get("content")
        |> extract_text_parts()
        |> apply_text_filters(role)

      is_binary(map_get(message, "text")) ->
        apply_text_filters(map_get(message, "text"), role)

      true ->
        nil
    end
  end

  def extract_text(_), do: nil

  @spec preview_text(term()) :: String.t()
  def preview_text(message) when is_map(message) do
    case extract_text(message) do
      text when is_binary(text) ->
        if String.trim(text) == "" do
          assistant_error_message(message) || summarize_non_text(message)
        else
          text
        end

      _ ->
        assistant_error_message(message) || summarize_non_text(message)
    end
  end

  def preview_text(_), do: "(non-text message)"

  @spec assistant_error?(term()) :: boolean()
  def assistant_error?(%{
        "role" => "assistant",
        "stopReason" => "error",
        "errorMessage" => error_message
      })
      when is_binary(error_message) and error_message != "",
      do: true

  def assistant_error?(_), do: false

  @spec assistant_error_message(term()) :: String.t() | nil
  def assistant_error_message(%{
        "role" => "assistant",
        "stopReason" => "error",
        "errorMessage" => error_message
      })
      when is_binary(error_message) and error_message != "",
      do: error_message

  def assistant_error_message(_), do: nil

  @spec role(term()) :: String.t()
  def role(message) when is_map(message) do
    map_string(message, "role") || "assistant"
  end

  def role(_), do: "assistant"

  @spec timestamp_ms(term()) :: integer() | nil
  def timestamp_ms(message) when is_map(message) do
    cond do
      is_integer(map_get(message, "timestamp")) ->
        normalize_unix_timestamp(map_get(message, "timestamp"))

      is_integer(map_get(message, "ts")) ->
        normalize_unix_timestamp(map_get(message, "ts"))

      is_binary(map_get(message, "timestamp")) ->
        parse_iso8601_timestamp(map_get(message, "timestamp"))

      true ->
        nil
    end
  end

  def timestamp_ms(_), do: nil

  defp extract_text_parts(parts) when is_list(parts) do
    parts
    |> Enum.map(fn part ->
      cond do
        is_map(part) and map_get(part, "type") == "text" and is_binary(map_get(part, "text")) ->
          map_get(part, "text")

        true ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.join(values, "\n")
    end
  end

  defp apply_text_filters(nil, _role), do: nil

  defp apply_text_filters(text, role) when is_binary(text) do
    case role do
      "assistant" -> strip_thinking_tags(text)
      _ -> strip_envelope(text)
    end
  end

  defp strip_thinking_tags(text) do
    text
    |> String.replace(~r/<\s*thinking\s*>[\s\S]*?<\s*\/\s*thinking\s*>/i, "")
    |> String.replace(~r/<\s*think\s*>[\s\S]*?<\s*\/\s*think\s*>/i, "")
    |> String.trim()
  end

  defp strip_envelope(text) do
    case Regex.run(~r/^\[[^\]]+\]\s*(.+)$/s, text, capture: :all_but_first) do
      [body] -> String.trim(body)
      _ -> String.trim(text)
    end
  end

  defp summarize_non_text(message) do
    content = map_get(message, "content")
    tool_names = extract_tool_call_names(content)

    cond do
      tool_names != [] ->
        "tool call: #{Enum.join(tool_names, ", ")}"

      true ->
        non_text_types = extract_non_text_types(content)
        summarize_non_text_fallback(message, non_text_types)
    end
  end

  defp summarize_non_text_fallback(_message, non_text_types) when non_text_types != [] do
    "non-text: #{Enum.join(non_text_types, ", ")}"
  end

  defp summarize_non_text_fallback(message, _non_text_types) do
    case String.downcase(role(message)) do
      value when value in ["tool", "toolresult", "tool_result"] -> "tool result"
      _ -> "(non-text message)"
    end
  end

  defp extract_tool_call_names(parts) when is_list(parts) do
    parts
    |> Enum.map(fn part ->
      if is_map(part) and tool_call_type?(part) do
        map_string(part, "name") || "(unnamed)"
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_tool_call_names(_), do: []

  defp extract_non_text_types(parts) when is_list(parts) do
    parts
    |> Enum.map(fn part ->
      if is_map(part) do
        map_string(part, "type")
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 in ["text", "input_text", "output_text"]))
    |> Enum.map(&String.replace(&1, "_", " "))
    |> Enum.uniq()
  end

  defp extract_non_text_types(_), do: []

  defp tool_call_type?(part) do
    case map_string(part, "type") do
      value when is_binary(value) ->
        normalized = String.downcase(value)
        normalized in ["toolcall", "tool_call"]

      _ ->
        false
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

  defp parse_iso8601_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)

  defp map_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
