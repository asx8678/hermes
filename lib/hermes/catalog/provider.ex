defmodule Hermes.Catalog.Provider do
  @moduledoc """
  Ecto schema for a custom or overridden provider in the model/provider
  catalog.

  A provider names an LLM backend and the transport `kind` used to talk to it
  (`"openai"`, `"anthropic"`, or `"mock"`). For OpenAI-compatible endpoints,
  `base_url` points at the API root (e.g. a custom or self-hosted endpoint) and
  the credential is resolved at call time from either the stored `api_key` or
  the named `api_key_env` environment variable.

  When `config :hermes, :catalog_encrypt_key` is set to a 32-byte base64-encoded
  key, the stored `api_key` is encrypted at rest with AES-256-GCM. When the key
  is absent, values are stored in plain text for backward compatibility.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(openai anthropic mock)

  @iv_len 12
  @tag_len 16
  @key_len 32
  @encrypted_prefix "ENC:"

  @primary_key {:name, :string, autogenerate: false}
  schema "providers" do
    field :label, :string
    field :kind, :string, default: "openai"
    field :base_url, :string
    field :api_key, :string
    field :api_key_env, :string
    field :is_default, :integer, default: 0

    timestamps()
  end

  @castable [:name, :label, :kind, :base_url, :api_key, :api_key_env, :is_default]

  @doc """
  Builds a changeset for a provider.

  When an encryption key is configured, the `api_key` change is encrypted
  before insert/update. Existing encrypted values that are not modified are
  left untouched.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @castable)
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> maybe_encrypt_api_key()
  end

  @doc """
  Loads a provider struct, decrypting the stored `api_key` when an encryption
  key is configured and the value was previously encrypted.

  Callers should use this after reading a provider from the database before
  accessing `api_key`.
  """
  @spec load(t()) :: t()
  def load(%__MODULE__{} = provider) do
    %{provider | api_key: decrypt(provider.api_key)}
  end

  @doc "Returns the list of valid transport kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Encrypts a plain-text value using AES-256-GCM.

  Returns the original value when no encryption key is configured.
  """
  @spec encrypt(String.t() | nil) :: String.t() | nil
  def encrypt(nil), do: nil
  def encrypt(""), do: ""

  def encrypt(plain_text) when is_binary(plain_text) do
    case fetch_encrypt_key() do
      nil -> plain_text
      key -> encrypt_with_key(plain_text, key)
    end
  end

  @doc """
  Decrypts a value previously encrypted with `encrypt/1`.

  Returns plain-text values unchanged. If the value is encrypted but no key
  is configured, the ciphertext is returned as-is.
  """
  @spec decrypt(String.t() | nil) :: String.t() | nil
  def decrypt(nil), do: nil
  def decrypt(""), do: ""

  def decrypt(@encrypted_prefix <> encoded) when is_binary(encoded) do
    case fetch_encrypt_key() do
      nil ->
        @encrypted_prefix <> encoded

      key ->
        try do
          decoded = Base.decode64!(encoded)
          <<iv::binary-size(@iv_len), tag::binary-size(@tag_len), cipher::binary>> = decoded
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, "", tag, false)
        rescue
          _ -> @encrypted_prefix <> encoded
        end
    end
  end

  def decrypt(plain_text) when is_binary(plain_text), do: plain_text

  defp maybe_encrypt_api_key(changeset) do
    case {get_change(changeset, :api_key), fetch_encrypt_key()} do
      {nil, _} ->
        changeset

      {"", _} ->
        changeset

      {plain_key, key} when is_binary(plain_key) and is_binary(key) ->
        if String.starts_with?(plain_key, @encrypted_prefix) do
          changeset
        else
          put_change(changeset, :api_key, encrypt_with_key(plain_key, key))
        end

      {_, _} ->
        changeset
    end
  end

  defp encrypt_with_key(plain_text, key) do
    iv = :crypto.strong_rand_bytes(@iv_len)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plain_text, "", @tag_len, true)
    @encrypted_prefix <> Base.encode64(iv <> tag <> cipher)
  end

  defp fetch_encrypt_key do
    case Application.get_env(:hermes, :catalog_encrypt_key) || System.get_env("HERMES_CATALOG_ENCRYPT_KEY") do
      nil ->
        nil

      encoded when is_binary(encoded) and byte_size(encoded) > 0 ->
        try do
          key = Base.decode64!(encoded)

          if byte_size(key) == @key_len do
            key
          else
            nil
          end
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_name(other), do: other
end
