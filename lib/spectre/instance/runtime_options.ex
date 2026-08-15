defmodule Spectre.Instance.RuntimeOptions do
  @moduledoc false

  # Builds the immutable execution snapshot handed to Runtime workers. The
  # Instance owner calls `build/3`, so `self()` remains the authoritative PID
  # embedded in the options even though assembly lives outside the GenServer.

  alias Spectre.Instance.Activation
  alias Spectre.Instance.Conversation
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Run

  @doc false
  @spec build(InstanceState.t(), keyword(), term()) :: keyword()
  def build(%InstanceState{} = data, opts, input) when is_list(opts) do
    origin_conversation_id =
      Conversation.first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        Conversation.input_conversation_id(input)
      ])

    opts =
      data.base_opts
      |> Keyword.merge(
        Keyword.drop(opts, [
          :timeout,
          :state,
          :conversation_id,
          :origin_conversation_id,
          :subject
        ])
      )
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:subject, data.subject)
      |> Keyword.put(:subject_id, data.subject.id)
      |> Keyword.put(:conversation_id, Keyword.fetch!(data.base_opts, :conversation_id))
      |> Keyword.put(:instance_run_lifecycle?, true)
      |> Keyword.put(:instance_pid, self())
      |> Keyword.put(:instance_definition_store, data.definition_store)
      |> pin_activation(data.activation)
      |> put_if_present(:origin_conversation_id, origin_conversation_id)

    metadata =
      case Keyword.get(opts, :run_metadata, %{}) do
        value when is_map(value) -> value
        _invalid -> %{}
      end
      |> Map.merge(%{
        instance_ref: data.ref,
        agent_ref: data.agent_ref,
        subject: data.subject,
        conversation_ref: Conversation.conversation_key(input, origin_conversation_id),
        origin_conversation_ref: Conversation.origin_conversation_key(origin_conversation_id),
        runtime_skill_dispatch?: Keyword.get(opts, :runtime_skill_dispatch?, false)
      })

    Keyword.put(opts, :run_metadata, metadata)
  end

  # Admission, not worker start, selects a Run's executable Definition.
  # Queueing, activation changes, and restart must never rewrite this pin.
  @doc false
  @spec pin_run(keyword(), Run.t()) :: keyword()
  def pin_run(opts, %Run{} = run) when is_list(opts) do
    runtime_skill_dispatch? =
      Map.get(
        run.metadata,
        :runtime_skill_dispatch?,
        Map.get(run.metadata, "runtime_skill_dispatch?", false)
      )

    metadata =
      case Keyword.get(opts, :run_metadata, %{}) do
        value when is_map(value) ->
          value
          |> Map.delete("runtime_skill_dispatch?")
          |> Map.put(:runtime_skill_dispatch?, runtime_skill_dispatch? == true)

        _invalid ->
          %{runtime_skill_dispatch?: runtime_skill_dispatch? == true}
      end

    opts
    |> Keyword.put(:definition_ref, run.definition_ref)
    |> Keyword.put(:activation_generation, run.activation_generation)
    |> Keyword.put(:authority_epoch, run.authority_epoch)
    |> Keyword.put(:closure_digest, run.closure_digest)
    |> Keyword.put(:runtime_skill_dispatch?, runtime_skill_dispatch? == true)
    |> Keyword.put(:run_metadata, metadata)
  end

  defp pin_activation(opts, nil), do: opts

  defp pin_activation(opts, %Activation{} = activation) do
    opts
    |> Keyword.put(:definition_ref, activation.definition_ref)
    |> Keyword.put(:activation_generation, activation.generation)
    |> Keyword.put(:authority_epoch, activation.authority_epoch)
    |> Keyword.put(:closure_digest, activation.closure_digest)
    |> Keyword.put(
      :runtime_skill_dispatch?,
      Map.get(activation.provenance, :change_surface?, false)
    )
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)
end
