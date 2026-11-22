# Spectre 0.4.0 Server checkpoint

`server-v1.checkpoint.base64` contains a version 1 snapshot written by the
runtime in the `0.4.0` tag at `57e762ceda1188daa60da0e068ed10b5376c3441`,
using Elixir 1.20.4 and OTP 29. The Base64 file is 2,393 bytes including its
trailing newline. Its SHA-256 is
`6b693babe97c46d897ecc8e7ee861af03f163a111492087ef8e9e5c557afdce6`.

The capture runs `Spectre.Server.ToolRuntimeTest.Agent` against a temporary
disk store. Its Server acquires a generated `probe` call for
`{:safe_wait, :resource}` with `on_result: :wait`. The fixture fetches the stored
checkpoint while the fake adapter waits for release and encodes those exact
bytes. The application and adapter input are synthetic.

The compatibility test uses the explicit checkpoint migration callback because
recompiling the fixture against 0.4.1 changes its definition fingerprint. The
callback accepts the unchanged projection. Recovery must invoke the helper
with the original command ID and deliver the result to its original handler.
