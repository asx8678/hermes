defmodule Hermes.Test.SeedCorpus do
  @moduledoc """
  Generates a large test corpus of sessions and messages for FTS5 benchmarks.

  The corpus is designed to exercise the search paths implemented in
  `Hermes.Sessions.Search`:

    * English keyword queries on the `messages_fts` unicode61 table.
    * CJK trigram queries on the `messages_fts_trigram` table.
    * Short CJK LIKE fallback on `messages.content` / `tool_name` / `tool_calls`.
    * Temporal sorts and session browsing.

  Content includes realistic English and CJK text, mixed-language messages, and
  tool-call records. Some messages are marked `active: 0, compacted: 1` so the
  recall path still includes them (search filters on `active = 1 OR compacted = 1`).
  """

  alias Hermes.Repo
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Session

  @sources ["telegram", "discord", "slack", "cli", "email"]
  @models ["claude-sonnet", "gpt-4", "gemini-pro"]

  @english_templates [
    "docker deployment to the staging cluster took three minutes",
    "kubernetes pod logs show the container crashed after restart",
    "I ran the test suite locally and everything passed",
    "the CI pipeline failed on the git push step",
    "need to debug this python exception in production",
    "refactor the authentication middleware before release",
    "deploy the new version to production tomorrow morning",
    "the database migration ran successfully on sqlite",
    "looking at rust stack traces from the host process",
    "elixir supervision tree restarted the sidecar"
  ]

  @cjk_templates [
    "大别山项目进展顺利，下周可以交付",
    "广西客户的需求变更已经记录下来了",
    "上海团队正在准备docker部署",
    "测试环境的数据库迁移完成了",
    "这个功能的代码审查已经通过",
    "需要修复生产环境的异常",
    "大别山项目使用kubernetes管理容器",
    "广西办公室的网络连接不稳定",
    "明天进行产品发布前的最终测试",
    "请检查docker镜像的构建日志"
  ]

  @mixed_templates [
    "docker deployment 在大别山项目里已经就绪",
    "kubernetes 测试覆盖了广西的用例",
    "production test 需要在广西环境运行",
    "大别山 project 的 docker 镜像更新了",
    "广西 team 准备 deploy 到 production"
  ]

  @tool_names ["terminal", "execute_code", "browser", "session_search"]

  @doc """
  Inserts `sessions_count` sessions with `messages_per_session` messages each,
  then optimizes both FTS5 tables.
  """
  @spec seed(pos_integer(), pos_integer()) :: :ok
  def seed(sessions_count, messages_per_session) do
    now = System.system_time(:second)
    total_span = sessions_count * messages_per_session * 60 + 3600
    base_ts = now - total_span

    sessions_count
    |> build_sessions(base_ts)
    |> insert_sessions()

    sessions_count
    |> build_messages(messages_per_session, base_ts)
    |> insert_messages()

    optimize_fts!()

    :ok
  end

  defp build_sessions(count, base_ts) do
    Enum.map(1..count, fn i ->
      %{
        id: "seed_sess_#{i}",
        source: Enum.random(@sources),
        model: Enum.random(@models),
        title: "Session #{i}",
        started_at: base_ts + i * 3600.0,
        archived: if(rem(i, 10) == 0, do: 1, else: 0)
      }
    end)
  end

  defp insert_sessions(sessions) do
    sessions
    |> Enum.chunk_every(200)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Session, chunk, returning: false)
    end)
  end

  defp build_messages(sessions_count, messages_per_session, base_ts) do
    for si <- 1..sessions_count,
        mi <- 1..messages_per_session do
      session_id = "seed_sess_#{si}"
      index = (si - 1) * messages_per_session + (mi - 1)
      {role, tool_name, tool_calls} = role_and_tools(mi)
      {active, compacted} = active_state(si, mi)

      %{
        session_id: session_id,
        role: role,
        content: content_for(si, mi, index),
        timestamp: base_ts + si * 3600.0 + mi * 60.0,
        active: active,
        compacted: compacted,
        tool_name: tool_name,
        tool_calls: tool_calls
      }
    end
  end

  defp insert_messages(messages) do
    # Insert one session's worth at a time to stay comfortably under SQLite's
    # default parameter limit while still being faster than one-by-one inserts.
    messages
    |> Enum.chunk_every(10)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Message, chunk, returning: false)
    end)
  end

  defp content_for(si, mi, index) do
    template = pick_template(index)
    inject_target_terms(si, mi, template)
  end

  defp pick_template(index) do
    pool =
      case rem(index, 5) do
        0 -> @mixed_templates
        1 -> @cjk_templates
        2 -> @english_templates
        3 -> @cjk_templates
        _ -> @english_templates
      end

    Enum.at(pool, rem(index, length(pool)))
  end

  defp inject_target_terms(si, mi, template) do
    cond do
      rem(si, 50) == 0 and mi == 1 ->
        "docker deployment: #{template}"

      rem(si, 70) == 0 and mi == 2 ->
        "#{template}，大别山项目"

      rem(si, 90) == 0 and mi == 3 ->
        "广西 #{template}"

      rem(si, 30) == 0 and mi == 4 ->
        "test run: #{template}"

      true ->
        template
    end
  end

  defp role_and_tools(mi) do
    case rem(mi, 7) do
      0 ->
        tool_name = Enum.random(@tool_names)

        tool_calls =
          Jason.encode!(%{name: tool_name, arguments: %{command: "ls -la", timeout: 30}})

        {"tool", tool_name, tool_calls}

      1 ->
        {"system", nil, nil}

      _ ->
        role = Enum.random(["user", "assistant"])
        {role, nil, nil}
    end
  end

  defp active_state(si, mi) do
    if rem(si + mi, 5) == 0 do
      {0, 1}
    else
      {1, 0}
    end
  end

  defp optimize_fts! do
    Repo.query!("INSERT INTO messages_fts(messages_fts) VALUES('optimize')")
    Repo.query!("INSERT INTO messages_fts_trigram(messages_fts_trigram) VALUES('optimize')")
  end
end
