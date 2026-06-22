defmodule Hermes.Sessions.StoreTest do
  use Hermes.DataCase, async: false

  alias Hermes.Repo
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Session
  alias Hermes.Sessions.Store

  test "create_session inserts a session row idempotently" do
    :ok = Store.create_session("sess-1", source: "tui", model: "gpt-4o")
    :ok = Store.create_session("sess-1", source: "tui", model: "gpt-4o")

    assert %Session{model: "gpt-4o", source: "tui"} = Repo.get(Session, "sess-1")
    assert Repo.aggregate(Session, :count) == 1
  end

  test "persist_messages writes rows and bumps message_count" do
    :ok = Store.create_session("sess-2", source: "tui", model: "gpt-4o")

    :ok =
      Store.persist_messages("sess-2", [
        %{role: "user", content: "remember the launch code is alpha-bravo"},
        %{role: "assistant", content: "Noted."}
      ])

    rows = Repo.all(from m in Message, where: m.session_id == "sess-2", order_by: m.id)
    assert length(rows) == 2
    assert Enum.map(rows, & &1.role) == ["user", "assistant"]

    assert %Session{message_count: 2} = Repo.get(Session, "sess-2")
  end

  test "persisting a message populates the FTS index (recall works)" do
    :ok = Store.create_session("sess-3", source: "tui", model: "gpt-4o")
    :ok = Store.persist_messages("sess-3", [%{role: "user", content: "the pineapple is hidden"}])

    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH ?", ["pineapple"])

    assert count == 1
  end

  test "tool_calls are serialized to JSON" do
    :ok = Store.create_session("sess-4", source: "tui", model: "gpt-4o")

    :ok =
      Store.persist_messages("sess-4", [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{"id" => "c1", "function" => %{"name" => "terminal"}}]
        }
      ])

    row = Repo.one(from m in Message, where: m.session_id == "sess-4")
    assert is_binary(row.tool_calls)
    assert {:ok, [%{"id" => "c1"}]} = Jason.decode(row.tool_calls)
  end

  test "list_sessions returns persisted sessions" do
    :ok = Store.create_session("sess-5", source: "tui", model: "gpt-4o")
    ids = Store.list_sessions() |> Enum.map(& &1.id)
    assert "sess-5" in ids
  end
end
