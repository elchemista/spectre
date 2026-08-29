defmodule SpectreStackPackageDataTest.Support do
  @moduledoc false

  def plan(package, ref, opts) do
    notify(opts, {:package_data_plan, package, ref.key, identifiers(opts)})

    case mode(opts, :plan_modes, package, :ready) do
      :ready -> {:ok, %{supported?: true}}
      :unsupported -> {:ok, %{supported?: false}}
      :invalid_ok -> {:ok, :invalid}
      {:error, reason} -> {:error, reason}
      {:raw, reply} -> reply
      {:raise, message} -> raise message
      {:throw, reason} -> throw(reason)
      {:exit, reason} -> exit(reason)
    end
  end

  def erase(package, ref, opts) do
    notify(opts, {:package_data_erase, package, ref.key, identifiers(opts)})

    case mode(opts, :erase_modes, package, :erased) do
      :erased -> {:ok, :erased}
      :already_erased -> {:ok, :already_erased}
      :already_erased_map -> {:ok, %{already_erased?: true}}
      {:error, reason} -> {:error, reason}
      {:raw, reply} -> reply
      {:raise, message} -> raise message
      {:throw, reason} -> throw(reason)
      {:exit, reason} -> exit(reason)
    end
  end

  defp mode(opts, key, package, default) do
    opts
    |> Keyword.get(key, %{})
    |> Map.get(package, default)
  end

  defp identifiers(opts) do
    {Keyword.fetch!(opts, :stack_installation), Keyword.fetch!(opts, :stack_package)}
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, message)
  end
end

defmodule SpectreStackPackageDataTest.FirstPackage do
  @moduledoc false

  @behaviour Spectre.Stack.PackageData

  use Spectre.Stack.Installable,
    id: :package_data_first,
    version: "0.1.0",
    spectre: ">= 0.3.0 and < 0.4.0"

  @impl Spectre.Stack.PackageData
  def erasure_plan(ref, opts), do: SpectreStackPackageDataTest.Support.plan(:first, ref, opts)

  @impl Spectre.Stack.PackageData
  def erase_instance(ref, opts), do: SpectreStackPackageDataTest.Support.erase(:first, ref, opts)
end

defmodule SpectreStackPackageDataTest.SecondPackage do
  @moduledoc false

  @behaviour Spectre.Stack.PackageData

  use Spectre.Stack.Installable,
    id: :package_data_second,
    version: "0.1.0",
    spectre: ">= 0.3.0 and < 0.4.0"

  @impl Spectre.Stack.PackageData
  def erasure_plan(ref, opts), do: SpectreStackPackageDataTest.Support.plan(:second, ref, opts)

  @impl Spectre.Stack.PackageData
  def erase_instance(ref, opts),
    do: SpectreStackPackageDataTest.Support.erase(:second, ref, opts)
end

defmodule SpectreStackPackageDataTest.PlanOnlyPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :package_data_plan_only,
    version: "0.1.0",
    spectre: ">= 0.3.0 and < 0.4.0"

  def erasure_plan(_ref, _opts), do: {:ok, %{supported?: true}}
end

defmodule SpectreStackPackageDataTest.CompleteStack do
  @moduledoc false

  use Spectre.Stack, id: :package_data_complete_stack

  install(SpectreStackPackageDataTest.FirstPackage)
  install(SpectreStackPackageDataTest.SecondPackage)
end

defmodule SpectreStackPackageDataTest.IncompleteStack do
  @moduledoc false

  use Spectre.Stack, id: :package_data_incomplete_stack
  install(SpectreStackPackageDataTest.PlanOnlyPackage)
end

defmodule SpectreStackPackageDataTest.CompleteAgent do
  @moduledoc false

  use Spectre.Agent,
    id: :package_data_complete_agent,
    stack: SpectreStackPackageDataTest.CompleteStack
end

defmodule SpectreStackPackageDataTest.IncompleteAgent do
  @moduledoc false

  use Spectre.Agent,
    id: :package_data_incomplete_agent,
    stack: SpectreStackPackageDataTest.IncompleteStack
end

defmodule SpectreStackPackageDataTest.PlainAgent do
  @moduledoc false
  use Spectre.Agent, id: :package_data_plain_agent
end

