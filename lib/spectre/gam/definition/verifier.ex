defmodule Spectre.GAM.Definition.Verifier do
  @moduledoc """
  Optional static diagnostic for a host's immutable authoring format.

  The kernel accepts portable Definitions without interpreting an Agent DSL.
  A verifier can inspect fixed declarations against a Surface, but its report
  is never a substitute for live admission, consent or executor validation.
  """

  @callback verify(Spectre.GAM.Surface.t(), Spectre.GAM.Definition.t()) ::
              {:ok, Spectre.GAM.Surface.definition_report()} | {:error, term()}
end
