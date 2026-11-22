defmodule Spectre.Server.GAM.Managed.Approval do
  @moduledoc """
  Transport-independent external consent for Managed GAM.

  The configured human Principal, Ed25519 key and approval mandate identify an
  approver. This trust satisfies consent only; it grants no execution authority.
  Transport adapters implement `send_message/2`. UI acknowledgements and decisions
  enter through the AgentServer's authenticated consumer, never model output.
  """
  alias Spectre.GAM
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Server.Store.Port, as: Store

  @doc "Sends an approval-protocol message. A successful transport acknowledgement records delivery only."
  @callback send_message(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @end_of_time 253_402_300_799_999

  @doc false
  def normalize(opts) do
    case Keyword.get(opts, :approvals) do
      nil ->
        {:ok, opts}

      config ->
        with true <- Keyword.keyword?(config),
             true <-
               Keyword.keys(config) --
                 [
                   :address,
                   :transport,
                   :approvers,
                   :signer,
                   :io_workers,
                   :io_timeout,
                   :maintenance_interval
                 ] == [],
             {:ok, io} <- io_options(config),
             address when is_binary(address) and address != "" <- config[:address],
             {module, transport_opts} <- config[:transport],
             true <- is_atom(module) and Code.ensure_loaded?(module),
             true <- function_exported?(module, :send_message, 2),
             true <- Keyword.keyword?(transport_opts),
             {:ok, approvers} <- normalize_approvers(config[:approvers] || %{}),
             {:ok, signer} <- normalize_signer(config[:signer]) do
          {:ok,
           Keyword.put(opts, :approvals, %{
             address: address,
             transport: {module, transport_opts},
             approvers: approvers,
             signer: signer,
             io_workers: io.workers,
             io_timeout: io.timeout,
             maintenance_interval: io.interval
           })}
        else
          _ -> {:error, :invalid_external_approvals}
        end
    end
  rescue
    _ -> {:error, :invalid_external_approvals}
  end

  defp io_options(config) do
    workers = Keyword.get(config, :io_workers, 4)
    timeout = Keyword.get(config, :io_timeout, 5_000)
    interval = config[:maintenance_interval]

    if positive?(workers) and timer?(timeout) and (is_nil(interval) or timer?(interval)),
      do: {:ok, %{workers: workers, timeout: timeout, interval: interval}},
      else: {:error, :invalid_approval_io_options}
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp timer?(value), do: positive?(value) and value <= 4_294_967_295

  defp normalize_approvers(approvers) when is_map(approvers) and not is_struct(approvers) do
    Enum.reduce_while(approvers, {:ok, %{}}, fn {address, config}, {:ok, acc} ->
      with true <- is_binary(address) and address != "",
           {:ok, trust} <- trust(Map.new(config)),
           key when is_binary(key) and byte_size(key) == 32 <- trust.public_key do
        {:cont, {:ok, Map.put(acc, address, trust)}}
      else
        _ -> {:halt, {:error, :invalid_external_approver}}
      end
    end)
  end

  defp normalize_approvers(_), do: {:error, :invalid_external_approvers}

  defp normalize_signer(nil), do: {:ok, nil}

  defp normalize_signer(config) do
    config = Map.new(config)

    with private when is_binary(private) and byte_size(private) == 32 <- config[:private_key],
         {public, _} <- :crypto.generate_key(:eddsa, :ed25519, private),
         {:ok, trust} <- trust(Map.put(config, :public_key, public)) do
      {:ok, Map.put(trust, :private_key, private)}
    else
      _ -> {:error, :invalid_external_signer}
    end
  end

  defp trust(config) do
    with {:ok, %{kind: :human} = principal} <- GAM.Principal.new(config[:principal]),
         mandate when is_binary(mandate) and mandate != "" <- config[:mandate_ref],
         deadline = Map.get(config, :expires_at, @end_of_time),
         true <- is_integer(deadline) and deadline > 0 do
      {:ok,
       %{
         principal: principal,
         mandate_ref: mandate,
         public_key: config[:public_key],
         expires_at: deadline
       }}
    else
      _ -> {:error, :invalid_external_approval_authority}
    end
  end

  @doc false
  def authority(opts) do
    case opts[:approvals] do
      nil ->
        nil

      config ->
        %{
          address: config.address,
          approvers:
            Map.new(config.approvers, fn {address, trust} -> {address, public(trust)} end),
          signer: if(config.signer, do: public(config.signer))
        }
    end
  end

  defp public(trust),
    do:
      trust
      |> Map.delete(:private_key)
      |> Map.update!(:principal, &GAM.Principal.canonical/1)

  @doc false
  def principals(opts) do
    case opts[:approvals] do
      nil ->
        []

      config ->
        (Map.values(config.approvers) ++ List.wrap(config.signer))
        |> Enum.map(& &1.principal)
        |> Enum.uniq_by(& &1.ref)
    end
  end

  @doc false
  def show_mandate(opts, operation_mandate) do
    recipients =
      case opts[:approvals] do
        nil -> []
        config -> Enum.map(config.approvers, fn {_, trust} -> trust.principal.ref end)
      end

    if recipients == [] do
      {:ok, nil}
    else
      operation_mandate
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(%{
        classes: ["presentation.show"],
        ceiling: GAM.Presentation.show_row(),
        target_refs: recipients
      })
      |> GAM.Mandate.new()
    end
  end

  @doc false
  def approver(opts, settings) do
    case Keyword.get(settings, :approver, :current_user) do
      :current_user ->
        {:ok, nil}

      {:external, address} ->
        case opts[:approvals] do
          %{approvers: %{^address => trust}} -> {:ok, {address, trust}}
          _ -> {:error, :external_approver_not_configured}
        end

      _ ->
        {:error, :invalid_managed_approver}
    end
  end

  @doc false
  def request(config, {address, trust}, presentation, show_ref, deadline, revision) do
    %{
      "type" => "approval.request",
      "id" => Spectre.Identity.uuid7(),
      "from" => config.address,
      "to" => address,
      "revision" => revision,
      "presentation_ref" => presentation.ref,
      "show_ref" => show_ref,
      "material_digest" => presentation.material_digest,
      "candidate_binding_ref" => presentation.candidate_binding_ref,
      "data_digest" => elem(GAM.Consent.data_digest(presentation.data), 1),
      "scope_ref" => presentation.scope_ref,
      "principal_ref" => trust.principal.ref,
      "mandate_ref" => trust.mandate_ref,
      "expires_at" => min(deadline, trust.expires_at),
      "rendered_payload" => presentation.rendered_payload
    }
  end

  @doc false
  def send_message(%{transport: {module, opts}}, message) do
    module.send_message(message, opts)
  rescue
    _ -> {:error, :approval_transport_failed}
  catch
    _, _ -> {:error, :approval_transport_failed}
  end

  @doc false
  def verify(config, request, response) do
    with %{to: address} <- %{to: request["to"]},
         %{^address => trust} <- config.approvers,
         true <- current?(request) and System.system_time(:millisecond) < trust.expires_at,
         true <- response["type"] in ["approval.presented", "approval.decision"],
         true <- response["from"] == request["to"] and response["to"] == request["from"],
         true <- response["relates_to"] == request["id"],
         true <- response["request_digest"] == Value.digest!(request),
         true <- response["principal_ref"] == trust.principal.ref,
         true <- response["mandate_ref"] == trust.mandate_ref,
         true <- response["decision"] in [nil, "confirm", "reject"],
         {:ok, signature} <- Base.url_decode64(response["signature"], padding: false),
         true <-
           :crypto.verify(:eddsa, :none, signing_bytes(response), signature, [
             trust.public_key,
             :ed25519
           ]) do
      {:ok, trust}
    else
      _ -> {:error, :external_approval_not_authorized}
    end
  rescue
    _ -> {:error, :external_approval_not_authorized}
  end

  defp signing_bytes(message),
    do: Value.encode!({"spectre.external-approval.v1", Map.delete(message, "signature")})

  defp current?(request),
    do:
      is_integer(request["expires_at"]) and
        System.system_time(:millisecond) < request["expires_at"]

  @doc false
  def receive_request(config, store, request) do
    with %{signer: signer} when not is_nil(signer) <- config,
         true <- request["type"] == "approval.request" and request["to"] == config.address,
         true <- request["principal_ref"] == signer.principal.ref,
         true <- request["mandate_ref"] == signer.mandate_ref,
         true <- current?(request) and System.system_time(:millisecond) < signer.expires_at,
         true <- is_integer(request["revision"]) and request["revision"] > 0,
         true <-
           Enum.all?(
             ~w(id from presentation_ref show_ref material_digest candidate_binding_ref data_digest scope_ref rendered_payload),
             &(is_binary(request[&1]) and request[&1] != "")
           ),
         :ok <- Value.validate(request) do
      insert_request(config, store, request)
    else
      _ -> {:error, :invalid_external_approval_request}
    end
  end

  defp insert_request(config, store, request) do
    key = request_key(config, request)

    value = %{
      request: request,
      digest: Value.digest!(request),
      received_at: System.system_time(:millisecond)
    }

    case store_call(store, :put_new, [key, value]) do
      {:ok, _revision} ->
        {:ok, :received, view(value)}

      {:error, :exists} ->
        with {:ok, %{value: existing}} <- store_call(store, :fetch, [key]),
             true <- Value.digest!(existing.request) == value.digest do
          {:ok, :duplicate, view(existing)}
        else
          false -> {:error, :approval_request_identity_conflict}
          error -> error
        end

      error ->
        error
    end
  end

  defp store_call(store, operation, args) do
    case apply(Store, operation, [store | args]) do
      {:error, reason} when reason not in [:exists, :conflict] ->
        {:error, {:approval_store, reason}}

      result ->
        result
    end
  end

  @doc false
  def request_key(config, request),
    do: {:external_approval, config.address, request["id"], request["from"]}

  @doc false
  def lookup(config, store, %{id: id, from: from}) when is_binary(id) and is_binary(from) do
    fetch_record(config, store, {:external_approval, config.address, id, from})
  end

  def lookup(config, store, id) when is_binary(id) do
    with :not_found <- fetch_record(config, store, {:external_approval, id}),
         {:ok, entries, _} <-
           store_call(store, :list, [
             {:external_approval, config.address, id},
             [limit: 2, max_bytes: 16_777_216]
           ]) do
      case entries do
        [{key, entry}] -> {:ok, key, entry}
        [] -> :not_found
        _ -> {:error, :approval_reference_ambiguous}
      end
    end
  end

  def lookup(_, _, _), do: {:error, :invalid_approval_reference}

  defp fetch_record(config, store, key) do
    case store_call(store, :fetch, [key]) do
      {:ok, %{value: %{request: request}} = entry} ->
        if request["to"] == config.address, do: {:ok, key, entry}, else: :not_found

      other ->
        other
    end
  end

  @doc false
  def fetch(config, store, reference) do
    with {:ok, _, entry} <- lookup(config, store, reference), do: {:ok, view(entry.value)}
  end

  @doc false
  def list(config, store, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:after, :limit, :max_bytes, :status] == [],
         status when status in [:all, :pending, :decided, :cancelled, :expired] <-
           Keyword.get(opts, :status, :all),
         {:ok, entries, cursor} <-
           store_call(store, :list, [
             {:external_approval, config.address},
             Keyword.delete(opts, :status)
           ]) do
      items =
        entries
        |> Enum.map(fn {_, entry} -> view(entry.value) end)
        |> Enum.filter(&(status == :all or &1.status == status))

      {:ok, %{version: 1, entries: items, next_cursor: cursor}}
    else
      false -> {:error, :invalid_approval_query}
      {:error, _} = error -> error
      _ -> {:error, :invalid_approval_query}
    end
  end

  def list(_, _, _), do: {:error, :invalid_approval_query}

  defp view(value) do
    request = value.request

    status =
      cond do
        value[:cancelled] -> :cancelled
        value[:terminal] -> :decided
        not current?(request) -> :expired
        true -> :pending
      end

    %{
      reference: %{id: request["id"], from: request["from"]},
      request: request,
      status: status,
      received_at: value[:received_at],
      decided_at: value[:decided_at],
      presented: value[:presented],
      decision: value[:terminal]
    }
  end

  @doc false
  def prepare_reply(config, store, reference, decision)
      when decision in [:presented, :confirm, :reject],
      do: reply_attempt(config, store, reference, decision, 8)

  def prepare_reply(_, _, _, _), do: {:error, :invalid_external_approval_decision}

  defp reply_attempt(_config, _store, _reference, _decision, 0),
    do: {:error, :approval_store_conflict}

  defp reply_attempt(config, store, reference, decision, attempts) do
    with %{signer: signer} when not is_nil(signer) <- config,
         {:ok, key, %{value: value} = entry} <- lookup(config, store, reference),
         true <- current?(value.request) and System.system_time(:millisecond) < signer.expires_at,
         false <- Map.get(value, :cancelled, false),
         true <- decision == :presented or Map.has_key?(value, :presented),
         {:ok, response} <- response(config, value.request, value, decision) do
      persist_reply({config, store, reference, decision, attempts}, key, entry, response)
    else
      {:error, {:approval_store, _}} = error -> error
      _ -> {:error, :external_approval_reply_failed}
    end
  end

  defp persist_reply({config, store, reference, decision, attempts}, key, entry, response) do
    field = if decision == :presented, do: :presented, else: :terminal

    if Map.get(entry.value, field) == response do
      {:ok, response}
    else
      updated = entry.value |> Map.put(field, response) |> stamp_decision(field)

      case store_call(store, :compare_and_swap, [key, entry.revision, updated]) do
        {:ok, _} -> {:ok, response}
        {:error, :conflict} -> reply_attempt(config, store, reference, decision, attempts - 1)
        error -> error
      end
    end
  end

  defp stamp_decision(value, :terminal),
    do: Map.put(value, :decided_at, System.system_time(:millisecond))

  defp stamp_decision(value, _), do: value

  defp response(_config, _request, %{terminal: response}, decision) do
    if response["decision"] == to_string(decision),
      do: {:ok, response},
      else: {:error, :approval_already_decided}
  end

  defp response(_config, _request, %{presented: response}, :presented), do: {:ok, response}

  defp response(config, request, _value, decision) do
    response = %{
      "type" => if(decision == :presented, do: "approval.presented", else: "approval.decision"),
      "id" => Spectre.Identity.uuid7(),
      "from" => config.address,
      "to" => request["from"],
      "relates_to" => request["id"],
      "request_digest" => Value.digest!(request),
      "principal_ref" => config.signer.principal.ref,
      "mandate_ref" => config.signer.mandate_ref,
      "decision" => if(decision != :presented, do: to_string(decision))
    }

    signature =
      :crypto.sign(:eddsa, :none, signing_bytes(response), [config.signer.private_key, :ed25519])

    {:ok, Map.put(response, "signature", Base.url_encode64(signature, padding: false))}
  end

  @doc false
  def cancel_inbox(config, store, message), do: cancel_attempt(config, store, message, 8)

  defp cancel_attempt(_, _, _, 0), do: {:error, :approval_store_conflict}

  defp cancel_attempt(config, store, message, attempts) do
    reference = %{id: message["relates_to"], from: message["from"]}

    with {:ok, key, entry} <- lookup(config, store, reference),
         request = entry.value.request,
         true <- message["to"] == config.address and message["from"] == request["from"],
         true <- message["request_digest"] == Value.digest!(request) do
      if entry.value[:cancelled] do
        {:ok, :duplicate, view(entry.value)}
      else
        value = Map.put(entry.value, :cancelled, true)

        save_cancellation(config, store, message, attempts, key, entry.revision, value)
      end
    else
      {:error, {:approval_store, _}} = error -> error
      _ -> {:error, :invalid_approval_cancellation}
    end
  end

  defp save_cancellation(config, store, message, attempts, key, revision, value) do
    case store_call(store, :compare_and_swap, [key, revision, value]) do
      {:ok, _} -> {:ok, :cancelled, view(value)}
      {:error, :conflict} -> cancel_attempt(config, store, message, attempts - 1)
      error -> error
    end
  end
end
