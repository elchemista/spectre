defmodule Spectre.Server.InputWait do
  @moduledoc false

  @max_match_bytes 1_024

  @type matcher :: {String.t(), binary() | list()}
  @type t :: %{
          id: binary(),
          revision: pos_integer(),
          deadline: integer() | nil,
          prompt: String.t() | nil,
          accept: matcher() | nil
        }

  @spec options(keyword()) :: keyword()
  def options(opts) do
    opts = Keyword.put(opts, :foreground, true)

    case Keyword.fetch(opts, :accept) do
      {:ok, %Regex{} = regex} ->
        Keyword.put(opts, :accept, {Regex.source(regex), Regex.opts(regex)})

      _ ->
        opts
    end
  end

  @spec validate(keyword()) :: :ok | {:error, atom()}
  def validate(opts) do
    with :ok <- validate_matcher(opts[:accept]) do
      if is_nil(opts[:prompt]) or is_binary(opts[:prompt]),
        do: :ok,
        else: {:error, :invalid_wait_prompt}
    end
  end

  defp validate_matcher(nil), do: :ok

  defp validate_matcher({source, options})
       when is_binary(source) and byte_size(source) <= @max_match_bytes and
              (is_binary(options) or is_list(options)) do
    with true <- String.starts_with?(source, ["^", "\\A"]),
         true <- String.ends_with?(source, ["$", "\\z"]),
         {:ok, regex} <- Regex.compile(source, options),
         false <- match_regex?(regex, ""),
         false <- source in ["^.+$", "\\A.+\\z"] do
      :ok
    else
      _ -> {:error, :invalid_wait_matcher}
    end
  end

  defp validate_matcher(_), do: {:error, :invalid_wait_matcher}

  @spec matches?(matcher() | nil, String.t()) :: boolean()
  def matches?({source, opts}, text) when byte_size(text) <= @max_match_bytes do
    case Regex.compile(source, opts) do
      {:ok, regex} -> match_regex?(regex, text)
      _ -> false
    end
  end

  def matches?(_, _), do: false

  defp match_regex?(regex, text) do
    :re.run(text, Regex.re_pattern(regex), [
      {:capture, :none},
      {:match_limit, 10_000},
      {:match_limit_recursion, 1_000}
    ]) == :match
  end

  @spec put(map(), binary(), keyword()) :: map()
  def put(pending, command_id, opts) do
    Map.put(pending, :input_wait, %{
      id: command_id,
      revision: 1,
      deadline: pending.deadline,
      prompt: opts[:prompt],
      accept: opts[:accept]
    })
  end

  @spec find(map(), {term(), pos_integer()} | nil) :: map() | nil
  def find(pendings, {id, revision}) do
    Enum.find_value(pendings, fn
      {_, %{input_wait: %{id: ^id, revision: ^revision}} = pending} -> pending
      _ -> nil
    end)
  end

  def find(_pendings, nil), do: nil

  @spec live?(t()) :: boolean()
  def live?(%{deadline: nil}), do: true
  def live?(%{deadline: deadline}), do: deadline > System.system_time(:millisecond)

  @spec public(t()) :: map()
  def public(wait), do: Map.delete(wait, :accept)
end
