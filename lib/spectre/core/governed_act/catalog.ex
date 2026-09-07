defmodule Spectre.GovernedAct.Catalog do
  @moduledoc """
  Governed declarations and their current revision pointers.

  Genesis anchors the Domain's foundation. Principal, HostProfile, Surface,
  Definition and Scope records describe who participates and the environment
  in which proposals are evaluated. Their histories remain available after a
  revision; a head reference selects the current record without copying it.

  This is a disposable part of `Spectre.GovernedAct.State`, populated only by
  the history fold. It is neither host configuration nor a second authority
  store. Keeping declarations together separates them from the changing
  admission, execution and accounting indexes without changing ledger records.
  """

  alias Spectre.{Definition, Genesis, HostProfile, Principal, Surface}
  alias Spectre.Scope.Opening

  defstruct genesis: nil,
            principals: %{},
            host_profile_ref: nil,
            host_profiles: %{},
            surface_ref: nil,
            surfaces: %{},
            definitions: %{},
            definition_heads: %{},
            scopes: %{}

  @type t :: %__MODULE__{
          genesis: Genesis.t() | nil,
          principals: %{optional(String.t()) => Principal.t()},
          host_profile_ref: String.t() | nil,
          host_profiles: %{optional(String.t()) => HostProfile.t()},
          surface_ref: String.t() | nil,
          surfaces: %{optional(String.t()) => Surface.t()},
          definitions: %{optional(String.t()) => Definition.t()},
          definition_heads: %{optional({String.t(), String.t()}) => String.t()},
          scopes: %{optional(String.t()) => Opening.t()}
        }

  @doc "Stores an already validated Principal without changing any authority."
  @spec put_principal(t(), Principal.t()) :: t()
  def put_principal(%__MODULE__{} = catalog, %Principal{ref: ref} = principal),
    do: %{catalog | principals: Map.put(catalog.principals, ref, principal)}

  @doc "Stores an accepted HostProfile revision and advances its head together."
  @spec put_host_profile(t(), HostProfile.t()) :: t()
  def put_host_profile(%__MODULE__{} = catalog, %HostProfile{ref: ref} = profile),
    do: %{
      catalog
      | host_profile_ref: ref,
        host_profiles: Map.put(catalog.host_profiles, ref, profile)
    }

  @doc "Stores an accepted Surface revision and advances its head together."
  @spec put_surface(t(), Surface.t()) :: t()
  def put_surface(%__MODULE__{} = catalog, %Surface{ref: ref} = surface),
    do: %{catalog | surface_ref: ref, surfaces: Map.put(catalog.surfaces, ref, surface)}

  @doc "Stores an accepted Definition revision and advances only that declaration's head."
  @spec put_definition(t(), Definition.t()) :: t()
  def put_definition(%__MODULE__{} = catalog, %Definition{ref: ref} = definition) do
    %{
      catalog
      | definitions: Map.put(catalog.definitions, ref, definition),
        definition_heads: Map.put(catalog.definition_heads, Definition.key(definition), ref)
    }
  end
end
