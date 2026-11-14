defmodule Outreach.SkillAgent do
  use Spectre.Agent, stack: Outreach.AI, server: Outreach.Server

  skill(Outreach.Skill,
    as: :outreach,
    governed: [{{:skill, :outreach}, :kinetic, :send_email}, :send_notice, :save_report]
  )
end
