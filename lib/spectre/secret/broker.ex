defmodule Spectre.Secret.Broker do
  @moduledoc """
  Host boundary that exchanges a committed Attempt for an execution capability.

  A broker must never return a reusable credential. The value it releases is
  scoped to the supplied executor and Act and is kept outside durable records.
  A failed checkout returns only validated Evidence and an opaque `details_ref`;
  raw credential-store errors must never become durable payloads.
  """

  alias Spectre.Act
  alias Spectre.Attempt
  alias Spectre.Evidence
  alias Spectre.Secret.CheckoutReceipt

  @type profile :: :development | :mediated | :isolated

  @type failure_metadata :: %{
          required(:evidence) => Evidence.t() | [Evidence.t()],
          required(:details_ref) => String.t()
        }

  @doc "Returns the stable identity bound into checkout receipts."
  @callback ref() :: String.t()

  @doc "Declares the strongest deployment boundary this broker actually provides."
  @callback profile() :: profile()

  @callback checkout(CheckoutReceipt.t(), Act.t(), Attempt.t(), keyword()) ::
              {:ok, term()}
              | {:error, :ambiguous, failure_metadata()}
end
