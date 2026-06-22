defmodule Hermes.Tools.WebTool do
  @moduledoc """
  Web search and content extraction tool.

  Minimal port of `tools/web_tools.py:1356`. Uses Finch for HTTP requests and
  a simple regex-based HTML stripper. No browser rendering or JavaScript
  execution.
  """

  @type context :: %{session_id: String.t()} | %{session_pid: pid()} | %{}

  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.0 HermesBot/1.0"
  @receive_timeout_ms 15_000
  @max_extract_chars 10_000
  @max_results 100

  # ---------------------------------------------------------------------------
  # Tool registration
  # ---------------------------------------------------------------------------

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "web_search",
        toolset: "web",
        schema: web_search_schema(),
        handler: &search/2,
        check_fn: &always_available/0
      },
      %{
        name: "web_extract",
        toolset: "web",
        schema: web_extract_schema(),
        handler: &extract/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a web action based on the provided arguments.

  Accepts either an explicit `"action"` key or infers it from the presence of
  `"query"` (search) or `"url"` (extract).
  """
  @spec invoke(map(), context()) :: map()
  def invoke(%{"action" => "search"} = args, context), do: search(args, context)
  def invoke(%{"action" => "extract"} = args, context), do: extract(args, context)

  def invoke(args, context) do
    cond do
      Map.has_key?(args, "query") -> search(args, context)
      Map.has_key?(args, "url") -> extract(args, context)
      true -> %{"success" => false, "error" => "unknown web action: provide 'query' or 'url'"}
    end
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @doc """
  Searches the web for the given query and returns a list of results.
  """
  @spec search(map(), context()) :: map()
  def search(args, _context) do
    query = Map.get(args, "query", "")
    limit = normalize_limit(Map.get(args, "limit", 5))

    if not is_binary(query) or String.trim(query) == "" do
      %{"success" => false, "error" => "query is required"}
    else
      case configured_search_backend() do
        :duckduckgo -> search_duckduckgo(query, limit)
        endpoint when is_binary(endpoint) -> search_endpoint(endpoint, query, limit)
      end
    end
  end

  @doc """
  Fetches a URL and returns the readable text content.
  """
  @spec extract(map(), context()) :: map()
  def extract(args, _context) do
    url = Map.get(args, "url", "")

    if not is_binary(url) or String.trim(url) == "" do
      %{"success" => false, "error" => "url is required"}
    else
      case fetch_url(url) do
        {:ok, body, final_url} ->
          title = extract_title(body)
          text = strip_html(body)

          %{
            "success" => true,
            "url" => final_url,
            "title" => title,
            "content" => String.slice(text, 0, @max_extract_chars)
          }

        {:error, reason} ->
          %{"success" => false, "error" => "failed to fetch url: #{format_error(reason)}"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Search backends
  # ---------------------------------------------------------------------------

  defp configured_search_backend do
    env = System.get_env("WEB_SEARCH_BACKEND")
    config = Application.get_env(:hermes, Hermes.Tools.WebTool, [])[:search_backend]

    backend = env || config

    case backend do
      nil -> :duckduckgo
      "duckduckgo" -> :duckduckgo
      url when is_binary(url) and byte_size(url) > 0 -> url
      _ -> :duckduckgo
    end
  end

  defp search_duckduckgo(query, limit) do
    url = "https://html.duckduckgo.com/html/?q=#{URI.encode_www_form(query)}"

    case fetch_url(url) do
      {:ok, body, _final_url} ->
        if duckduckgo_blocked?(body) do
          %{
            "success" => false,
            "error" =>
              "DuckDuckGo returned a bot challenge. Configure a search endpoint via WEB_SEARCH_BACKEND or :hermes, Hermes.Tools.WebTool, :search_backend."
          }
        else
          results = parse_duckduckgo_results(body, limit)

          %{
            "success" => true,
            "data" => %{"web" => results},
            "count" => length(results)
          }
        end

      {:error, reason} ->
        %{"success" => false, "error" => "search request failed: #{format_error(reason)}"}
    end
  end

  defp duckduckgo_blocked?(body) do
    String.contains?(body, "Unfortunately, bots use DuckDuckGo too") or
      String.contains?(body, "anomaly-modal") or
      String.contains?(body, "challenge-form")
  end

  defp search_endpoint(endpoint, query, limit) do
    base = URI.parse(endpoint)
    existing = base.query || ""
    sep = if(existing == "", do: "", else: "&")

    url =
      URI.to_string(%{
        base
        | query: "#{existing}#{sep}q=#{URI.encode_www_form(query)}&limit=#{limit}"
      })

    case fetch_url(url) do
      {:ok, body, _final_url} ->
        case Jason.decode(body) do
          {:ok, results} when is_list(results) ->
            web = Enum.map(results, &normalize_search_result/1) |> Enum.take(limit)
            %{"success" => true, "data" => %{"web" => web}, "count" => length(web)}

          {:ok, %{"results" => results}} when is_list(results) ->
            web = Enum.map(results, &normalize_search_result/1) |> Enum.take(limit)
            %{"success" => true, "data" => %{"web" => web}, "count" => length(web)}

          {:ok, %{"data" => %{"web" => web}}} when is_list(web) ->
            results = Enum.map(web, &normalize_search_result/1) |> Enum.take(limit)
            %{"success" => true, "data" => %{"web" => results}, "count" => length(results)}

          {:ok, other} ->
            %{"success" => false, "error" => "unexpected endpoint response: #{inspect(other)}"}

          {:error, _} ->
            %{"success" => false, "error" => "endpoint returned non-JSON response"}
        end

      {:error, reason} ->
        %{"success" => false, "error" => "endpoint request failed: #{format_error(reason)}"}
    end
  end

  defp parse_duckduckgo_results(html, limit) do
    titles =
      Regex.scan(
        ~r/<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)<\/a>/is,
        html
      )

    urls =
      Regex.scan(
        ~r/<a[^>]+class="result__url"[^>]+href="([^"]+)"[^>]*>(.*?)<\/a>/is,
        html
      )

    snippets =
      Regex.scan(
        ~r/<div[^>]+class="result__snippet"[^>]*>(.*?)<\/div>/is,
        html
      )

    count = Enum.count([length(titles), length(urls), length(snippets)], &(&1 > 0))

    if count == 0 do
      # Fallback: the no-JS HTML may use a different layout; try looser patterns.
      fallback_parse_results(html, limit)
    else
      do_zip_duckduckgo_results(titles, urls, snippets, limit)
    end
  end

  defp do_zip_duckduckgo_results(titles, urls, snippets, limit) do
    max_len = max(max(length(titles), length(urls)), length(snippets))

    0..(max_len - 1)
    |> Enum.map(fn i ->
      title_tuple = Enum.at(titles, i)
      url_tuple = Enum.at(urls, i)
      snippet_tuple = Enum.at(snippets, i)

      raw_href = if(title_tuple, do: elem(title_tuple, 1), else: "")
      title_html = if(title_tuple, do: elem(title_tuple, 2), else: "")
      display_url_html = if(url_tuple, do: elem(url_tuple, 2), else: "")
      snippet_html = if(snippet_tuple, do: elem(snippet_tuple, 1), else: "")

      resolved_url = resolve_duckduckgo_url(raw_href, display_url_html)

      %{
        "title" => strip_html(title_html),
        "url" => resolved_url,
        "description" => strip_html(snippet_html),
        "position" => i + 1
      }
    end)
    |> Enum.filter(fn r -> r["title"] != "" or r["url"] != "" end)
    |> Enum.take(limit)
  end

  defp fallback_parse_results(html, limit) do
    # Look for any <a> tags that look like search result titles paired with
    # nearby text snippets. This is intentionally permissive.
    blocks =
      Regex.scan(
        ~r/<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>.*?<p[^>]*>(.*?)<\/p>/is,
        html
      )

    blocks
    |> Enum.map(fn [_, href, title, snippet] ->
      %{
        "title" => strip_html(title),
        "url" => resolve_duckduckgo_url(href, ""),
        "description" => strip_html(snippet),
        "position" => 0
      }
    end)
    |> Enum.take(limit)
    |> Enum.with_index(fn result, idx -> Map.put(result, "position", idx + 1) end)
  end

  defp resolve_duckduckgo_url(href, display_url_html) do
    # DuckDuckGo wraps external links in a redirect; the real URL is in the
    # `uddg` query parameter.
    with [_, encoded] <- Regex.run(~r/uddg=([^&]+)/, href),
         decoded <- URI.decode(encoded) do
      decoded
    else
      _ ->
        display = strip_html(display_url_html)

        cond do
          String.starts_with?(href, "http") -> href
          display != "" -> "https://#{display}"
          true -> href
        end
    end
  end

  defp normalize_search_result(%{} = result) do
    %{
      "title" => Map.get(result, "title", ""),
      "url" => Map.get(result, "url", ""),
      "description" => Map.get(result, "description", ""),
      "position" => Map.get(result, "position", 0)
    }
  end

  defp normalize_search_result(_other),
    do: %{"title" => "", "url" => "", "description" => "", "position" => 0}

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp fetch_url(url, redirects \\ 0)
  defp fetch_url(_url, redirects) when redirects > 5, do: {:error, :too_many_redirects}

  defp fetch_url(url, redirects) do
    headers = [
      {"User-Agent", @user_agent},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"}
    ]

    req = Finch.build(:get, url, headers)

    case Finch.request(req, Hermes.Finch, receive_timeout: @receive_timeout_ms) do
      {:ok, %Finch.Response{status: status, body: body, headers: response_headers}}
      when status in 301..302 ->
        case get_header(response_headers, "location") do
          nil ->
            {:error, {:redirect, status, body}}

          location ->
            next = URI.merge(url, location) |> URI.to_string()
            fetch_url(next, redirects + 1)
        end

      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body, url}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(key) == name_lower, do: value, else: nil
    end)
  end

  # ---------------------------------------------------------------------------
  # HTML stripping
  # ---------------------------------------------------------------------------

  defp strip_html(html) when is_binary(html) do
    html
    |> remove_blocks(~r/<script[^>]*>.*?<\/script>/is)
    |> remove_blocks(~r/<style[^>]*>.*?<\/style>/is)
    |> remove_blocks(~r/<nav[^>]*>.*?<\/nav>/is)
    |> remove_blocks(~r/<header[^>]*>.*?<\/header>/is)
    |> remove_blocks(~r/<footer[^>]*>.*?<\/footer>/is)
    |> remove_blocks(~r/<aside[^>]*>.*?<\/aside>/is)
    |> remove_tags(~r/<[^>]+>/)
    |> decode_entities()
    |> collapse_whitespace()
  end

  defp strip_html(_), do: ""

  defp extract_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> strip_html(title)
      _ -> ""
    end
  end

  defp remove_blocks(html, regex), do: Regex.replace(regex, html, " ")
  defp remove_tags(html, regex), do: Regex.replace(regex, html, " ")

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/[\s\x00-\x08\x0B\x0C\x0E-\x1F]+/, " ")
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Misc helpers
  # ---------------------------------------------------------------------------

  defp normalize_limit(limit) when is_integer(limit), do: max(1, min(limit, @max_results))

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} -> normalize_limit(n)
      _ -> 5
    end
  end

  defp normalize_limit(_), do: 5

  defp format_error({:http_error, status, body}) do
    "HTTP #{status}: #{String.slice(body, 0, 200)}"
  end

  defp format_error(%Mint.TransportError{reason: reason}),
    do: "transport error: #{inspect(reason)}"

  defp format_error(other), do: inspect(other)

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp web_search_schema do
    %{
      name: "web_search",
      description:
        "Search the web for information. Returns up to 5 results by default with titles, URLs, and descriptions.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query to look up on the web."
          },
          limit: %{
            type: "integer",
            description: "Maximum number of results to return.",
            minimum: 1,
            maximum: @max_results,
            default: 5
          }
        },
        required: ["query"]
      }
    }
  end

  defp web_extract_schema do
    %{
      name: "web_extract",
      description:
        "Extract readable text content from a web page URL. Fetches the page, strips HTML tags, and returns the text.",
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "URL of the web page to extract content from."
          }
        },
        required: ["url"]
      }
    }
  end
end
