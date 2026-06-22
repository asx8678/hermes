defmodule Hermes.Sessions.SessionSearch do
  @moduledoc """
  Single-shape session search tool with three modes:

    * DISCOVERY - pass a `query` to search sessions via FTS5 and return
      top results with snippets and message windows.
    * SCROLL - pass `session_id` + `around_message_id` to fetch an anchored
      message window without FTS5.
    * BROWSE - pass no search args to list recent sessions.

  Ports the discovery/scroll/browse shapes from
  `tools/session_search_tool.py`.
  """

  alias Hermes.Sessions.Search

  @type context :: %{session_id: String.t()} | %{}

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "session_search",
        toolset: "memory",
        schema: session_search_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Invokes the session_search tool from the registry.
  """
  @spec invoke(map(), context()) :: map()
  def invoke(args, context) do
    opts = [
      query: Map.get(args, "query"),
      session_id: Map.get(args, "session_id"),
      around_message_id: Map.get(args, "around_message_id"),
      window: Map.get(args, "window"),
      limit: Map.get(args, "limit"),
      role_filter: Map.get(args, "role_filter"),
      sort: Map.get(args, "sort"),
      current_session_id: Map.get(context, :session_id)
    ]

    search(opts)
  end

  defp always_available, do: true
  @hidden_session_sources ["subagent", "tool"]

  @doc """
  Run the session_search tool and return a JSON-encodable response map.

  Mode is inferred from the args:
    * `:query` present (and no anchor) -> DISCOVERY
    * `:session_id` + `:around_message_id` -> SCROLL
    * no `:query`, `:session_id`, or `:around_message_id` -> BROWSE

  Options:
    * `:query` - FTS5 search string
    * `:session_id` - target session for scroll
    * `:around_message_id` - anchor message id for scroll
    * `:window` - message window radius (default 5)
    * `:limit` - max sessions for discovery/browse (default 3)
    * `:role_filter` - comma-separated roles or list of roles
    * `:sort` - `"newest"` or `"oldest"` for discovery
    * `:exclude_sources` - sources to exclude (default `["subagent", "tool"]`)
    * `:current_session_id` - skip the current session lineage in discovery
  """
  @spec search(keyword()) :: map()
  def search(opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    around_message_id = Keyword.get(opts, :around_message_id)

    cond do
      is_binary(session_id) and String.trim(session_id) != "" and around_message_id != nil ->
        scroll_mode(opts)

      is_binary(session_id) and String.trim(session_id) != "" ->
        # Read mode is not part of the A5 contract; treat it as scroll missing
        # an anchor by returning a clear error.
        %{
          "success" => false,
          "error" => "scroll requires around_message_id"
        }

      true ->
        query = Keyword.get(opts, :query)

        if is_binary(query) and String.trim(query) != "" do
          discovery_mode(opts)
        else
          browse_mode(opts)
        end
    end
  end

  defp browse_mode(opts) do
    limit = clamp_limit(Keyword.get(opts, :limit, 3))
    exclude_sources = Keyword.get(opts, :exclude_sources, @hidden_session_sources)

    results = Search.browse(limit: limit, exclude_sources: exclude_sources)

    %{
      "success" => true,
      "mode" => "browse",
      "results" => results,
      "count" => length(results),
      "message" =>
        "Showing #{length(results)} most recent sessions. Pass a query= to search, or session_id+around_message_id to scroll."
    }
  end

  defp discovery_mode(opts) do
    query = opts |> Keyword.get(:query) |> to_string() |> String.trim()
    limit = clamp_limit(Keyword.get(opts, :limit, 3))
    sort = normalize_sort(Keyword.get(opts, :sort))
    exclude_sources = Keyword.get(opts, :exclude_sources, @hidden_session_sources)
    current_session_id = Keyword.get(opts, :current_session_id)
    role_filter = normalize_role_filter(Keyword.get(opts, :role_filter, ["user", "assistant"]))

    results =
      Search.search(query,
        role_filter: role_filter,
        exclude_sources: exclude_sources,
        limit: 50,
        offset: 0,
        sort: sort
      )

    if results == [] do
      %{
        "success" => true,
        "mode" => "discover",
        "query" => query,
        "results" => [],
        "count" => 0,
        "message" => "No matching sessions found."
      }
    else
      seen_sessions =
        results
        |> Enum.reject(fn r ->
          current_session_id &&
            (r.session_id == current_session_id ||
               r.session_id == current_session_id)
        end)
        |> Enum.reduce(%{}, fn r, acc ->
          sid = r.session_id

          if Map.has_key?(acc, sid) do
            acc
          else
            Map.put(acc, sid, r)
          end
        end)
        |> Map.values()
        |> Enum.take(limit)

      session_results =
        Enum.map(seen_sessions, fn match ->
          hit_sid = match.session_id
          msg_id = match.id

          view = Search.get_anchored_view(hit_sid, msg_id, window: 5, bookend: 3)

          %{
            "session_id" => hit_sid,
            "when" => format_timestamp(match.session_started),
            "source" => match.source || "unknown",
            "model" => match.model || "unknown",
            "title" => nil,
            "matched_role" => match.role,
            "match_message_id" => msg_id,
            "snippet" => match.snippet || "",
            "bookend_start" => Enum.map(view["bookend_start"], &shape_message/1),
            "messages" => Enum.map(view["window"], fn m -> shape_message(m, msg_id) end),
            "bookend_end" => Enum.map(view["bookend_end"], &shape_message/1),
            "messages_before" => view["messages_before"],
            "messages_after" => view["messages_after"]
          }
        end)

      %{
        "success" => true,
        "mode" => "discover",
        "query" => query,
        "results" => session_results,
        "count" => length(session_results),
        "sessions_searched" => length(seen_sessions)
      }
    end
  end

  defp scroll_mode(opts) do
    session_id = Keyword.get(opts, :session_id) |> String.trim()

    around_message_id =
      case Keyword.get(opts, :around_message_id) do
        id when is_binary(id) -> String.to_integer(id)
        id when is_integer(id) -> id
        _ -> nil
      end

    window =
      case Keyword.get(opts, :window, 5) do
        w when is_binary(w) -> String.to_integer(w)
        w when is_integer(w) -> w
        _ -> 5
      end

    window = max(1, min(window, 20))

    if around_message_id == nil do
      %{
        "success" => false,
        "error" => "scroll requires integer around_message_id"
      }
    else
      view = Search.get_anchored_view(session_id, around_message_id, window: window, bookend: 0)

      if view["window"] == [] do
        %{
          "success" => false,
          "error" => "around_message_id #{around_message_id} not in session_id #{session_id}"
        }
      else
        %{
          "success" => true,
          "mode" => "scroll",
          "session_id" => session_id,
          "around_message_id" => around_message_id,
          "window" => window,
          "messages" => Enum.map(view["window"], fn m -> shape_message(m, around_message_id) end),
          "messages_before" => view["messages_before"],
          "messages_after" => view["messages_after"]
        }
      end
    end
  end

  defp shape_message(m, anchor_id \\ nil) do
    entry =
      case m do
        %{} = msg ->
          %{
            "id" => Map.get(msg, "id") || Map.get(msg, :id),
            "role" => Map.get(msg, "role") || Map.get(msg, :role),
            "content" => Map.get(msg, "content") || Map.get(msg, :content),
            "timestamp" => Map.get(msg, "timestamp") || Map.get(msg, :timestamp)
          }
      end

    entry =
      if tool_name = Map.get(m, "tool_name") || Map.get(m, :tool_name) do
        Map.put(entry, "tool_name", tool_name)
      else
        entry
      end

    entry =
      if tool_calls = Map.get(m, "tool_calls") || Map.get(m, :tool_calls) do
        Map.put(entry, "tool_calls", tool_calls)
      else
        entry
      end

    entry =
      if tool_call_id = Map.get(m, "tool_call_id") || Map.get(m, :tool_call_id) do
        Map.put(entry, "tool_call_id", tool_call_id)
      else
        entry
      end

    if anchor_id != nil and (Map.get(m, "id") == anchor_id || Map.get(m, :id) == anchor_id) do
      Map.put(entry, "anchor", true)
    else
      entry
    end
  end

  defp normalize_role_filter(nil), do: ["user", "assistant"]
  defp normalize_role_filter(roles) when is_list(roles), do: roles

  defp normalize_role_filter(roles) when is_binary(roles) do
    roles
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp normalize_role_filter(_), do: ["user", "assistant"]

  defp normalize_sort(nil), do: nil

  defp normalize_sort(sort) when is_binary(sort) do
    norm = String.trim(sort) |> String.downcase()
    if norm in ["newest", "oldest"], do: norm, else: nil
  end

  defp normalize_sort(_), do: nil

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> clamp_limit(n)
      :error -> 3
    end
  end

  defp clamp_limit(limit) when is_integer(limit) do
    max(1, min(limit, 10))
  end

  defp clamp_limit(_), do: 3

  defp format_timestamp(nil), do: "unknown"

  defp format_timestamp(ts) when is_float(ts) or is_integer(ts) do
    case DateTime.from_unix(trunc(ts * 1000), :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%B %d, %Y at %I:%M %p")
      _ -> to_string(ts)
    end
  end

  defp format_timestamp(ts), do: to_string(ts)

  # ---------------------------------------------------------------------------
  # Tool schema
  # ---------------------------------------------------------------------------

  defp session_search_schema do
    %{
      name: "session_search",
      description: "Search across sessions and messages using FTS5, scroll within a session, or browse recent sessions.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "FTS5 search query for discovery mode."
          },
          session_id: %{
            type: "string",
            description: "Target session id for scroll mode."
          },
          around_message_id: %{
            type: "string",
            description: "Anchor message id for scroll mode; requires session_id."
          },
          window: %{
            type: "integer",
            description: "Message window radius for scroll mode.",
            default: 5
          },
          limit: %{
            type: "integer",
            description: "Maximum sessions to return for discovery or browse.",
            default: 3
          },
          role_filter: %{
            type: "string",
            description: "Comma-separated roles to filter (e.g. \"user,assistant\")."
          },
          sort: %{
            type: "string",
            enum: ["newest", "oldest"],
            description: "Sort order for discovery results.",
            default: "newest"
          }
        },
        required: []
      }
    }
  end
end
