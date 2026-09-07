defmodule Spectre.Attempt.Observer do
  @moduledoc """
  Trusted Domain adapter for independently obtaining a late world observation.

  The adapter may verify a provider receipt or query an external system, but it
  does not receive an execution capability. It is fixed when the Domain starts;
  callers can supply input to it but cannot replace it per request.
  """

  alias Spectre.{Act, Attempt, Evidence, Outcome}

  @type observation :: %{
          required(:evidence) => Evidence.t() | [Evidence.t()],
          required(:details_ref) => String.t()
        }

  @type result ::
          {:ok, Outcome.status(), String.t() | nil, observation()}
          | {:error, term()}

  @callback observe(Act.t(), Attempt.t(), term(), keyword()) :: result()
end
