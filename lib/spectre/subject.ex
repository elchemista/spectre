defmodule Spectre.Subject do
  @moduledoc """
  Canonical person or entity identity owned by an Agent Instance.

  A Subject is deliberately distinct from a channel sender, chat, phone
  number, or conversation id. External identities reach a Subject only through
  explicit `Spectre.SubjectLink` records.
  """

  alias Spectre.Run.Value

  @enforce_keys [:id]
  defstruct [:id, metadata: %{}]

  @type t :: %__MODULE__{id: String.t(), metadata: map()}

  @doc """
  Normalizes a portable application identity into a canonical Subject.
  """
  @spec new(t() | term(), keyword()) :: t()
  def new(subject, opts \\ [])

  def new(%__MODULE__{} = subject, _opts), do: validate!(subject)

  def new(value, opts) when is_list(opts) and not is_nil(value) do
    id = Value.logical_id(value, "subject")
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{id: id, metadata: metadata}
    |> validate!()
  end

  @doc """
  Returns an opaque key for Instance and Subject Registry indexes.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = subject) do
    subject = validate!(subject)
    Value.token("subject", subject.id)
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = subject) do
    cond do
      not (is_binary(subject.id) and subject.id != "") ->
        {:error, {:invalid_subject_id, subject.id}}

      not is_map(subject.metadata) ->
        {:error, {:invalid_subject_metadata, subject.metadata}}

      true ->
        Value.validate(subject, [:subject])
    end
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = subject) do
    case validate(subject) do
      :ok -> subject
      {:error, reason} -> raise ArgumentError, "invalid Subject: #{inspect(reason)}"
    end
  end
end
