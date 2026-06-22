defmodule Hermes.Curator.BackgroundReview do
  @moduledoc """
  Post-turn background review.

  Ported from `agent/background_review.py:45` and `_run_review_in_thread`
  (`agent/background_review.py:446-702`). After a turn completes, a
  fire-and-forget task replays the conversation snapshot plus a review prompt
  through a stripped-down turn loop and asks: "should any skill/memory be
  saved or updated?".

  The review fork runs with the session's provider/model, uses a tool
  whitelist limited to memory, skill, and session-recall tools, and writes
  via `skill_manage` / `memory` when appropriate.

  #curator-recall: the whitelist includes `session_search` so the review can
  recall cross-session history when deciding what to save.
  """

  alias Hermes.Sessions.TurnLoop
  alias Hermes.Tools.Registry

  @review_prompt """
  Review the conversation above and decide whether any skill or memory should be saved or updated.

  You may only call memory, skill, and session-recall tools. If nothing is worth saving, just say 'Nothing to save.' and stop.
  """

  @tool_whitelist ["memory", "skill_manage", "skills_list", "skill_view", "session_search"]

  @doc """
  Spawn a non-blocking background review for the given conversation snapshot.

  `opts` accepts `:provider`, `:model`, `:api_mode`, `:finch_name`,
  `:max_iterations`, and `:system_prompt` and falls back to sensible defaults.
  """
  @spec spawn_review(String.t(), [map()], keyword()) :: :ok
  def spawn_review(session_id, messages, opts) do
    opts = normalize_opts(opts)

    :telemetry.execute(
      [:hermes, :curator, :background_review, :spawned],
      %{count: 1},
      %{session_id: session_id}
    )

    Task.start(fn -> run_review(session_id, messages, opts) end)
    :ok
  end

  defp normalize_opts(opts) do
    [
      provider: Keyword.get(opts, :provider, Hermes.Providers.Anthropic),
      model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
      api_mode: Keyword.get(opts, :api_mode, "anthropic_messages"),
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      finch_name: Keyword.get(opts, :finch_name, Hermes.Finch),
      max_iterations: Keyword.get(opts, :max_iterations, 5),
      system_prompt: Keyword.get(opts, :system_prompt, nil)
    ]
  end

  defp run_review(session_id, messages, opts) do
    tools = Registry.list_schemas(@tool_whitelist)

    review_messages = messages ++ [%{role: "user", content: @review_prompt}]

    turn_opts = [
      session_id: session_id,
      messages: review_messages,
      model: opts[:model],
      provider: opts[:provider],
      api_mode: opts[:api_mode],
      base_url: opts[:base_url],
      api_key: opts[:api_key],
      tools: tools,
      max_iterations: opts[:max_iterations],
      budget_grace_call: false,
      finch_name: opts[:finch_name],
      system_prompt: opts[:system_prompt]
    ]

    case TurnLoop.run(turn_opts) do
      {:ok, _result} ->
        :telemetry.execute(
          [:hermes, :curator, :background_review, :completed],
          %{count: 1},
          %{session_id: session_id}
        )

        :ok

      {:error, _error} ->
        :telemetry.execute(
          [:hermes, :curator, :background_review, :failed],
          %{count: 1},
          %{session_id: session_id}
        )

        :ok
    end
  end
end
