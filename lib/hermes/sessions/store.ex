defmodule Hermes.Sessions.Store do
  @moduledoc """
  Durable persistence for sessions and messages.

  The live conversation runs in `Hermes.Sessions.SessionServer` (in-memory for
  speed and fault isolation), and this module write-throughs each session and
  message to SQLite so conversations survive restarts and become searchable.
  Inserting a `messages` row automatically populates the FTS5 tables via the
  triggers created in the sessions migration, which is what makes
  `Hermes.Sessions.Search` / `session_search` return data.

  All writes are best-effort: a persistence failure is logged and swallowed so
  it can never crash a running turn.
  """

  import Ecto.Query, only: [from: 2]

  alias Hermes.Repo
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Session

  require Logger

  @doc """
  Inserts the session row if it does not already exist. Idempotent.
  """
  @spec create_session(String.t(), keyword()) :: :ok
  def create_session(session_id, opts \\ []) when is_binary(session_id) do
    attrs = %{
      id: session_id,
      source: Keyword.get(opts, :source, "tui"),
      model: Keyword.get(opts, :model),
      started_at: now(),
      parent_session_id: Keyword.get(opts, :parent_session_id)
    }

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :id)

    :ok
  rescue
    error ->
      Logger.warning("Store.create_session failed: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Persists a list of new messages for a session (each as a `messages` row) and
  bumps the session's `message_count`. The caller passes only the messages that
  are genuinely new this turn (computed as a value-delta), which keeps this
  correct even when context compression rewrites the in-memory history.
  """
  @spec persist_messages(String.t(), [map()]) :: :ok
  def persist_messages(_session_id, []), do: :ok

  def persist_messages(session_id, messages)
      when is_binary(session_id) and is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.each(fn {message, idx} -> persist_message(session_id, message, idx) end)

    bump_message_count(session_id, length(messages))
    :ok
  rescue
    error ->
      Logger.warning("Store.persist_messages failed: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Lists persisted sessions (most recent first) as dashboard-friendly maps.
  """
  @spec list_sessions(non_neg_integer()) :: [map()]
  def list_sessions(limit \\ 100) do
    Repo.all(
      from s in Session,
        order_by: [desc: s.started_at],
        limit: ^limit,
        select: %{
          id: s.id,
          model: s.model,
          source: s.source,
          message_count: s.message_count,
          started_at: s.started_at
        }
    )
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp persist_message(session_id, message, ordinal) do
    role = fetch(message, :role)

    attrs = %{
      session_id: session_id,
      role: to_string(role || "user"),
      content: stringify_content(fetch(message, :content)),
      tool_call_id: fetch(message, :tool_call_id),
      tool_name: fetch(message, :name) || fetch(message, :tool_name),
      tool_calls: encode_json(fetch(message, :tool_calls)),
      finish_reason: fetch(message, :finish_reason),
      reasoning: stringify_content(fetch(message, :reasoning)),
      # Monotonic within a turn so ordering by timestamp matches append order.
      timestamp: now() + ordinal * 1.0e-6,
      active: 1
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  rescue
    error ->
      Logger.warning("Store.persist_message failed: #{Exception.message(error)}")
      :error
  end

  defp bump_message_count(session_id, count) do
    from(s in Session, where: s.id == ^session_id)
    |> Repo.update_all(inc: [message_count: count])
  rescue
    _ -> :ok
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil

  defp stringify_content(value) when is_binary(value), do: value
  defp stringify_content(nil), do: nil
  defp stringify_content(value), do: encode_json(value)

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  defp now, do: System.system_time(:millisecond) / 1000.0
end
