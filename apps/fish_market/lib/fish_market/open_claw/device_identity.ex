defmodule FishMarket.OpenClaw.DeviceIdentity do
  @moduledoc """
  Persistent Ed25519 device identity for OpenClaw connect authentication.
  """

  require Logger

  @version 1
  @identity_dir "identity"
  @identity_file "device.json"

  @default_scopes [
    "operator.admin",
    "operator.approvals",
    "operator.pairing"
  ]

  @type t :: %{
          device_id: String.t(),
          public_key: binary(),
          private_key: binary()
        }

  @type connect_opts :: %{
          role: String.t(),
          scopes: [String.t()],
          token: String.t() | nil,
          nonce: String.t() | nil,
          signed_at: integer() | nil
        }

  @spec load_or_create_identity(String.t() | nil) :: t()
  def load_or_create_identity(xdg_config_home \\ nil) do
    identity_file_path = resolve_identity_path(xdg_config_home)
    identity_dir = Path.dirname(identity_file_path)

    identity_file_path
    |> read_identity()
    |> case do
      {:ok, identity} ->
        identity

      {:error, reason} ->
        Logger.warning("[openclaw] failed to load existing device identity: #{inspect(reason)}")
        create_identity(identity_file_path, identity_dir)
    end
  end

  @spec scopes() :: [String.t()]
  def scopes, do: @default_scopes

  @spec build_connect_device(
          identity :: t(),
          opts :: connect_opts()
        ) :: %{
          String.t() => String.t() | non_neg_integer()
        }
  def build_connect_device(identity, opts) do
    role = Map.fetch!(opts, :role)
    scopes = Map.fetch!(opts, :scopes)
    token = Map.fetch!(opts, :token)
    signed_at = Map.get(opts, :signed_at, System.system_time(:millisecond))
    nonce = Map.get(opts, :nonce)

    payload = build_payload(identity.device_id, role, scopes, token, nonce, signed_at)
    signature = sign_payload(identity.private_key, payload)

    device = %{
      "id" => identity.device_id,
      "publicKey" => encode_identity_key(identity.public_key),
      "signature" => signature,
      "signedAt" => signed_at
    }

    clean_nonce =
      case nonce do
        nil -> nil
        value -> String.trim(value)
      end

    if is_binary(clean_nonce) and byte_size(clean_nonce) > 0 do
      Map.put(device, "nonce", clean_nonce)
    else
      device
    end
  end

  @spec resolve_identity_path(String.t() | nil) :: String.t()
  def resolve_identity_path(xdg_config_home \\ nil) do
    [xdg_config_base(xdg_config_home), "fish-market", @identity_dir, @identity_file]
    |> Path.join()
  end

  defp xdg_config_base(nil) do
    Path.expand("~/.config")
  end

  defp xdg_config_base(raw) do
    raw
    |> String.trim()
    |> case do
      "" -> Path.expand("~/.config")
      value -> Path.expand(value)
    end
  end

  defp read_identity(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, parsed} <- Jason.decode(raw),
         {:ok, identity} <- validate_identity(parsed) do
      {:ok, identity}
    else
      {:error, _} = error -> error
    end
  end

  defp validate_identity(%{
         "version" => @version,
         "deviceId" => device_id,
         "publicKeyBase64" => public_key_b64,
         "privateKeyBase64" => private_key_b64
       })
       when is_binary(device_id) and is_binary(public_key_b64) and is_binary(private_key_b64) do
    case decode_identity_key(public_key_b64) do
      {:ok, public_key} ->
        case decode_identity_key(private_key_b64) do
          {:ok, private_key} ->
            if derive_device_id(public_key) == device_id and byte_size(public_key) == 32 and
                 byte_size(private_key) == 32 do
              {:ok,
               %{
                 device_id: device_id,
                 public_key: public_key,
                 private_key: private_key
               }}
            else
              {:error, :identity_mismatch}
            end

          :error ->
            {:error, :invalid_identity}
        end

      :error ->
        {:error, :invalid_identity}
    end
  end

  defp validate_identity(_), do: {:error, :invalid_identity}

  defp create_identity(path, dir) do
    identity = generate_identity()
    :ok = File.mkdir_p(dir)
    set_permissions(dir, 0o700)

    payload = %{
      version: @version,
      deviceId: identity.device_id,
      publicKeyBase64: encode_identity_key(identity.public_key),
      privateKeyBase64: encode_identity_key(identity.private_key),
      createdAtMs: System.system_time(:millisecond),
      updatedAtMs: System.system_time(:millisecond)
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
    set_permissions(path, 0o600)
    identity
  end

  defp generate_identity() do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      device_id: derive_device_id(public_key),
      public_key: public_key,
      private_key: private_key
    }
  end

  defp derive_device_id(public_key) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16(case: :lower)
  end

  defp build_payload(device_id, role, scopes, token, nonce, signed_at) do
    token_value = token || ""
    has_nonce = is_binary(nonce) && byte_size(String.trim(nonce)) > 0
    payload_version = if has_nonce, do: "v2", else: "v1"
    scopes_value = Enum.join(scopes, ",")

    base_parts = [
      payload_version,
      device_id,
      "gateway-client",
      "backend",
      role,
      scopes_value,
      Integer.to_string(signed_at),
      token_value
    ]

    payload_parts =
      if has_nonce do
        base_parts ++ [String.trim(nonce)]
      else
        base_parts
      end

    Enum.join(payload_parts, "|")
  end

  defp sign_payload(private_key, payload) do
    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    |> Base.url_encode64(padding: false)
  end

  defp encode_identity_key(binary), do: Base.url_encode64(binary, padding: false)

  defp decode_identity_key(encoded) do
    Base.url_decode64(encoded, padding: false)
  end

  defp set_permissions(path, mode) do
    try do
      File.chmod(path, mode)
    rescue
      _ -> :ok
    end
  end
end
