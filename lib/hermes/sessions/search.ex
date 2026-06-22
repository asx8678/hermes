defmodule Hermes.Sessions.Search do
  @moduledoc """
  Full-text search across session messages using SQLite FTS5.

  Ports the Python `search_messages` method from `hermes_state.py:3466-3715`
  and supporting helpers from `hermes_state.py:3377-3464`.

  Supports:
    * Simple keywords: `"docker deployment"`
    * Phrases: `'"exact phrase"'`
    * Boolean: `"docker OR kubernetes"`, `"python NOT java"`
    * Prefix: `"deploy*"`

  CJK queries are routed automatically:
    * 3+ CJK characters per token -> `messages_fts_trigram` trigram FTS5 table
    * 1-2 CJK characters -> `LIKE` fallback on `content`/`tool_name`/`tool_calls`
    * Non-CJK -> `messages_fts` unicode61 FTS5 table

  Sort options:
    * `nil` (default) - BM25 rank only
    * `"newest"` - timestamp DESC, then rank
    * `"oldest"` - timestamp ASC, then rank
  """

  alias Hermes.Repo

  @hidden_session_sources ["subagent", "tool"]

  @fts5_special_regex ~r/[+{}():\"^]/
  @leading_asterisk_regex ~r/(^|\s)\*/
  @repeated_asterisk_regex ~r/\*+/
  @leading_boolean_regex ~r/^(AND|OR|NOT)\b\s*/i
  @trailing_boolean_regex ~r/\s+(AND|OR|NOT)\s*$/i
  @compound_term_regex ~r/\b(\w+(?:[._-]\w+)+)\b/
  @quoted_phrase_regex ~r/"[^"]*"/

  # CJK Unicode ranges used by the Python source.
  @cjk_ranges [
    {0x4E00, 0x9FFF},
    {0x3400, 0x4DBF},
    {0x20000, 0x2A6DF},
    {0x3000, 0x303F},
    {0x3040, 0x309F},
    {0x30A0, 0x30FF},
    {0xAC00, 0xD7AF}
  ]

  @doc """
  Search messages using FTS5 with optional filters and temporal ordering.

  Options:
    * `:source_filter` - list of sources to include
    * `:exclude_sources` - list of sources to exclude (defaults to `["subagent", "tool"]`)
    * `:role_filter` - list of roles to include
    * `:limit` - max results (default 20)
    * `:offset` - pagination offset (default 0)
    * `:sort` - `"newest"`, `"oldest"`, or `nil` (default)
    * `:include_inactive` - include rewound rows (default false)

  Returns a list of result maps with atom keys.
  """
  @spec search(String.t(), keyword()) :: list(map())
  def search(query, opts \\ []) do
    query = sanitize_fts5_query(query || "")

    if query == "" do
      []
    else
      do_search(query, opts)
    end
  end

  @doc """
  Return recent sessions ordered by most-recently-active first.

  Options:
    * `:limit` - max sessions (default 20)
    * `:exclude_sources` - list of sources to exclude (defaults to `["subagent", "tool"]`)
  """
  @spec browse(keyword()) :: list(map())
  def browse(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    exclude_sources = Keyword.get(opts, :exclude_sources, @hidden_session_sources)

    {where_sql, params} = build_session_where([], exclude_sources)

    sql = """
    SELECT
      s.id,
      s.title,
      s.source,
      s.model,
      s.started_at,
      COALESCE(m.last_active, s.started_at) AS last_active
    FROM sessions s
    LEFT JOIN (
      SELECT session_id, MAX(timestamp) AS last_active
      FROM messages
      GROUP BY session_id
    ) m ON m.session_id = s.id
    #{where_sql}
    ORDER BY last_active DESC
    LIMIT ?
    """

    params = params ++ [limit]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            id,
                            title,
                            source,
                            model,
                            started_at,
                            last_active
                          ] ->
          %{
            session_id: id,
            title: title,
            source: source,
            model: model,
            started_at: started_at,
            last_active: last_active
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Return an anchored window of messages plus optional session bookends.

  `window` controls how many messages on each side of the anchor are included.
  `bookend` controls how many non-empty user/assistant messages from the start
  and end of the session are returned. Set `bookend` to 0 to disable bookends.
  """
  @spec get_anchored_view(String.t(), integer(), keyword()) :: map()
  def get_anchored_view(session_id, around_message_id, opts \\ []) do
    window = Keyword.get(opts, :window, 5)
    bookend = Keyword.get(opts, :bookend, 3)
    keep_roles = Keyword.get(opts, :keep_roles, ["user", "assistant"])

    window = max(0, window)
    bookend = max(0, bookend)

    primitive = get_messages_around(session_id, around_message_id, window)
    window_rows = primitive["window"]

    if window_rows == [] do
      %{
        "window" => [],
        "messages_before" => 0,
        "messages_after" => 0,
        "bookend_start" => [],
        "bookend_end" => []
      }
    else
      keep_set = if keep_roles, do: MapSet.new(keep_roles), else: nil

      filtered_window =
        if keep_set do
          Enum.filter(window_rows, fn m ->
            m["id"] == around_message_id || MapSet.member?(keep_set, m["role"])
          end)
        else
          window_rows
        end

      window_min_id = List.first(window_rows)["id"]
      window_max_id = List.last(window_rows)["id"]

      {bookend_start_rows, bookend_end_rows} =
        if bookend > 0 do
          role_clause =
            if keep_roles do
              placeholders = Enum.map_join(keep_roles, ",", fn _ -> "?" end)
              " AND role IN (#{placeholders})"
            else
              ""
            end

          role_params = if keep_roles, do: keep_roles, else: []

          start_sql = """
          SELECT id, role, content, timestamp, tool_name, tool_calls, tool_call_id
          FROM messages
          WHERE session_id = ? AND id < ?#{role_clause} AND length(content) > 0
          ORDER BY id ASC
          LIMIT ?
          """

          end_sql = """
          SELECT id, role, content, timestamp, tool_name, tool_calls, tool_call_id
          FROM messages
          WHERE session_id = ? AND id > ?#{role_clause} AND length(content) > 0
          ORDER BY id DESC
          LIMIT ?
          """

          start_rows =
            case Repo.query(start_sql, [session_id, window_min_id] ++ role_params ++ [bookend]) do
              {:ok, %{rows: rows}} -> Enum.map(rows, &message_row_to_map/1)
              {:error, _} -> []
            end

          end_rows =
            case Repo.query(end_sql, [session_id, window_max_id] ++ role_params ++ [bookend]) do
              {:ok, %{rows: rows}} -> Enum.map(rows, &message_row_to_map/1) |> Enum.reverse()
              {:error, _} -> []
            end

          {start_rows, end_rows}
        else
          {[], []}
        end

      %{
        "window" => filtered_window,
        "messages_before" => primitive["messages_before"],
        "messages_after" => primitive["messages_after"],
        "bookend_start" => bookend_start_rows,
        "bookend_end" => bookend_end_rows
      }
    end
  end

  defp do_search(query, opts) do
    sort = normalize_sort(Keyword.get(opts, :sort))
    source_filter = Keyword.get(opts, :source_filter)
    exclude_sources = Keyword.get(opts, :exclude_sources, @hidden_session_sources)
    role_filter = Keyword.get(opts, :role_filter)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    include_inactive = Keyword.get(opts, :include_inactive, false)

    order_by_sql =
      case sort do
        "newest" -> "ORDER BY m.timestamp DESC, rank"
        "oldest" -> "ORDER BY m.timestamp ASC, rank"
        _ -> "ORDER BY rank"
      end

    if contains_cjk?(query) do
      do_cjk_search(
        query,
        source_filter,
        exclude_sources,
        role_filter,
        limit,
        offset,
        order_by_sql,
        include_inactive
      )
    else
      case do_fts_search(
             query,
             source_filter,
             exclude_sources,
             role_filter,
             limit,
             offset,
             order_by_sql,
             include_inactive,
             "messages_fts"
           ) do
        {:ok, results} -> results
        {:error, _} -> []
      end
    end
  end

  defp do_cjk_search(
         query,
         source_filter,
         exclude_sources,
         role_filter,
         limit,
         offset,
         order_by_sql,
         include_inactive
       ) do
    raw_query = String.trim(query, "\"") |> String.trim()
    cjk_count = count_cjk(raw_query)

    tokens_for_check =
      raw_query
      |> String.split()
      |> Enum.filter(fn t ->
        String.upcase(t) not in ["AND", "OR", "NOT"] and contains_cjk?(t)
      end)

    any_short_cjk = Enum.any?(tokens_for_check, fn t -> count_cjk(t) < 3 end)

    if cjk_count >= 3 and not any_short_cjk do
      # Try trigram FTS5 path.  Only fall back to LIKE on execution error;
      # an empty trigram result is a valid result, mirroring Python.
      trigram_query = build_trigram_query(raw_query)

      case do_fts_search(
             trigram_query,
             source_filter,
             exclude_sources,
             role_filter,
             limit,
             offset,
             order_by_sql,
             include_inactive,
             "messages_fts_trigram"
           ) do
        {:ok, results} ->
          results

        {:error, _} ->
          do_like_fallback(
            raw_query,
            source_filter,
            exclude_sources,
            role_filter,
            limit,
            offset,
            include_inactive
          )
      end
    else
      do_like_fallback(
        raw_query,
        source_filter,
        exclude_sources,
        role_filter,
        limit,
        offset,
        include_inactive
      )
    end
  end

  defp do_fts_search(
         query,
         source_filter,
         exclude_sources,
         role_filter,
         limit,
         offset,
         order_by_sql,
         include_inactive,
         fts_table
       ) do
    {where_clauses, params} =
      build_where_clauses(
        ["#{fts_table} MATCH ?"],
        [query],
        source_filter,
        exclude_sources,
        role_filter,
        include_inactive
      )

    snippet_call = "snippet(#{fts_table}, 0, '>>>', '<<<', '...', 40)"

    sql = """
    SELECT
      m.id,
      m.session_id,
      m.role,
      #{snippet_call} AS snippet,
      m.content,
      m.timestamp,
      m.tool_name,
      s.source,
      s.model,
      s.started_at AS session_started
    FROM #{fts_table}
    JOIN messages m ON m.id = #{fts_table}.rowid
    JOIN sessions s ON s.id = m.session_id
    WHERE #{Enum.join(where_clauses, " AND ")}
    #{order_by_sql}
    LIMIT ? OFFSET ?
    """

    params = params ++ [limit, offset]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &result_row_to_map/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_like_fallback(
         raw_query,
         source_filter,
         exclude_sources,
         role_filter,
         limit,
         offset,
         include_inactive
       ) do
    non_op_tokens =
      case String.split(raw_query) do
        [] -> [raw_query]
        tokens -> Enum.filter(tokens, fn t -> String.upcase(t) not in ["AND", "OR", "NOT"] end)
      end

    non_op_tokens = if non_op_tokens == [], do: [raw_query], else: non_op_tokens

    token_clauses =
      Enum.map(non_op_tokens, fn _tok ->
        "(m.content LIKE ? ESCAPE '\\' OR m.tool_name LIKE ? ESCAPE '\\' OR m.tool_calls LIKE ? ESCAPE '\\')"
      end)

    like_params =
      Enum.flat_map(non_op_tokens, fn tok ->
        esc = like_escape(tok)
        ["%#{esc}%", "%#{esc}%", "%#{esc}%"]
      end)

    {where_clauses, params} =
      build_where_clauses(
        ["(#{Enum.join(token_clauses, " OR ")})"],
        like_params,
        source_filter,
        exclude_sources,
        role_filter,
        include_inactive
      )

    first_token = hd(non_op_tokens)

    sql = """
    SELECT
      m.id,
      m.session_id,
      m.role,
      substr(m.content, max(1, instr(m.content, ?) - 40), 120) AS snippet,
      m.content,
      m.timestamp,
      m.tool_name,
      s.source,
      s.model,
      s.started_at AS session_started
    FROM messages m
    JOIN sessions s ON s.id = m.session_id
    WHERE #{Enum.join(where_clauses, " AND ")}
    ORDER BY m.timestamp DESC
    LIMIT ? OFFSET ?
    """

    params = [first_token] ++ params ++ [limit, offset]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &result_row_to_map/1)
      {:error, _} -> []
    end
  end

  defp build_where_clauses(
         clauses,
         params,
         source_filter,
         exclude_sources,
         role_filter,
         include_inactive
       ) do
    {clauses, params} =
      if not include_inactive do
        clauses = clauses ++ ["(m.active = 1 OR m.compacted = 1)"]
        {clauses, params}
      else
        {clauses, params}
      end

    {clauses, params} =
      if nonempty_list?(source_filter) do
        placeholders = Enum.map_join(source_filter, ",", fn _ -> "?" end)
        clauses = clauses ++ ["s.source IN (#{placeholders})"]
        {clauses, params ++ source_filter}
      else
        {clauses, params}
      end

    {clauses, params} =
      if nonempty_list?(exclude_sources) do
        placeholders = Enum.map_join(exclude_sources, ",", fn _ -> "?" end)
        clauses = clauses ++ ["s.source NOT IN (#{placeholders})"]
        {clauses, params ++ exclude_sources}
      else
        {clauses, params}
      end

    {clauses, params} =
      if nonempty_list?(role_filter) do
        placeholders = Enum.map_join(role_filter, ",", fn _ -> "?" end)
        clauses = clauses ++ ["m.role IN (#{placeholders})"]
        {clauses, params ++ role_filter}
      else
        {clauses, params}
      end

    {clauses, params}
  end

  defp build_session_where(params, exclude_sources) do
    if nonempty_list?(exclude_sources) do
      placeholders = Enum.map_join(exclude_sources, ",", fn _ -> "?" end)
      {"WHERE s.source NOT IN (#{placeholders})", params ++ exclude_sources}
    else
      {"", params}
    end
  end

  defp nonempty_list?(nil), do: false
  defp nonempty_list?([]), do: false
  defp nonempty_list?(_list), do: true

  defp result_row_to_map([
         id,
         session_id,
         role,
         snippet,
         content,
         timestamp,
         tool_name,
         source,
         model,
         session_started
       ]) do
    %{
      id: id,
      session_id: session_id,
      role: role,
      snippet: snippet,
      content: content,
      timestamp: timestamp,
      tool_name: tool_name,
      source: source,
      model: model,
      session_started: session_started
    }
  end

  defp message_row_to_map([
         id,
         role,
         content,
         timestamp,
         tool_name,
         tool_calls,
         tool_call_id
       ]) do
    %{
      "id" => id,
      "role" => role,
      "content" => content,
      "timestamp" => timestamp,
      "tool_name" => tool_name,
      "tool_calls" => tool_calls,
      "tool_call_id" => tool_call_id
    }
  end

  defp get_messages_around(session_id, around_message_id, window) do
    window = max(0, window)

    anchor_sql = """
    SELECT 1 FROM messages
    WHERE id = ? AND session_id = ?
    LIMIT 1
    """

    anchor_exists =
      case Repo.query(anchor_sql, [around_message_id, session_id]) do
        {:ok, %{rows: [[1]]}} -> true
        _ -> false
      end

    if not anchor_exists do
      %{"window" => [], "messages_before" => 0, "messages_after" => 0}
    else
      before_sql = """
      SELECT id, role, content, timestamp, tool_name, tool_calls, tool_call_id
      FROM messages
      WHERE session_id = ? AND id <= ?
      ORDER BY id DESC
      LIMIT ?
      """

      after_sql = """
      SELECT id, role, content, timestamp, tool_name, tool_calls, tool_call_id
      FROM messages
      WHERE session_id = ? AND id > ?
      ORDER BY id ASC
      LIMIT ?
      """

      before_rows =
        case Repo.query(before_sql, [session_id, around_message_id, window + 1]) do
          {:ok, %{rows: rows}} -> Enum.map(rows, &message_row_to_map/1) |> Enum.reverse()
          {:error, _} -> []
        end

      after_rows =
        case Repo.query(after_sql, [session_id, around_message_id, window]) do
          {:ok, %{rows: rows}} -> Enum.map(rows, &message_row_to_map/1)
          {:error, _} -> []
        end

      messages_before = max(0, length(before_rows) - 1)
      messages_after = length(after_rows)

      %{
        "window" => before_rows ++ after_rows,
        "messages_before" => messages_before,
        "messages_after" => messages_after
      }
    end
  end

  defp build_trigram_query(raw_query) do
    raw_query
    |> String.split()
    |> Enum.map(fn tok ->
      if String.upcase(tok) in ["AND", "OR", "NOT"] do
        tok
      else
        escaped = String.replace(tok, "\"", "\"\"")
        "\"#{escaped}\""
      end
    end)
    |> Enum.join(" ")
  end

  defp like_escape(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp normalize_sort(nil), do: nil

  defp normalize_sort(sort) when is_binary(sort) do
    norm = String.trim(sort) |> String.downcase()
    if norm in ["newest", "oldest"], do: norm, else: nil
  end

  defp normalize_sort(_), do: nil

  @doc false
  @spec sanitize_fts5_query(String.t()) :: String.t()
  def sanitize_fts5_query(query) do
    query = to_string(query)

    # Step 1: preserve balanced quoted phrases via placeholders.
    {preserved, sanitized} = preserve_quoted(query)

    # Step 2: strip remaining FTS5-special characters.
    sanitized = Regex.replace(@fts5_special_regex, sanitized, " ")

    # Step 3: collapse repeated asterisks and strip leading asterisks.
    sanitized = Regex.replace(@repeated_asterisk_regex, sanitized, "*")
    sanitized = Regex.replace(@leading_asterisk_regex, sanitized, "\\1")

    # Step 4: remove dangling boolean operators at start/end.
    sanitized = String.trim(sanitized)
    sanitized = Regex.replace(@leading_boolean_regex, sanitized, "")
    sanitized = String.trim(sanitized)
    sanitized = Regex.replace(@trailing_boolean_regex, sanitized, "")

    # Step 5: quote dotted/hyphenated/underscored compound terms.
    sanitized = Regex.replace(@compound_term_regex, sanitized, "\"\\1\"")

    # Step 6: restore preserved quoted phrases.
    restore_quoted(sanitized, preserved)
    |> String.trim()
  end

  defp preserve_quoted(query) do
    matches = Regex.scan(@quoted_phrase_regex, query) |> List.flatten()

    {reversed, replaced} =
      Enum.reduce(matches, {[], query}, fn match, {acc, text} ->
        placeholder = "\x00Q#{length(acc)}\x00"
        {acc ++ [match], String.replace(text, match, placeholder, global: false)}
      end)

    {Enum.reverse(reversed), replaced}
  end

  defp restore_quoted(sanitized, preserved) do
    Enum.reduce(Enum.with_index(preserved), sanitized, fn {quoted, idx}, text ->
      String.replace(text, "\x00Q#{idx}\x00", quoted, global: false)
    end)
  end

  @doc false
  @spec contains_cjk?(String.t()) :: boolean()
  def contains_cjk?(""), do: false

  def contains_cjk?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(&cjk_codepoint?/1)
  end

  @doc false
  @spec count_cjk(String.t()) :: non_neg_integer()
  def count_cjk(text) do
    text
    |> String.to_charlist()
    |> Enum.count(&cjk_codepoint?/1)
  end

  defp cjk_codepoint?(cp) do
    Enum.any?(@cjk_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)
  end
end
