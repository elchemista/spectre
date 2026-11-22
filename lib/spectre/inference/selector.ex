defmodule Spectre.Inference.Selector do
  @moduledoc """
  Behaviour implemented by inference-selection policies.
  """

  @doc "Selects an inference profile from the request, available profiles, context and policy options."
  @callback select(
              Spectre.Inference.Request.t(),
              [Spectre.Inference.Profile.t()],
              Spectre.Context.t(),
              keyword()
            ) ::
              {:ok, Spectre.Inference.Selection.t()} | {:error, term()}
end
