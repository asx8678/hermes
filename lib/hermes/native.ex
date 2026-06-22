defmodule Hermes.Native do
  @moduledoc """
  Rustler NIF loader for tokenization hot paths.

  These NIFs are short, pure, CPU-bound functions and run on dirty CPU
  schedulers so they do not block normal BEAM schedulers. Per the
  architecture spec, terminal/execute_code/browser remain sidecars — never
  NIFs.

  Source: 07-rewrite-execution-spec.md (NIF discipline).
  """

  use Rustler, otp_app: :hermes

  @doc """
  Roughly estimate the number of tokens in `text` for `model`.

  Uses a simple heuristic: ~4 ASCII characters per token, ~1 CJK character
  per token. This mirrors Python's `estimate_messages_tokens_rough`.
  """
  @spec count_tokens(String.t(), String.t()) :: integer()
  def count_tokens(_text, _model), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sum rough token estimates across a list of messages.

  Each message is expected to be a map containing a string `"content"`
  value.
  """
  @spec estimate_messages_tokens([map()]) :: integer()
  def estimate_messages_tokens(_messages), do: :erlang.nif_error(:nif_not_loaded)
end
