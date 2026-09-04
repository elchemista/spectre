defmodule Spectre.Seal do
  @moduledoc """
  Internal authenticity primitive for ephemeral runtime records.

  Seals are domain-separated HMACs over `Spectre.Canonical.Value` bytes. They
  protect live SubmissionContexts, Turns, Grants and checkout receipts from
  cross-boundary substitution, but are neither durable ledger signatures nor
  evidence of authority.
  """

  alias Spectre.Canonical.Value

  @minimum_secret_bytes 32

  @doc false
  @spec valid_secret?(term()) :: boolean()
  def valid_secret?(secret),
    do: is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes

  @doc false
  @spec generate_secret() :: binary()
  def generate_secret, do: :crypto.strong_rand_bytes(@minimum_secret_bytes)

  @doc false
  @spec sign(term(), binary(), binary()) :: {:ok, String.t()} | {:error, term()}
  def sign(material, secret, domain)
      when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes and
             is_binary(domain) and byte_size(domain) > 0 do
    with {:ok, encoded} <- Value.encode(material) do
      {:ok,
       secret
       |> mac(domain, encoded)
       |> Base.url_encode64(padding: false)}
    end
  end

  def sign(_material, _secret, _domain), do: {:error, :invalid_seal_material}

  @doc false
  @spec verify(term(), term(), binary(), binary()) :: :ok | :error
  def verify(material, supplied, secret, domain)
      when is_binary(supplied) and supplied != "" and is_binary(secret) and
             byte_size(secret) >= @minimum_secret_bytes and is_binary(domain) and
             byte_size(domain) > 0 do
    with {:ok, supplied} <- Base.url_decode64(supplied, padding: false),
         {:ok, encoded} <- Value.encode(material) do
      expected = mac(secret, domain, encoded)

      if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
        do: :ok,
        else: :error
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  def verify(_material, _supplied, _secret, _domain), do: :error

  defp mac(secret, domain, encoded),
    do: :crypto.mac(:hmac, :sha256, secret, domain <> encoded)
end
