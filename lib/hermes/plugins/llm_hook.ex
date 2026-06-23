defmodule Hermes.Plugins.LLMHook do
  @moduledoc """
  Behaviour for plugin pre/post LLM-call hooks.

  Mirrors the `pre_api_request` / post-response hook pattern from Python
  `agent/conversation_loop.py:742-748,1010-1013`. Plugins register
  themselves via `Application.get_env(:hermes, :llm_hooks, [])` and must
  implement this behaviour.

  The default implementations are no-ops.
  """

  @doc """
  Called just before the provider `stream/4` call.

  Receives the current turn-loop state and returns the (possibly mutated)
  state.
  """
  @callback pre_llm_call(state :: map()) :: map()

  @doc """
  Called immediately after a successful provider `stream/4` call.

  Receives the current turn-loop state and the normalized response. Must
  return `{state, response}`.
  """
  @callback post_llm_call(state :: map(), response :: struct()) :: {map(), struct()}

  @doc "No-op pre-call hook."
  def pre_llm_call(state), do: state

  @doc "No-op post-call hook."
  def post_llm_call(state, response), do: {state, response}
end
