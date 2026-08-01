defmodule SpectreJournalPublicContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Journal

  test "extension journal metadata is operational and privacy safe" do
    assert :ok =
             Journal.record(__MODULE__, :canonical_transition, %{revision: 1}, journal: false)

    assert :ok =
             Journal.record(__MODULE__, :canonical_transition, %{7 => :non_sensitive},
               journal: false
             )

    assert {:error, {:sensitive_journal_metadata, :text}} =
             Journal.record(__MODULE__, :canonical_transition, %{text: "private"}, journal: false)

    assert {:error, {:sensitive_journal_metadata, "TOKEN"}} =
             Journal.record(__MODULE__, :canonical_transition, %{"TOKEN" => "private"},
               journal: false
             )
  end
end
