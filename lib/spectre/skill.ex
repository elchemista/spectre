defmodule Spectre.Skill do
  @moduledoc """
  Reusable Agent declarations, compiled by the same authoring layer.

      defmodule MyApp.LookupSkill do
        use Spectre.Skill,
          namespace: "my_app", name: "lookup", revision: 1, declared_at: 0

        candidate "order", class: "orders.lookup", row: %{read: true}
      end

  An Agent installs these declarations with `install MyApp.LookupSkill,
  as: "lookup"` and materializes `"lookup/order"`. Routes, assets, extension
  contributions and host ports compose under the same namespace; the root
  Agent explicitly chooses the root routing methods with `router via: [...]`.
  Named flows preserve their own routing methods and named host pipeline
  requirements, all mounted under the installation namespace. They create no
  process and do not silently inherit the root router's policy.
  Installation does not grant
  the Skill a Mandate, create a child Scope or allocate budget. Deliberative
  skill code is an ordinary function or a `Spectre.Mind` adapter, not another
  runtime. Code that calls a governed remote model belongs behind an executor.
  """

  defmacro __using__(opts) do
    quote do
      use Spectre.Agent, unquote(opts)
    end
  end
end
