defmodule Hermes.Sessions.Compaction do
  @moduledoc """
  Context compression for long conversations.

  When a turn's message history approaches the model's context window, the
  oldest portion of the conversation is summarized by the same provider/model
  and replaced with a single compact summary message, so the session can keep
  going without overflowing the window.

  Design notes:

    * The trigger is `estimated_tokens > context_window * @threshold`. Token
      counting uses the `Hermes.Native` Rustler NIF when available and falls
      back to a pure heuristic otherwise.
    * History is only ever split at a **user-message boundary** (the start of
      the current turn). This guarantees the kept tail never begins with an
      orphaned `tool` result whose `assistant` tool-call was summarized away —
      which would make the next API call invalid.
    * Compression is serialized per session through the `compression_locks`
      table (`Hermes.Sessions.CompressionLock`), mirroring the Python design.
      All DB access is best-effort: a failure simply skips compression.
  """

  import Ecto.Query, only: [from: 2]

  alias Hermes.Repo
  alias Hermes.Sessions.CompressionLock

  require Logger

  # Compress once history crosses this fraction of the context window.
  @threshold 0.75
  # Lock validity window (seconds) before it is considered stale.
  @lock_ttl_seconds 120
  @summary_max_tokens 1024

  @summary_prompt """
  You are compacting a long conversation to save context. Summarize the\
   following earlier conversation history concisely while preserving key facts,\
   user preferences, decisions, open questions, and any state needed to\
   continue. Write the summary as dense notes, not prose.
  """

  @doc """
  Returns the turn-loop state, compressing older history in place when the
  estimated token count exceeds the model's context window threshold. Returns
  the state unchanged when no context window is known or the threshold is not
  crossed.
  """
  @spec maybe_compress(map()) :: map()
  def maybe_compress(%{context_window: cw, messages: messages} = state)
      when is_integer(cw) and cw > 0 do
    tokens = estimate_tokens(messages)

    if tokens > round(cw * @threshold) do
      compress(state, tokens)
    else
      state
    end
  end

  def maybe_compress(state), do: state

  @doc """
  Forces a compaction pass regardless of the token threshold (used by the
  `/compact` slash command). Returns the state with compressed messages.
  """
  @spec force(map()) :: map()
  def force(%{messages: messages} = state) do
    compress(state, estimate_tokens(messages))
  end

  # ---------------------------------------------------------------------------

  defp compress(%{session_id: session_id} = state, tokens) do
    case acquire_lock(session_id) do
      :ok ->
        try do
          do_compress(state, tokens)
        after
          release_lock(session_id)
        end

      :busy ->
        state
    end
  end

  defp do_compress(state, tokens) do
    case safe_split(state.messages) do
      {[], _keep} ->
        # Nothing summarizable before the current turn — skip safely.
        state

      {to_summarize, to_keep} ->
        case summarize(state, to_summarize) do
          {:ok, summary} ->
            Logger.info(
              "Compacted session #{state.session_id}: ~#{tokens} tokens, " <>
                "#{length(to_summarize)} messages -> summary"
            )

            summary_msg = %{
              role: "user",
              content: "[Earlier conversation summary — compacted to save context]\n\n" <> summary
            }

            %{state | messages: [summary_msg | to_keep]}

          :error ->
            state
        end
    end
  end

  # Split so the kept tail begins at the LAST user message (start of the current
  # turn). Everything before it is summarized. If the only user message is at the
  # head, there is nothing safe to summarize.
  defp safe_split(messages) do
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {msg, idx}, acc ->
        if role_of(msg) == "user", do: idx, else: acc
      end)

    case last_user_index do
      nil -> {[], messages}
      0 -> {[], messages}
      idx -> Enum.split(messages, idx)
    end
  end

  defp summarize(state, messages) do
    rendered = render_for_summary(messages)

    request = [%{role: "user", content: @summary_prompt <> "\n\n" <> rendered}]

    opts = [
      params: [max_tokens: @summary_max_tokens],
      base_url: state.base_url,
      api_key: state.api_key
    ]

    case state.provider.stream(state.model, request, opts, state.finch_name) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp render_for_summary(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = role_of(msg) || "user"
      content = content_of(msg)
      "#{String.upcase(role)}: #{content}"
    end)
  end

  defp role_of(msg), do: get(msg, :role)

  defp content_of(msg) do
    case get(msg, :content) do
      c when is_binary(c) -> c
      nil -> ""
      other -> inspect(other)
    end
  end

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, to_string(key))
    end
  end

  defp get(_map, _key), do: nil

  # ---------------------------------------------------------------------------
  # Token estimation (NIF with pure fallback)
  # ---------------------------------------------------------------------------

  @doc false
  @spec estimate_tokens([map()]) :: non_neg_integer()
  def estimate_tokens(messages) do
    payload = Enum.map(messages, fn m -> %{"content" => content_of(m)} end)
    Hermes.Native.estimate_messages_tokens(payload)
  rescue
    _ -> fallback_estimate(messages)
  catch
    _, _ -> fallback_estimate(messages)
  end

  defp fallback_estimate(messages) do
    messages
    |> Enum.map(&content_of/1)
    |> Enum.map(&div(String.length(&1), 4))
    |> Enum.sum()
  end

  # ---------------------------------------------------------------------------
  # Lock (compression_locks table)
  # ---------------------------------------------------------------------------

  defp acquire_lock(session_id) do
    now = now()

    # Clear an expired lock first, then claim if free.
    Repo.delete_all(
      from l in CompressionLock, where: l.session_id == ^session_id and l.expires_at < ^now
    )

    case Repo.get(CompressionLock, session_id) do
      %CompressionLock{} ->
        :busy

      nil ->
        attrs = %{
          session_id: session_id,
          holder: inspect(self()),
          acquired_at: now,
          expires_at: now + @lock_ttl_seconds
        }

        %CompressionLock{} |> CompressionLock.changeset(attrs) |> Repo.insert()
        :ok
    end
  rescue
    _ -> :ok
  end

  defp release_lock(session_id) do
    Repo.delete_all(from l in CompressionLock, where: l.session_id == ^session_id)
    :ok
  rescue
    _ -> :ok
  end

  defp now, do: System.system_time(:millisecond) / 1000.0
end
