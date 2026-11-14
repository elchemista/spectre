defmodule Outreach.Skill do
  use Spectre.Skill,
    id: :outreach,
    server: Outreach.Server,
    prompt_root: Path.expand("../prompts", __DIR__)

  flow :outreach do
    on(:start, regex: ~r/^start$/)
    on(:status, regex: ~r/^status$/)
    on(:resume, regex: ~r/^resume$/)
  end
end
