defmodule FishMarketWeb.SessionRoute do
  @moduledoc false

  @legacy_prefix "k-"
  @salt "openclaw-session-route"
  @max_age 30 * 24 * 60 * 60
  @session_key_pattern ~r/^[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+){2,}$/

  @spec encode(String.t()) :: String.t()
  def encode(session_key) when is_binary(session_key) and session_key != "" do
    Phoenix.Token.sign(FishMarketWeb.Endpoint, @salt, session_key)
  end

  @spec decode(String.t()) :: {:ok, String.t()} | :error
  def decode(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(FishMarketWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, session_key} when is_binary(session_key) ->
        if valid_session_key?(session_key) do
          {:ok, session_key}
        else
          :error
        end

      _ ->
        decode_legacy(token)
    end
  end

  def decode(_token), do: :error

  @spec valid_session_key?(String.t()) :: boolean()
  def valid_session_key?(session_key) when is_binary(session_key) do
    Regex.match?(@session_key_pattern, session_key)
  end

  def valid_session_key?(_session_key), do: false

  defp decode_legacy(@legacy_prefix <> encoded) when encoded != "" do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, session_key} when is_binary(session_key) ->
        if valid_session_key?(session_key) do
          {:ok, session_key}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp decode_legacy(session_id) when is_binary(session_id) and session_id != "" do
    session_key = URI.decode(session_id)

    if valid_session_key?(session_key) do
      {:ok, session_key}
    else
      :error
    end
  end

  defp decode_legacy(_session_id), do: :error
end
