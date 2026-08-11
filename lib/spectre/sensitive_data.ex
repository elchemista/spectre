defmodule Spectre.SensitiveData do
  @moduledoc false

  @sensitive_keys MapSet.new(~w(
    accesskey accesskeyid accesstoken apikey auth authorization bearer
    chainofthought clientsecret clienttoken cookie cookies cot credential credentials
    idtoken jwt oauth oauthcode password passphrase privatekey rawprompt refreshtoken
    secret secrets session sessionid sessiontoken token
    address birthdate dateofbirth email emailaddress firstname fullname lastname
    passport passportnumber phone phonenumber postaladdress postalcode
    socialsecuritynumber ssn streetaddress taxid userid zipcode
  ))

  @sensitive_suffix_components MapSet.new(~w(
    auth authorization bearer cookie credential jwt oauth passphrase password secret
    session token
  ))

  @sensitive_key_qualifiers MapSet.new(~w(
    access api auth client credential encryption private secret session signing
  ))

  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, normalize_key(key)) or
      sensitive_components?(key_components(key))
  end

  @spec normalize_key(term()) :: String.t()
  def normalize_key(key) when is_atom(key) and not is_nil(key),
    do: key |> Atom.to_string() |> normalize_key()

  def normalize_key(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  def normalize_key(_key), do: ""

  @spec key_components(term()) :: [String.t()]
  defp key_components(key) when is_atom(key) and not is_nil(key),
    do: key |> Atom.to_string() |> key_components()

  defp key_components(key) when is_binary(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/u, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/u, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end

  defp key_components(_key), do: []

  defp sensitive_components?(components) do
    case Enum.reverse(components) do
      ["key", qualifier | _rest] -> MapSet.member?(@sensitive_key_qualifiers, qualifier)
      [suffix | _rest] -> MapSet.member?(@sensitive_suffix_components, suffix)
      [] -> false
    end
  end

  @spec sensitive_path(term()) :: [term()] | nil
  def sensitive_path(value), do: sensitive_path(value, [])

  defp sensitive_path(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      if sensitive_key?(key) do
        Enum.reverse([key | path])
      else
        sensitive_path(item, [key_label(key) | path])
      end
    end)
  end

  defp sensitive_path(value, path) when is_list(value),
    do: list_path(value, path, 0)

  defp sensitive_path(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> list_path(path, 0)

  defp sensitive_path(_value, _path), do: nil

  defp list_path([], _path, _index), do: nil

  defp list_path([value | rest], path, index),
    do: sensitive_path(value, [index | path]) || list_path(rest, path, index + 1)

  defp list_path(_improper, path, index), do: Enum.reverse([{:tail, index} | path])

  defp key_label(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp key_label(_key), do: :key
end
