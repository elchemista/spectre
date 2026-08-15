defmodule Spectre.Inference.FrozenSelection do
  @moduledoc """
  Portable proof of the model selection accepted for one provider attempt.

  The executable model binding is deliberately absent. `model_ref` is a
  digest used to verify that a binding resolved locally at dispatch still
  denotes the selection committed with the Run.
  """

  alias Spectre.Inference.Selection
  alias Spectre.Run.Value

  @enforce_keys [:request_id, :model_ref, :selector_ref, :attempt]
  defstruct [
    :request_id,
    :level,
    :model_ref,
    :reason,
    :selector_ref,
    :profile_hash,
    attempt: 1,
    fallback_chain: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          level: term(),
          model_ref: String.t(),
          reason: term(),
          selector_ref: String.t(),
          profile_hash: String.t() | nil,
          attempt: pos_integer(),
          fallback_chain: [term()],
          metadata: map()
        }

  @doc false
  @spec from_selection(Selection.t()) :: t()
  def from_selection(%Selection{} = selection) do
    frozen = %__MODULE__{
      request_id: selection.request_id,
      level: selection.level,
      model_ref: model_ref(selection.model),
      reason: selection.reason,
      selector_ref: Atom.to_string(selection.selector),
      profile_hash: selection.profile_hash,
      attempt: selection.attempt,
      # Executable fallback bindings can contain clients or credentials. The
      # durable selection keeps only their stable identities; live retries
      # resolve the actual binding again through the Instance runtime opts.
      fallback_chain: Enum.map(selection.fallback_chain, &model_ref/1),
      metadata: portable_metadata(selection.metadata)
    }

    case validate(frozen) do
      :ok -> frozen
      {:error, reason} -> raise ArgumentError, "invalid frozen selection: #{inspect(reason)}"
    end
  end

  @doc "Returns a secret-free identity for an executable model binding."
  @spec model_ref(term()) :: String.t()
  def model_ref(model) do
    Value.token("model", safe_model_identity(model))
  end

  @doc false
  @spec matches_binding?(t(), term()) :: boolean()
  def matches_binding?(%__MODULE__{model_ref: expected}, model),
    do: model_ref(model) == expected

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # Frozen selections are replay evidence, so their complete portable shape is
  # checked at a single trust boundary.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = selection) do
    cond do
      not nonempty_binary?(selection.request_id) ->
        {:error, :invalid_frozen_selection_request_id}

      not nonempty_binary?(selection.model_ref) ->
        {:error, :invalid_frozen_selection_model_ref}

      not nonempty_binary?(selection.selector_ref) ->
        {:error, :invalid_frozen_selection_selector_ref}

      not is_integer(selection.attempt) or selection.attempt < 1 ->
        {:error, :invalid_frozen_selection_attempt}

      not is_list(selection.fallback_chain) ->
        {:error, :invalid_frozen_selection_fallback_chain}

      not is_map(selection.metadata) or is_struct(selection.metadata) ->
        {:error, :invalid_frozen_selection_metadata}

      true ->
        Value.validate(selection, [:frozen_selection])
    end
  end

  defp safe_model_identity(model) when is_function(model) do
    info = Function.info(model)

    # Two closures can share module/name/arity while capturing different
    # clients or credentials. Hashing the external fun representation keeps
    # those live bindings distinct without placing the captured environment
    # in the durable selection.
    closure_digest = :crypto.hash(:sha256, :erlang.term_to_binary(model))

    {
      :function,
      info[:module],
      info[:name],
      info[:arity],
      info[:uniq],
      info[:index],
      closure_digest
    }
  end

  defp safe_model_identity(model), do: model

  defp portable_metadata(metadata) when is_map(metadata) do
    metadata =
      Map.drop(metadata, [
        :api_key,
        :token,
        :secret,
        :credentials,
        "api_key",
        "token",
        "secret",
        "credentials"
      ])

    case Value.validate(metadata) do
      :ok -> metadata
      {:error, _reason} -> %{}
    end
  end

  defp portable_metadata(_metadata), do: %{}
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
