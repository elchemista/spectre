defmodule Spectre.Secret.Broker do
  @moduledoc """
  Host boundary that exchanges a committed Attempt for an execution capability.

  A broker must never return a reusable credential. The value it releases is
  scoped to the supplied executor and Act and is kept outside durable records.
  A failed checkout returns only validated Evidence and an opaque `details_ref`;
  raw credential-store errors must never become durable payloads.

  `use Spectre.Secret.Broker, ref: "broker:my-app", profile: :mediated`
  declares the behaviour and overridable `ref/0` and `profile/0`. Both choices
  are required: the macro cannot establish deployment isolation. Implement
  `checkout/4` explicitly; no credential access or successful checkout is
  supplied by default.
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

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Spectre.Secret.Broker
      opts = Spectre.Adapter.use_options!(opts, [:ref], profile: nil)
      @spectre_broker_ref Keyword.fetch!(opts, :ref)
      @spectre_broker_profile Keyword.fetch!(opts, :profile)

      unless @spectre_broker_profile in [:development, :mediated, :isolated] do
        raise ArgumentError, "profile must explicitly be :development, :mediated or :isolated"
      end

      @impl true
      def ref, do: @spectre_broker_ref

      @impl true
      def profile, do: @spectre_broker_profile

      defoverridable ref: 0, profile: 0
    end
  end
end
