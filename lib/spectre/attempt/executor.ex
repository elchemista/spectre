defmodule Spectre.Attempt.Executor do
  @moduledoc """
  Executes one already-committed governed Act.

  Implementations are Zone X adapters. They receive no authority to alter the
  Act; `capability` is the short-lived host handle released only after the
  corresponding Attempt has been committed.

  Results cross back into the governed record layer, so they contain only
  validated `Spectre.Evidence` and an opaque, non-empty `details_ref`. Raw
  provider replies, exceptions, credentials and reusable bearer material are
  not valid result metadata. Evidence may be empty only for an ambiguous result.
  """

  alias Spectre.Act
  alias Spectre.Attempt
  alias Spectre.Evidence

  @type observation :: %{
          required(:evidence) => Evidence.t() | [Evidence.t()],
          required(:details_ref) => String.t()
        }

  @type result ::
          {:ok, observation()}
          | {:error, :failed, observation()}
          | {:error, :definitive_no_effect, observation()}
          | {:error, :ambiguous, observation()}

  @doc "Returns the stable executor identity accepted by this adapter."
  @callback executor_ref() :: String.t()

  @doc "Returns the immutable contract revision implemented by this adapter."
  @callback contract_ref() :: String.t()

  @callback execute(Act.t(), Attempt.t(), term(), keyword()) :: result()
end
