defmodule Hermes.Tools.XSearchTool do
  @moduledoc """
  X/Twitter search tool backed by the xAI Responses API.

  Port of `tools/x_search_tool.py:274`. Uses Finch for HTTP.
  """

  @user_agent "HermesBot/1.0"
  @default_timeout 180_000
  @max_results_chars 100_000

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "x_search",
        toolset: "x_search",
        schema: x_search_schema(),
        handler: &invoke/2,
        check_fn: &check_available/0
      }
    ]
  end

  @doc """
  Runs an X search query through the xAI Responses API.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    query = Map.get(args, "query", "")

    if not is_binary(query) or String.trim(query) == "" do
      %{"success" => false, "error" => "query is required"}
    else
      allowed = normalize_handles(Map.get(args, "allowed_x_handles"))
      excluded = normalize_handles(Map.get(args, "excluded_x_handles"))
      from_date = Map.get(args, "from_date")
      to_date = Map.get(args, "to_date")
      enable_images = Map.get(args, "enable_image_understanding", false)
      enable_videos = Map.get(args, "enable_video_understanding", false)

      with :ok <- validate_date_range(from_date, to_date) do
        do_search(query, %{
          allowed: allowed,
          excluded: excluded,
          from_date: from_date,
          to_date: to_date,
          enable_image_understanding: enable_images,
          enable_video_understanding: enable_videos
        })
      else
        {:error, msg} -> %{"success" => false, "error" => msg}
      end
    end
  end

  defp do_search(query, filters) do
    api_key = resolve_api_key()
    base_url = Application.get_env(:hermes, :xai_base_url, "https://api.x.ai/v1")
    model = Application.get_env(:hermes, :x_search_model, "grok-4-20-reasoning")
    timeout = Application.get_env(:hermes, :x_search_timeout, @default_timeout)

    if is_nil(api_key) or api_key == "" do
      %{"success" => false, "error" => "XAI_API_KEY not configured"}
    else
      body = build_payload(query, model, filters)
      url = "#{base_url}/responses"

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"User-Agent", @user_agent}
      ]

      request = Finch.build(:post, url, headers, Jason.encode!(body))

      case Finch.request(request, Hermes.Finch, receive_timeout: timeout) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          parse_success_response(response_body, query, model, filters)

        {:ok, %{status: status, body: response_body}} ->
          %{
            "success" => false,
            "provider" => "xai",
            "tool" => "x_search",
            "error" => "HTTP #{status}: #{String.slice(response_body, 0, 500)}"
          }

        {:error, error} ->
          %{
            "success" => false,
            "provider" => "xai",
            "tool" => "x_search",
            "error" => "request failed: #{format_error(error)}"
          }
      end
    end
  end

  defp build_payload(query, model, filters) do
    tool = %{
      type: "x_search",
      query: query
    }

    tool =
      if filters.allowed && filters.allowed != [] do
        Map.put(tool, :allowed_x_handles, filters.allowed)
      else
        tool
      end

    tool =
      if filters.excluded && filters.excluded != [] do
        Map.put(tool, :excluded_x_handles, filters.excluded)
      else
        tool
      end

    tool = maybe_put(tool, :from_date, filters.from_date)
    tool = maybe_put(tool, :to_date, filters.to_date)
    tool = Map.put(tool, :enable_image_understanding, filters.enable_image_understanding)
    tool = Map.put(tool, :enable_video_understanding, filters.enable_video_understanding)

    %{
      model: model,
      input: [
        %{role: "user", content: query}
      ],
      tools: [tool],
      store: false
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_success_response(body, query, model, filters) do
    case Jason.decode(body) do
      {:ok, response} ->
        answer = extract_answer(response)
        citations = Map.get(response, "citations", [])
        inline_citations = extract_inline_citations(response)

        degraded =
          has_narrowing_filter?(filters) and citations == [] and inline_citations == []

        %{
          "success" => true,
          "provider" => "xai",
          "tool" => "x_search",
          "model" => model,
          "query" => query,
          "answer" => String.slice(answer, 0, @max_results_chars),
          "citations" => citations,
          "inline_citations" => inline_citations,
          "degraded" => degraded,
          "degraded_reason" =>
            if(degraded, do: "no citations returned for filtered query", else: nil)
        }

      {:error, reason} ->
        %{
          "success" => false,
          "provider" => "xai",
          "tool" => "x_search",
          "error" => "failed to decode response: #{format_error(reason)}"
        }
    end
  end

  defp extract_answer(%{"output_text" => text}) when is_binary(text), do: text

  defp extract_answer(%{"output" => outputs}) when is_list(outputs) do
    outputs
    |> Enum.flat_map(&Map.get(&1, "content", []))
    |> Enum.find_value("", fn item ->
      case item do
        %{"type" => "output_text", "text" => text} -> text
        %{"type" => "text", "text" => text} -> text
        _ -> nil
      end
    end)
  end

  defp extract_answer(_), do: ""

  defp extract_inline_citations(%{"output" => outputs}) when is_list(outputs) do
    outputs
    |> Enum.flat_map(&Map.get(&1, "content", []))
    |> Enum.flat_map(fn item ->
      annotations = Map.get(item, "annotations", [])

      Enum.filter(annotations, fn a ->
        is_map(a) && Map.get(a, "type") == "url_citation"
      end)
    end)
  end

  defp extract_inline_citations(_), do: []

  defp has_narrowing_filter?(filters) do
    filters.allowed != [] or filters.excluded != [] or
      filters.from_date not in [nil, ""] or
      filters.to_date not in [nil, ""]
  end

  defp normalize_handles(nil), do: []
  defp normalize_handles(list) when is_list(list), do: Enum.map(list, &normalize_handle/1)
  defp normalize_handles(_), do: []

  defp normalize_handle(handle) when is_binary(handle) do
    handle |> String.trim() |> String.replace_prefix("@", "")
  end

  defp normalize_handle(_), do: ""

  defp validate_date_range(nil, nil), do: :ok
  defp validate_date_range("", ""), do: :ok

  defp validate_date_range(from_date, to_date) do
    from = parse_date(from_date)
    to = parse_date(to_date)

    cond do
      from == :error ->
        {:error, "invalid from_date format, expected YYYY-MM-DD"}

      to == :error ->
        {:error, "invalid to_date format, expected YYYY-MM-DD"}

      from != nil and to != nil and Date.compare(from, to) == :gt ->
        {:error, "from_date cannot be after to_date"}

      from != nil and Date.compare(from, Date.utc_today()) == :gt ->
        {:error, "from_date cannot be in the future"}

      true ->
        :ok
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp resolve_api_key do
    System.get_env("XAI_API_KEY") ||
      Application.get_env(:hermes, :xai_api_key)
  end

  defp check_available do
    key = resolve_api_key()
    is_binary(key) and key != ""
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  defp x_search_schema do
    %{
      name: "x_search",
      description: "Search X/Twitter via the xAI Responses API.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "What to search for on X."},
          allowed_x_handles: %{type: "array", items: %{type: "string"}},
          excluded_x_handles: %{type: "array", items: %{type: "string"}},
          from_date: %{type: "string", description: "YYYY-MM-DD"},
          to_date: %{type: "string", description: "YYYY-MM-DD"},
          enable_image_understanding: %{type: "boolean"},
          enable_video_understanding: %{type: "boolean"}
        },
        required: ["query"]
      }
    }
  end
end