defmodule SpectreStackPackageDataTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Ref
  alias Spectre.Stack.PackageData

  alias SpectreStackPackageDataTest.CompleteAgent
  alias SpectreStackPackageDataTest.FirstPackage
  alias SpectreStackPackageDataTest.IncompleteAgent
  alias SpectreStackPackageDataTest.PlanOnlyPackage
  alias SpectreStackPackageDataTest.PlainAgent
  alias SpectreStackPackageDataTest.SecondPackage

  test "reports package-data erasure as not configured when the Agent has no Stack adapters" do
    ref = Ref.new(PlainAgent, "plain")

    assert {:ok, %{configured: false, status: :not_configured, package_count: 0, adapters: []}} =
             PackageData.erasure_plan(ref)

    assert {:ok,
            %{
              outcome: :not_configured,
              package_count: 0,
              erased_count: 0,
              already_erased_count: 0,
              packages: []
            }} = PackageData.erase_instance(ref)
  end

  test "plans and erases complete adapters in immutable Stack order" do
    ref = complete_ref("ordered")
    opts = [test_pid: self()]

    assert {:ok, %{configured: true, status: :ready, package_count: 2} = plan} =
             PackageData.erasure_plan(ref, opts)

    assert Enum.map(plan.adapters, &{&1.package, &1.status}) == [
             {:package_data_first, :ready},
             {:package_data_second, :ready}
           ]

    assert_receive {:package_data_plan, :first, ref_key,
                    {:package_data_first, :package_data_first}}

    assert ref_key == ref.key

    assert_receive {:package_data_plan, :second, ^ref_key,
                    {:package_data_second, :package_data_second}}

    authorize = fn ->
      send(self(), :package_data_authorized)
      :ok
    end

    assert {:ok,
            %{
              outcome: :erased,
              package_count: 2,
              erased_count: 2,
              already_erased_count: 0,
              packages: packages
            }} = PackageData.erase_instance(ref, opts, authorize)

    assert Enum.map(packages, &{&1.package, &1.outcome}) == [
             {:package_data_first, :erased},
             {:package_data_second, :erased}
           ]

    assert_receive :package_data_authorized
    assert_receive {:package_data_erase, :first, ^ref_key, _identifiers}
    assert_receive :package_data_authorized
    assert_receive {:package_data_erase, :second, ^ref_key, _identifiers}
  end

  test "recognizes both supported already-erased replies" do
    ref = complete_ref("already-erased")

    assert {:ok,
            %{
              outcome: :already_erased,
              erased_count: 0,
              already_erased_count: 2,
              packages: packages
            }} =
             PackageData.erase_instance(ref,
               erase_modes: %{first: :already_erased_map, second: :already_erased}
             )

    assert Enum.all?(packages, &(&1.outcome == :already_erased))
  end

  test "returns completed installation ids when a later adapter fails" do
    ref = complete_ref("partial")

    assert {:error,
            {:package_data_erase_failed, [:package_data_first], SecondPackage,
             :temporarily_unavailable}} =
             PackageData.erase_instance(ref,
               erase_modes: %{second: {:error, :temporarily_unavailable}}
             )
  end

  test "fails before mutation when authorization is rejected" do
    ref = complete_ref("unauthorized")

    assert {:error, {:package_data_erase_failed, [], FirstPackage, :stale_owner}} =
             PackageData.erase_instance(ref, [], fn -> {:error, :stale_owner} end)
  end

  test "classifies unsupported, invalid and unavailable plans" do
    ref = complete_ref("plan-statuses")

    assert {:ok, %{status: :unsupported} = unsupported} =
             PackageData.erasure_plan(ref, plan_modes: %{first: :unsupported})

    assert {:error, {:package_data_erasure_unavailable, :unsupported, _adapters}} =
             PackageData.erasure_capability(unsupported)

    assert {:ok, %{status: :unsupported}} =
             PackageData.erasure_plan(ref, plan_modes: %{first: :invalid_ok})

    assert {:ok, %{status: :unavailable} = unavailable} =
             PackageData.erasure_plan(ref, plan_modes: %{first: {:error, :offline}})

    assert {:error, {:package_data_erasure_unavailable, :unavailable, _adapters}} =
             PackageData.erasure_capability(unavailable)
  end

  test "normalizes every invalid callback reply shape to unavailable" do
    ref = complete_ref("invalid-replies")

    for reply <- [%{}, [], {:invalid, :tuple}, :invalid_atom, 123] do
      assert {:ok, %{status: :unavailable}} =
               PackageData.erasure_plan(ref, plan_modes: %{first: {:raw, reply}})
    end
  end

  test "contains callback exceptions and non-local exits" do
    ref = complete_ref("callback-failures")

    assert {:error,
            {:package_data_erase_failed, [], FirstPackage,
             {:package_data_callback_exception, FirstPackage, :erase_instance, RuntimeError,
              "erase exploded"}}} =
             PackageData.erase_instance(ref,
               erase_modes: %{first: {:raise, "erase exploded"}}
             )

    assert {:error,
            {:package_data_erase_failed, [], FirstPackage,
             {:package_data_callback_failure, FirstPackage, :erase_instance, :throw,
              :erase_thrown}}} =
             PackageData.erase_instance(ref,
               erase_modes: %{first: {:throw, :erase_thrown}}
             )
  end

  test "fails closed when a package implements only one erasure callback" do
    ref = Ref.new(IncompleteAgent, "incomplete")

    assert {:ok,
            %{
              status: :unsupported,
              adapters: [%{adapter: adapter, status: :unsupported}]
            }} = PackageData.erasure_plan(ref)

    assert adapter == inspect(PlanOnlyPackage)

    assert {:error, {:package_data_adapter_incomplete, PlanOnlyPackage}} =
             PackageData.erase_instance(ref)
  end

  test "validates public options and preflight components" do
    ref = complete_ref("validation")

    assert {:error, :invalid_package_data_erasure_options} =
             PackageData.erasure_plan(ref, :invalid)

    assert {:error, :invalid_package_data_erasure_options} =
             PackageData.erasure_plan(ref, [:not_a_keyword])

    assert {:error, :invalid_package_data_erasure_options} =
             PackageData.erase_instance(ref, :invalid, fn -> :ok end)

    assert {:error, :invalid_package_data_erasure_options} =
             PackageData.erase_instance(ref, [:not_a_keyword], fn -> :ok end)

    assert :ok = PackageData.erasure_capability(%{status: :ready})
    assert :ok = PackageData.erasure_capability(%{status: :not_configured})
    assert {:error, :invalid_package_data_erasure_plan} = PackageData.erasure_capability(%{})
  end

  defp complete_ref(subject), do: Ref.new(CompleteAgent, subject)
end
