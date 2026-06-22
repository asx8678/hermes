defmodule Hermes.Sessions.SearchTest do
  @moduledoc """
  Tests for `Hermes.Sessions.Search` and `Hermes.Sessions.SessionSearch`.

  Ports the behavior exercised by `hermes_state.py:3466-3715`
  and `tools/session_search_tool.py`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Repo
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Search
  alias Hermes.Sessions.Session
  alias Hermes.Sessions.SessionSearch

  defp insert_session(attrs \\ []) do
    attrs = Enum.into(attrs, %{})
    id = Map.get(attrs, :id, "sess_#{System.unique_integer([:positive])}")

    %Session{}
    |> Session.changeset(%{
      id: id,
      source: Map.get(attrs, :source, "test_source"),
      model: Map.get(attrs, :model, "claude-test"),
      started_at: Map.get(attrs, :started_at, 1_718_000_000.0)
    })
    |> Repo.insert!()
  end

  defp insert_message(session_id, attrs) do
    attrs = Enum.into(attrs, %{})

    %Message{}
    |> Message.changeset(%{
      session_id: session_id,
      role: Map.get(attrs, :role, "user"),
      content: Map.get(attrs, :content, "hello world"),
      timestamp: Map.get(attrs, :timestamp, 1_718_000_001.0),
      active: Map.get(attrs, :active, 1),
      compacted: Map.get(attrs, :compacted, 0),
      tool_name: Map.get(attrs, :tool_name),
      tool_calls: Map.get(attrs, :tool_calls)
    })
    |> Repo.insert!()
  end

  describe "search/2" do
    test "returns matching messages with snippets" do
      session = insert_session()
      insert_message(session.id, content: "docker deployment on production")

      assert [%{snippet: snippet, content: "docker deployment on production"}] =
               Search.search("deployment")

      assert snippet =~ ">>>"
      assert snippet =~ "<<<"
    end

    test "supports phrase search" do
      session = insert_session()
      insert_message(session.id, content: "exact phrase test")
      insert_message(session.id, content: "exact not phrase")

      assert [%{content: "exact phrase test"}] =
               Search.search("\"exact phrase\"")
    end

    test "supports boolean OR" do
      session = insert_session()
      insert_message(session.id, content: "docker rules")
      insert_message(session.id, content: "kubernetes rules")

      results = Search.search("docker OR kubernetes")
      assert length(results) == 2
    end

    test "supports boolean NOT" do
      session = insert_session()
      insert_message(session.id, content: "python rocks")
      insert_message(session.id, content: "java rocks")

      assert [%{content: "python rocks"}] = Search.search("python NOT java")
    end

    test "supports prefix search" do
      session = insert_session()
      insert_message(session.id, content: "deploy the fix")

      assert [%{content: "deploy the fix"}] = Search.search("deploy*")
    end

    test "orders by BM25 rank by default" do
      session = insert_session()
      insert_message(session.id, content: "one two three four deployment")
      insert_message(session.id, content: "deployment")

      [first | _] = Search.search("deployment")
      assert first.content == "deployment"
    end

    test "newest sort orders by timestamp DESC" do
      session = insert_session()
      insert_message(session.id, content: "older deployment", timestamp: 1_000.0)
      insert_message(session.id, content: "newer deployment", timestamp: 2_000.0)

      [first, second] = Search.search("deployment", sort: "newest")
      assert first.content == "newer deployment"
      assert second.content == "older deployment"
    end

    test "oldest sort orders by timestamp ASC" do
      session = insert_session()
      insert_message(session.id, content: "older deployment", timestamp: 1_000.0)
      insert_message(session.id, content: "newer deployment", timestamp: 2_000.0)

      [first, second] = Search.search("deployment", sort: "oldest")
      assert first.content == "older deployment"
      assert second.content == "newer deployment"
    end

    test "excludes rewound rows (active=0, compacted=0)" do
      session = insert_session()
      insert_message(session.id, content: "rewound message", active: 0, compacted: 0)

      assert Search.search("rewound", include_inactive: false) == []
    end

    test "includes compacted rows (active=0, compacted=1)" do
      session = insert_session()
      insert_message(session.id, content: "compacted message", active: 0, compacted: 1)

      assert [%{content: "compacted message"}] =
               Search.search("compacted", include_inactive: false)
    end

    test "include_inactive searches every row" do
      session = insert_session()
      insert_message(session.id, content: "rewound message", active: 0, compacted: 0)

      assert [%{content: "rewound message"}] =
               Search.search("rewound", include_inactive: true)
    end

    test "filters by source" do
      s1 = insert_session(source: "desktop")
      s2 = insert_session(source: "subagent")
      insert_message(s1.id, content: "desktop message")
      insert_message(s2.id, content: "subagent message")

      assert [%{source: "desktop"}] = Search.search("message", source_filter: ["desktop"])
      assert [] = Search.search("message", source_filter: ["missing"])
    end

    test "filters by role" do
      session = insert_session()
      insert_message(session.id, content: "user says hi", role: "user")
      insert_message(session.id, content: "assistant says hi", role: "assistant")

      assert [%{role: "user"}] = Search.search("hi", role_filter: ["user"])
    end

    test "excludes hidden sources by default" do
      s1 = insert_session(source: "desktop")
      s2 = insert_session(source: "subagent")
      insert_message(s1.id, content: "visible message")
      insert_message(s2.id, content: "hidden message")

      assert [%{source: "desktop"}] = Search.search("message")
    end

    test "searches tool_name and tool_calls content" do
      session = insert_session()

      insert_message(session.id,
        content: "",
        role: "assistant",
        tool_name: "search_tool",
        tool_calls: "[{\"query\": \"elixir fts5\"}]"
      )

      assert [%{tool_name: "search_tool"}] = Search.search("search_tool")
      assert [%{snippet: snippet}] = Search.search("elixir")
      assert snippet =~ "elixir"
    end
  end

  describe "search/2 CJK" do
    test "CJK query with >=3 chars uses trigram path" do
      session = insert_session()
      insert_message(session.id, content: "大别山项目很重要")

      assert [%{content: "大别山项目很重要"}] = Search.search("大别山项目")
    end

    test "CJK query with 1-2 chars uses LIKE fallback" do
      session = insert_session()
      insert_message(session.id, content: "广西的风景")

      assert [%{content: "广西的风景"}] = Search.search("广西")
    end

    test "mixed CJK query with short token falls back to LIKE" do
      session = insert_session()
      insert_message(session.id, content: "广西桂林漓江游")

      results = Search.search("广西 OR 桂林 OR 漓江")
      assert length(results) >= 1
    end

    test "CJK boolean query with all long tokens uses trigram" do
      session = insert_session()
      insert_message(session.id, content: "广西壮族自治区桂林市")

      results = Search.search("广西壮族自治区 OR 桂林市")
      assert length(results) == 1
    end
  end

  describe "sanitize_fts5_query/1" do
    test "preserves quoted phrases" do
      assert Search.sanitize_fts5_query("\"exact phrase\"") == "\"exact phrase\""
    end

    test "strips unmatched quotes" do
      result = Search.sanitize_fts5_query("hello \"world")
      assert result =~ "hello"
      assert result =~ "world"
      refute result =~ "\""
    end

    test "quotes hyphenated terms" do
      assert Search.sanitize_fts5_query("my-app config") == "\"my-app\" config"
    end

    test "removes dangling boolean operators" do
      assert Search.sanitize_fts5_query("hello AND") == "hello"
      assert Search.sanitize_fts5_query("OR world") == "world"
    end
  end

  describe "browse/1" do
    test "returns recent sessions by last active" do
      s1 = insert_session(source: "desktop", started_at: 1_000.0)
      s2 = insert_session(source: "desktop", started_at: 2_000.0)

      insert_message(s1.id, content: "older", timestamp: 1_100.0)
      insert_message(s2.id, content: "newer", timestamp: 2_100.0)

      [first, second] = Search.browse(limit: 10)
      assert first.session_id == s2.id
      assert second.session_id == s1.id
    end

    test "excludes hidden sources by default" do
      s1 = insert_session(source: "desktop")
      s2 = insert_session(source: "subagent")

      insert_message(s1.id, content: "hello")
      insert_message(s2.id, content: "hello")

      assert [%{source: "desktop"}] = Search.browse(limit: 10)
    end
  end

  describe "get_anchored_view/3" do
    test "returns window centered on anchor message" do
      session = insert_session()

      for i <- 1..10 do
        insert_message(session.id,
          content: "message #{i}",
          timestamp: 1_000.0 + i,
          role: if(rem(i, 2) == 0, do: "assistant", else: "user")
        )
      end

      messages = Repo.all(from(m in Message, where: m.session_id == ^session.id, order_by: m.id))
      anchor = Enum.at(messages, 4)

      view = Search.get_anchored_view(session.id, anchor.id, window: 2)
      assert length(view["window"]) == 5
      assert view["messages_before"] == 2
      assert view["messages_after"] == 2
      assert List.first(view["window"])["content"] == "message 3"
      assert List.last(view["window"])["content"] == "message 7"
    end

    test "filters tool roles by default" do
      session = insert_session()

      for i <- 1..5 do
        insert_message(session.id,
          content: "message #{i}",
          timestamp: 1_000.0 + i,
          role: if(i == 3, do: "tool", else: "user")
        )
      end

      messages = Repo.all(from(m in Message, where: m.session_id == ^session.id, order_by: m.id))
      anchor = Enum.at(messages, 2)

      view = Search.get_anchored_view(session.id, anchor.id, window: 2)
      window_ids = Enum.map(view["window"], & &1["id"])
      assert anchor.id in window_ids
      refute Enum.any?(view["window"], &(&1["role"] == "tool" and &1["id"] != anchor.id))
    end

    test "returns empty view when anchor is missing" do
      session = insert_session()
      insert_message(session.id, content: "only message")

      assert %{
               "window" => [],
               "messages_before" => 0,
               "messages_after" => 0
             } = Search.get_anchored_view(session.id, 9_999_999)
    end
  end

  describe "SessionSearch.search/1" do
    test "DISCOVERY mode returns sessions with snippets and windows" do
      session = insert_session()

      for i <- 1..10 do
        insert_message(session.id,
          content: "content #{i}",
          timestamp: 1_000.0 + i
        )
      end

      response = SessionSearch.search(query: "content 5")
      assert response["success"]
      assert response["mode"] == "discover"
      assert [result] = response["results"]
      assert result["snippet"] != ""
      assert length(result["messages"]) >= 1
      assert result["messages_before"] >= 0
      assert result["messages_after"] >= 0
    end

    test "DISCOVERY dedupes by session" do
      session = insert_session()

      for i <- 1..5 do
        insert_message(session.id, content: "repeated session content #{i}")
      end

      response = SessionSearch.search(query: "content", limit: 3)
      assert response["count"] == 1
    end

    test "BROWSE mode lists recent sessions" do
      session = insert_session()
      insert_message(session.id, content: "recent")

      response = SessionSearch.search(limit: 5)
      assert response["success"]
      assert response["mode"] == "browse"
      assert [result] = response["results"]
      assert result.session_id == session.id
    end

    test "SCROLL mode returns anchored window" do
      session = insert_session()

      messages =
        for i <- 1..10 do
          insert_message(session.id, content: "msg #{i}", timestamp: 1_000.0 + i)
        end

      anchor = Enum.at(messages, 4)

      response =
        SessionSearch.search(
          session_id: session.id,
          around_message_id: anchor.id,
          window: 2
        )

      assert response["success"]
      assert response["mode"] == "scroll"
      assert response["around_message_id"] == anchor.id
      assert length(response["messages"]) == 5

      assert Enum.any?(response["messages"], & &1["anchor"])
    end

    test "SCROLL rejects missing anchor" do
      response =
        SessionSearch.search(
          session_id: "missing_session",
          around_message_id: 1
        )

      refute response["success"]
      assert response["error"] =~ "not in session_id"
    end
  end
end
