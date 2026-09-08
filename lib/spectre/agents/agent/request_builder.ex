defmodule Spectre.Agent.RequestBuilder do
  @moduledoc """
  Preparation-only bridge from handler requests to ordinary Candidates.

  The host supplies fixed class bindings, or a declared request adapter with
  prepare/4. That callback prepares data locally; it must not perform the
  requested effect or call a remote model. Every result is rebuilt by Mind and
  Candidate, then evaluated by the kernel only after Instance.advance.

  Consequence boundaries and Row reuse the real Surface contract. No default
  Mandate, executor, purpose, accountable Principal or consent is invented.

  This module also provides the default prepare/4 implementation. A custom
  adapter can delegate ordinary requests here and handle only its own data
  preparation. The same fixed-field checks run after either implementation;
  an adapter cannot override them or authorize its own result.
  """

  alias Spectre.{Adapter, Candidate, Mind, Portable, Row, Surface}
  alias Spectre.Agent.Wiring
  alias Spectre.Candidate.Template
  alias Spectre.Consequence.Contract
  @annotations ["disclosure_to", "meter"]

  @type operation :: {:request | :ask | :classify, atom() | String.t()}
  @callback prepare(operation(), term(), Spectre.Agent.Turn.t(), keyword()) ::
              {:ok, map() | keyword()} | {:error, term()}

  @doc "Normalizes optional authoring constraints without inventing occurrence fields or authority."
  @spec template(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def template(value) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             value,
             (Candidate.request_fields() -- [:identity_key, :row]) ++ [:disclosure_to, :meter],
             :request_template
           ),
         {:ok, fixed} <- Template.new(Map.drop(attrs, [:disclosure_to, :meter])),
         {:ok, destinations} <-
           Portable.normalize_refs(List.wrap(attrs[:disclosure_to]), :disclosure_to),
         {:ok, meters} <- meter_names(Map.get(attrs, :meter, %{})) do
      {:ok, fixed |> Map.put("disclosure_to", destinations) |> Map.put("meter", meters)}
    end
  end

  @doc """
  Prepares plain consequence data using the immutable :declaration option.

  Named request templates reject attempts to replace fixed fields. Direct
  classes and ask/classify declarations need an explicit class. There is no
  I/O, provider selection or permission default here. The authoring runtime
  supplies :declaration; host wiring cannot replace it.
  """
  @spec prepare(operation(), term(), Spectre.Agent.Turn.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare({:request, name}, data, _turn, opts) when is_atom(name) do
    case Keyword.get(opts, :declaration) do
      nil -> {:error, {:unknown_request_template, name}}
      template -> Template.bind(Map.drop(template, @annotations), consequence: data)
    end
  end

  def prepare({kind, name}, data, _turn, opts) when kind in [:request, :ask, :classify] do
    case Keyword.get(opts, :declaration) do
      %{class: class} -> {:ok, %{class: class, consequence: data}}
      _missing -> {:error, {:request_class_required, kind, name}}
    end
  end

  def prepare(_operation, _data, _turn, _opts), do: {:error, :invalid_handler_request}

  @doc false
  def build(operation, data, turn, owner, runtime, ref) do
    with {:ok, attrs} <- prepared_fields(operation, data, turn, owner, runtime),
         :ok <- absent(attrs, [:identity_key, :row]),
         {:ok, row} <- Surface.classify(runtime.surface, attrs[:class]),
         {:ok, attrs} <- boundaries(runtime.surface, attrs, turn, row.disclose),
         :ok <- template_constraints(operation, attrs, owner.plan),
         attrs = attrs |> Map.put(:identity_key, ref) |> Map.put(:row, Row.canonical(row)) do
      Mind.candidate(turn.mind_turn, attrs)
    end
  end

  @doc false
  def low_level(candidate, turn) do
    with {:ok, candidate} <- Candidate.new(candidate),
         {:ok, rebound} <-
           Mind.candidate(
             turn.mind_turn,
             candidate |> Map.from_struct() |> Map.take(Candidate.request_fields())
           ),
         true <- candidate === rebound do
      {:ok, candidate}
    else
      false -> {:error, :candidate_turn_mismatch}
      error -> error
    end
  end

  defp prepared_fields({kind, name} = operation, data, turn, owner, runtime) do
    {module, opts} =
      case request_adapter(kind, name, owner, runtime.wiring) do
        {:ok, adapter} -> adapter
        :error -> {__MODULE__, []}
      end

    opts = Keyword.put(opts, :declaration, declaration(kind, name, owner.plan))

    # Adapters may fill in missing details, not replace the class or fixed
    # fields the author declared under this operation name. Normalize each
    # independent input once, then merge only those normalized maps.
    with {:ok, {:ok, attrs}} <- Adapter.invoke(module, :prepare, [operation, data, turn, opts]),
         {:ok, attrs} <-
           Portable.normalize_attrs(attrs, Candidate.request_fields(), :prepared_request),
         {:ok, fixed} <- fixed_fields(kind, name, owner.plan),
         {:ok, attrs} <- merge_exact(fixed, attrs) do
      merge_binding(attrs, runtime.bindings)
    else
      {:ok, {:error, _} = error} -> error
      {:ok, _invalid} -> {:error, :invalid_request_adapter_reply}
      {:error, _} = error -> error
    end
  end

  defp declaration(:ask, name, plan), do: Map.get(plan.asks, to_string(name), %{})

  defp declaration(:classify, name, plan),
    do: Map.get(plan.settings, "classifier/" <> to_string(name), %{})

  defp declaration(:request, name, plan) when is_atom(name),
    do: Map.get(plan.requests, Atom.to_string(name))

  defp declaration(:request, class, _plan), do: %{class: class}

  defp fixed_fields(:request, name, plan) when is_atom(name),
    do:
      Portable.normalize_attrs(
        Map.drop(declaration(:request, name, plan) || %{}, @annotations),
        Candidate.request_fields(),
        :request_template
      )

  defp fixed_fields(kind, name, plan),
    do: {:ok, Map.take(declaration(kind, name, plan), [:class])}

  defp request_adapter(kind, name, owner, wiring) do
    case Wiring.fetch(wiring, owner.prefix, :request, name) do
      :error when kind == :classify ->
        Wiring.fetch(wiring, owner.prefix, :classifier, name)

      :error when kind == :ask ->
        declaration = Map.get(owner.plan.asks, to_string(name), %{})

        case Map.get(declaration, :via, Map.get(declaration, :model)) do
          nil -> :error
          port -> Wiring.fetch(wiring, owner.prefix, :request, port)
        end

      configured ->
        configured
    end
  end

  defp merge_binding(attrs, bindings) do
    # A complete explicit adapter/template needs no redundant empty entry in
    # the host binding map. Missing required fields still fail Candidate.new.
    with {:ok, fixed} <-
           Portable.normalize_attrs(
             Map.get(bindings, attrs[:class], %{}),
             Candidate.request_fields(),
             :class_binding
           ),
         :ok <- absent(fixed, [:identity_key, :row, :class, :consequence]) do
      merge_exact(fixed, attrs)
    end
  end

  defp boundaries(surface, attrs, turn, disclose?) do
    case Map.fetch(surface.consequence_contracts, attrs[:class]) do
      {:ok, contract} ->
        with {:ok, extracted} <- Contract.bindings(contract, attrs[:consequence]),
             {:ok, attrs} <- merge_exact(attrs, Map.drop(extracted, [:destination_refs])) do
          if disclose?,
            do: disclosure(attrs, extracted.destination_refs, turn),
            else: {:ok, attrs}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp disclosure(attrs, [], _turn), do: {:ok, attrs}
  defp disclosure(%{disclosure: _} = attrs, _destinations, _turn), do: {:ok, attrs}

  defp disclosure(attrs, destinations, turn) do
    # Destinations are explicit in the class contract's consequence. Sources
    # and conservative labels are derived, never guessed or weakened.
    with {:ok, labels} <- Spectre.Mind.Turn.labels(turn.mind_turn),
         {:ok, disclosure} <-
           Spectre.Disclosure.new(
             destination_refs: destinations,
             source_evidence_refs: Spectre.Mind.Turn.evidence_refs(turn.mind_turn),
             labels: labels
           ) do
      {:ok, Map.put(attrs, :disclosure, disclosure)}
    end
  end

  defp template_constraints({:request, name}, attrs, plan) when is_atom(name) do
    declaration =
      Map.get(plan.requests, to_string(name), %{"disclosure_to" => [], "meter" => %{}})

    destinations = declaration["disclosure_to"]
    meters = Map.values(declaration["meter"])

    actual_destinations =
      case attrs[:disclosure] do
        nil ->
          []

        value ->
          Spectre.Disclosure.new(value)
          |> case do
            {:ok, disclosure} -> disclosure.destination_refs
            _invalid -> :invalid
          end
      end

    cond do
      destinations != [] and destinations !== actual_destinations ->
        {:error, :request_disclosure_constraint_mismatch}

      meters != [] and
          Enum.sort(meters) !== Enum.sort(Map.keys(Map.get(attrs, :meter_requests, %{}))) ->
        {:error, :request_meter_constraint_mismatch}

      true ->
        :ok
    end
  end

  defp template_constraints(_operation, _attrs, _plan), do: :ok

  defp meter_names(value) when is_map(value) or is_list(value) do
    if is_map(value) or Portable.keyword?(value) do
      Enum.reduce_while(value, {:ok, %{}}, fn {name, ref}, {:ok, found} ->
        with true <- is_atom(name) or is_binary(name),
             :ok <- Portable.validate_ref(ref, :meter_ref),
             false <- Map.has_key?(found, to_string(name)) do
          {:cont, {:ok, Map.put(found, to_string(name), ref)}}
        else
          _invalid -> {:halt, {:error, :invalid_request_meter_bindings}}
        end
      end)
    else
      {:error, :invalid_request_meter_bindings}
    end
  end

  defp meter_names(_value), do: {:error, :invalid_request_meter_bindings}

  defp merge_exact(left, right) do
    case Enum.find(right, fn {key, value} -> Map.has_key?(left, key) and left[key] !== value end) do
      nil -> {:ok, Map.merge(left, right)}
      {key, _value} -> {:error, {:request_binding_conflict, key}}
    end
  end

  defp absent(attrs, fields) do
    case Enum.find(fields, &Map.has_key?(attrs, &1)) do
      nil -> :ok
      field -> {:error, {:reserved_request_field, field}}
    end
  end
end
