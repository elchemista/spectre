defmodule SpectreInstanceCommitTest.Agent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreInstanceCommitTest.RejectingOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  @impl true
  def claim(_ref, _opts), do: raise("claim must not be called")

  @impl true
  def validate(_ref, _lease, _opts), do: raise("validate must not be called")
end

defmodule SpectreInstanceCommitTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance
  alias Spectre.Instance.Commit
  alias Spectre.Subject

  test "invalid checkpoint commit modes fail before the canonical commit pipeline" do
    subject = Subject.new("commit-mode-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(
        {Instance, agent: SpectreInstanceCommitTest.Agent, subject: subject, idle: false}
      )

    data = :sys.get_state(instance)

    guarded = %{
      data
      | owner: SpectreInstanceCommitTest.RejectingOwner,
        canonical: %{data.canonical | sections: :unreachable}
    }

    assert {:error, {:invalid_canonical_commit_checkpoint_mode, :unsupported}} =
             Commit.canonical_sections(guarded, %{flow: data.state},
               correlation_id: "invalid-checkpoint-mode",
               checkpoint: :unsupported
             )

    assert %{canonical: %{revision: 0}, checkpoint_inflight: nil, checkpoint_pending: nil} =
             :sys.get_state(instance)
  end
end
