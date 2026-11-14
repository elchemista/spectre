defmodule Outreach.FakeProtocol do
  use SpectreLens.Protocol.Adapter

  def new_tab(instance, opts) do
    {:ok,
     %SpectreLens.Tab{
       id: "tab-#{System.unique_integer([:positive])}",
       instance_id: instance.id,
       protocol: __MODULE__,
       handle: %{owner: instance.owner},
       url_policy: SpectreLens.URLPolicy.take_options(opts)
     }}
  end

  def close_tab(tab), do: SpectreLens.Runtime.release_tab(tab.runtime, tab)
  def navigate(_tab, _url, _opts), do: :ok
  def url(_tab), do: {:ok, "https://shop.example.test"}
  def title(_tab), do: {:ok, "Luca's Shopify store"}
  def html(_tab, _opts), do: {:ok, "<main>We build shops with Shopify.</main>"}
  def markdown(_tab, _opts), do: {:ok, "# Luca\nShopify development"}
  def semantic_tree(_tab, _opts), do: {:ok, %{"nodes" => []}}
  def interactive_elements(_tab, _opts), do: {:ok, []}
  def structured_data(_tab, _opts), do: {:ok, %{"platform" => "Shopify"}}
  def links(_tab, _opts), do: {:ok, []}
  def forms(_tab, _opts), do: {:ok, []}
end

defmodule Outreach.FakeBrowser do
  @behaviour SpectreLens.Browser
  def default_protocol, do: Outreach.FakeProtocol

  def start_instance(index, opts) do
    {:ok,
     %SpectreLens.Browser.Instance{
       id: index,
       backend: __MODULE__,
       protocol: Outreach.FakeProtocol,
       owner: Keyword.get(opts, :test_pid, self())
     }}
  end

  def stop_instance(_instance), do: :ok
  def max_tabs(_instance, _opts), do: 8
end

defmodule Outreach.FakeModel do
  def complete(prompt, _opts) do
    Outreach.Sink.model_call()

    if String.contains?(prompt, "Shopify") do
      {:ok,
       "Prepared a message.\n<al>SEND EMAIL TO=\"dev@example.com\" BODY=\"Your Shopify site looks interesting\"</al>"}
    else
      {:error, :site_context_missing}
    end
  end
end

defmodule Outreach.Sink do
  use Agent

  def start_link(_),
    do:
      Agent.start_link(
        fn -> %{email: [], notice: [], model_calls: 0, attempts: %{email: 0, notice: 0}} end,
        name: __MODULE__
      )

  def deliver(kind, to, content) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = update_in(state, [:attempts, kind], &(&1 + 1))
      previous = Map.fetch!(state, kind)

      if Enum.any?(previous, &(&1.to == to)) do
        {{:error, :already_contacted}, state}
      else
        receipt = %{to: to, content: content, id: "SIMULATED-#{kind}-#{length(previous) + 1}"}
        {{:ok, receipt}, Map.put(state, kind, previous ++ [receipt])}
      end
    end)
  end

  def model_call,
    do: Agent.update(__MODULE__, &Map.update!(&1, :model_calls, fn count -> count + 1 end))

  def snapshot, do: Agent.get(__MODULE__, & &1)
end

defmodule Outreach.Actions do
  use SpectreKinetic
  @al ~s(SEND EMAIL TO="dev@example.com" BODY="Your Shopify site looks interesting")
  @doc "Send a personalized email to the requested recipient."
  @spec send_email(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_email(to, body), do: Outreach.Sink.deliver(:email, to, body)
end

defmodule Outreach.FakeChannel do
  def capabilities(_opts), do: [:text]

  def deliver(outbound, _opts) do
    with {:ok, receipt} <- Outreach.Sink.deliver(:notice, outbound.to, outbound.content),
         do: {:ok, Spectre.Beam.Receipt.accepted(outbound, provider_message_id: receipt.id)}
  end
end
