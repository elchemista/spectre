defmodule Spectre.SemanticCache.Test.CustomerSupport do
  @moduledoc false

  # Shared real-model corpus: fictional support conversations. None of the queries is an
  # exact example, and no label is chosen from a score measured during a test.
  @examples [
    {"refund",
     "The headphones in order ORD-2041 arrived broken. I would like to return them and receive a refund to my card."},
    {"refund",
     "I sent back the shoes from order ORD-8830 last week. Please refund the purchase price to my original payment method."},
    {"refund", "The jacket does not fit. Can you arrange a return and give me my money back?"},
    {"shipping",
     "Where is my parcel for order ORD-5102? The tracking page has not changed since Monday and the delivery is late."},
    {"shipping",
     "Please send me the shipment tracking number and the estimated delivery date for my recent order."},
    {"shipping",
     "The courier says my package was delivered, but it never arrived at my address. Can you locate the shipment?"},
    {"billing",
     "I need a PDF invoice for order ORD-7219, addressed to Example Retail Ltd, with the company VAT number."},
    {"billing",
     "Please correct the billing address on my invoice and send a new copy for our accounting department."},
    {"billing",
     "Could you email the tax invoice for last month's subscription? Our bookkeeper needs the receipt."},
    {"account",
     "I forgot my password and cannot sign in to my account. Please help me reset my login credentials."},
    {"account",
     "I replaced my phone and lost access to the authenticator app. How can I recover my account?"},
    {"account",
     "My account is locked after several unsuccessful login attempts. I need help regaining access."}
  ]

  @queries [
    {"refund", "My new headphones are faulty. How do I send them back and get reimbursed?"},
    {"refund",
     "The returned shoes have reached your warehouse. When will the money be credited back to my card?"},
    {"shipping",
     "Can you check where my delivery is? It was supposed to arrive yesterday but I still have no parcel."},
    {"shipping",
     "I haven't received the courier tracking link. When is my package expected to reach me?"},
    {"billing",
     "Our finance team needs a downloadable VAT invoice for the purchase, made out to the business."},
    {"billing",
     "The street on the invoice is wrong. Could you issue a corrected billing document?"},
    {"account",
     "I can't remember the password for my profile. How can I reset it and log in again?"},
    {"account",
     "My old phone had the two-factor codes and I no longer have it. I need to restore access to my login."}
  ]

  def examples, do: @examples
  def queries, do: @queries
  def labels, do: ["refund", "shipping", "billing", "account"]

  def unrelated,
    do: "What is the orbital period of Neptune, and why does it appear blue through a telescope?"

  def model, do: "BAAI/bge-small-en-v1.5"
  def profile, do: "fastembed:bge-small-en-v1.5:384:plain:v1"

  def embed! do
    {:ok, 384} = ExFastembed.load(model())
    texts = Enum.map(@examples ++ @queries, &elem(&1, 1)) ++ [unrelated()]
    {:ok, vectors} = ExFastembed.embed_text(texts)
    Map.new(Enum.zip(texts, vectors))
  end
end
