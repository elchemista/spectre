defmodule Spectre.Forge.Critic do
  @moduledoc """
  Compiled adapter contract for model-backed Forge critique, including Prism.

  Core passes only the portable Reflection projection and redacted Experience
  snapshot. Adapter modules are registered by host code; model output can
  return opinion and a proposed falsifiable case, never executable code.
  """

  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Forge.Critique
  alias Spectre.Governance.Data
  alias Spectre.Projection
  alias Spectre.Projection.Reflection

  @max_critics 16

  @callback id() :: String.t()
  @callback version() :: pos_integer()
  @callback profile_ref() :: String.t()
  @callback critique(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Returns the compiled critic adapter contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: 1

  @doc "Runs each compiled critic and returns attributed, digest-bound results."
  @spec run([module()], Projection.t(), ExperienceStore.snapshot(), keyword()) ::
          {:ok, [Critique.t()]} | {:error, term()}
  def run(critics, reflection, snapshot, opts \\ [])

  def run(critics, %Projection{} = reflection, snapshot, opts)
      when is_list(critics) and length(critics) <= @max_critics and is_list(opts) do
    with :ok <- options(opts),
         :ok <- ExperienceStore.verify_snapshot(snapshot),
         :ok <- reflection_shape(reflection),
         {:ok, results} <- invoke_all(critics, reflection, snapshot, opts),
         :ok <- unique_critics(results) do
      {:ok, results}
    end
  end

  def run(critics, _reflection, _snapshot, _opts)
      when is_list(critics) and length(critics) > @max_critics,
      do: {:error, {:forge_critic_limit_exceeded, length(critics), @max_critics}}

  def run(_critics, _reflection, _snapshot, _opts),
    do: {:error, :invalid_forge_critics}

  defp invoke_all(critics, reflection, snapshot, opts) do
    critics
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {critic, index}, {:ok, results} ->
      case invoke(critic, reflection, snapshot, opts) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, {:forge_critic_failed, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end)
  end

  defp invoke(critic, reflection, snapshot, opts) do
    with :ok <- ensure_critic(critic),
         {:ok, metadata} <- critic_metadata(critic),
         {:ok, response} <- call_critic(critic, reflection, snapshot, opts),
         {:ok, response} <- response(response) do
      Critique.new(%{
        schema_version: 1,
        critic_id: metadata.id,
        critic_version: metadata.version,
        profile_ref: metadata.profile_ref,
        reflection_digest: reflection.digest,
        experience_snapshot_digest: snapshot.digest,
        opinion: Map.get(response, "opinion"),
        eval_case: Map.get(response, "eval_case"),
        oracle_ref: Map.get(response, "oracle_ref"),
        provenance: Map.get(response, "provenance", %{})
      })
    end
  end

  defp call_critic(critic, reflection, snapshot, opts) do
    critic.critique(
      Reflection.to_data(reflection),
      snapshot_data(snapshot),
      Keyword.get(opts, :critic_opts, [])
    )
  rescue
    exception -> {:error, {:forge_critic_exception, critic, exception.__struct__}}
  catch
    kind, reason -> {:error, {:forge_critic_failure, critic, kind, reason}}
  end

  defp response({:ok, value}), do: response(value)
  defp response({:error, _reason} = error), do: error

  defp response(value) when is_map(value) and not is_struct(value) do
    fields = [:opinion, :eval_case, :oracle_ref, :provenance]
    allowed = Enum.flat_map(fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(value, fields)

    case {Map.keys(value) -- allowed, collisions} do
      {[], []} ->
        Data.normalize_map(value)

      {unknown, []} ->
        {:error, {:unknown_forge_critic_response_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_forge_critic_response_fields, collisions}}
    end
  end

  defp response(value), do: {:error, {:invalid_forge_critic_response, shape(value)}}

  defp ensure_critic(critic) when is_atom(critic) and not is_nil(critic) do
    callbacks = [id: 0, version: 0, profile_ref: 0, critique: 3]

    if Code.ensure_loaded?(critic) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(critic, name, arity) end),
       do: :ok,
       else: {:error, {:invalid_forge_critic_adapter, critic}}
  end

  defp ensure_critic(value), do: {:error, {:invalid_forge_critic_adapter, value}}

  defp critic_metadata(critic) do
    metadata = %{id: critic.id(), version: critic.version(), profile_ref: critic.profile_ref()}

    cond do
      not (is_binary(metadata.id) and metadata.id != "") ->
        {:error, {:invalid_forge_critic_id, critic}}

      not (is_integer(metadata.version) and metadata.version > 0) ->
        {:error, {:invalid_forge_critic_version, critic}}

      not (is_binary(metadata.profile_ref) and metadata.profile_ref != "") ->
        {:error, {:invalid_forge_critic_profile, critic}}

      true ->
        {:ok, metadata}
    end
  rescue
    exception -> {:error, {:forge_critic_exception, critic, exception.__struct__}}
  end

  defp reflection_shape(reflection) do
    with :ok <- Projection.verify_ref(reflection, reflection.definition_ref),
         "spectre.projection.reflection" <- reflection.generator_id,
         1 <- reflection.generator_version do
      :ok
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_forge_reflection_projection}
    end
  end

  defp snapshot_data(snapshot) do
    %{
      "definition_ref" => Spectre.Definition.Ref.to_string(snapshot.definition_ref),
      "as_of" => snapshot.as_of,
      "evidence_refs" => snapshot.evidence_refs,
      "evidence" => Enum.map(snapshot.evidence, &Evidence.to_data/1),
      "digest" => snapshot.digest
    }
  end

  defp unique_critics(results) do
    identities = Enum.map(results, &{&1.critic_id, &1.critic_version, &1.profile_ref})

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: {:error, :duplicate_forge_critic_identity}
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_forge_critic_options}
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
