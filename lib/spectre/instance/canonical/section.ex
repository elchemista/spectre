defmodule Spectre.Instance.Canonical.Section do
  @moduledoc false

  defstruct revision: 0, value: %{}

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          value: term()
        }

  @spec replace(t(), term(), non_neg_integer()) :: t()
  def replace(%__MODULE__{value: value} = section, value, revision)
      when is_integer(revision) and revision >= 0 do
    # A canonical commit may include an ownership-fence write whose value did
    # not change. Keeping the section revision stable makes section fences and
    # semantic state digests describe data changes rather than delivery work.
    section
  end

  def replace(%__MODULE__{} = section, value, revision)
      when is_integer(revision) and revision >= 0 do
    %{section | revision: revision, value: value}
  end
end
