defmodule Hermes.Sessions.CompactionTest do
  use Hermes.DataCase, async: false

  alias Hermes.Sessions.Compaction

  # A provider stub whose stream/4 returns a fixed summary, so compaction can
  # run without any network call.
  defmodule SummaryProvider do
    def stream(_model, _messages, _opts, _finch \\ nil), do: {:ok, %{content: "COMPACT SUMMARY"}}
  end

  defp base_state(messages) do
    %{
      session_id: "compact-#{System.unique_integer([:positive])}",
      provider: SummaryProvider,
      model: "test-model",
      base_url: nil,
      api_key: nil,
      finch_name: Hermes.Finch,
      context_window: 1_000,
      messages: messages
    }
  end

  test "no-op when token count is under the threshold" do
    state = base_state([%{role: "user", content: "short"}])
    assert Compaction.maybe_compress(state) == state
  end

  test "no-op when no context window is known" do
    state = %{base_state([%{role: "user", content: "hi"}]) | context_window: nil}
    assert Compaction.maybe_compress(state) == state
  end

  test "compresses older history and keeps the current turn when over threshold" do
    big = String.duplicate("token ", 2_000)

    messages = [
      %{role: "user", content: big},
      %{role: "assistant", content: big},
      %{role: "user", content: "the current question"}
    ]

    state = base_state(messages)
    compacted = Compaction.maybe_compress(state)

    # Older turn replaced by a single summary message; current turn preserved.
    assert [summary, last] = compacted.messages
    assert summary.role == "user"
    assert summary.content =~ "COMPACT SUMMARY"
    assert last.content == "the current question"
  end

  test "does not split tool-call pairs (keeps from the last user message)" do
    big = String.duplicate("x ", 3_000)

    messages = [
      %{role: "user", content: "first"},
      %{role: "assistant", content: big, tool_calls: [%{"id" => "c1"}]},
      %{role: "tool", tool_call_id: "c1", content: big},
      %{role: "user", content: "second question"}
    ]

    compacted = Compaction.maybe_compress(base_state(messages))

    # The kept tail must begin at a user message, never an orphaned tool result.
    assert hd(compacted.messages).role == "user"
    assert List.last(compacted.messages).content == "second question"
    refute Enum.any?(compacted.messages, &(&1.role == "tool"))
  end

  test "estimate_tokens counts roughly and never crashes on odd content" do
    assert Compaction.estimate_tokens([%{role: "user", content: "abcd efgh"}]) >= 1
    assert Compaction.estimate_tokens([%{role: "user", content: nil}]) == 0
  end
end
