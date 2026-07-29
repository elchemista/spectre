defmodule Spectre.Run.Ref do
  @moduledoc """
  Opaque, revision-fenced reference to an observable point in a `Spectre.Run`.

  A reference contains only logical identifiers. It is therefore safe to put
  on a transport envelope or use as part of an idempotency key; it never
  contains the Run continuation, runtime options, provider clients, or process
  handles.
  """

  alias Spectre.Run.Value

  @enforce_keys [:run_id, :revision, :kind, :boundary_id]
  defstruct [:run_id, :revision, :kind, :boundary_id, :subject_id]

  @type kind :: :reply | :policy | :invocation | :complete | :error

  @type t :: %__MODULE__{
          run_id: String.t(),
          revision: non_neg_integer(),
          kind: kind(),
          boundary_id: String.t(),
          subject_id: String.t() | nil
        }

  @doc false
  @spec new(String.t(), non_neg_integer(), kind(), String.t(), term()) :: t()
  def new(run_id, revision, kind, boundary_id, subject_id \\ nil)
      when is_binary(run_id) and run_id != "" and is_integer(revision) and revision >= 0 and
             kind in [:reply, :policy, :invocation, :complete, :error] and
             is_binary(boundary_id) and boundary_id != "" do
    case Value.opaque_id(subject_id, "subject") do
      {:ok, opaque_subject_id} ->
        %__MODULE__{
          run_id: run_id,
          revision: revision,
          kind: kind,
          boundary_id: boundary_id,
          subject_id: opaque_subject_id
        }

      {:error, reason} ->
        raise ArgumentError, "non-portable Run reference subject: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a stable, privacy-safe token suitable for transport idempotency.
  """
  @spec token(t()) :: String.t()
  def token(%__MODULE__{} = ref) do
    digest =
      {ref.run_id, ref.revision, ref.kind, ref.boundary_id, ref.subject_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "run:" <> binary_part(digest, 0, 32)
  end
end
