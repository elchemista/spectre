# Lo sketch iniziale è stato sostituito dall'integrazione eseguibile e verificata.
#
# Stack, Agent e Server:
#   integration/stack_tools/support/workflow.ex
# Binding GAM ed executor:
#   integration/stack_tools/support/host.ex
# Scenari di consenso, isolamento e recovery:
#   integration/stack_tools/test/outreach_test.exs
#
# Dalla radice del repository:
#   cd integration/stack_tools
#   mix deps.get
#   mix test
#
# Non importare kinetic/3, mnemonic/3 o lens/3 dai package: il core genera
# questi helper dal behaviour Stack.Installable quando il Server dichiara
# `use Spectre.Server, tools: Outreach.AI`.
# I servizi esterni dell'esempio sono simulati; non vengono inviate email.
