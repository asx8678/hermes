defmodule Hermes.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API transport.

  Speaks the OpenAI `/chat/completions` wire format, so it works with OpenAI
  itself and any compatible endpoint. The default `base_url` targets
  [makora](https://inference.makora.com/v1), which hosts
  `moonshotai/Kimi-K2.7-Code` and `zai-org/GLM-5.2-FP8`.

  Mirrors `Hermes.Providers.Anthropic`. Hermes' internal message and tool format
  is already OpenAI-shaped (assistant `tool_calls`, `role: "tool"` results, and
  `{"type" => "function", ...}` tool schemas — see `Hermes.Sessions.TurnLoop`),
  so `convert_messages/2` and `convert_tools/1` are near pass-through.

  Configuration:

    * `config :hermes, :openai_base_url` (default `#{inspect("https://inference.makora.com/v1")}`)
    * `config :hermes, :openai_api_key` or the `MAKORA_OPTIMIZE_TOKEN` /
      `OPENAI_API_KEY` environment variables (read at call time).
  """

  @behaviour Hermes.Providers.Transport

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Providers.Types.Usage

  @default_max_tokens 16_384
  @default_base_url "https://inference.makora.com/v1"

  # OpenAI finish_reason -> normalized finish reason.
  @stop_reason_map %{
    "stop" => "stop",
    "length" => "length",
    "tool_calls" => "tool_calls",
    "function_call" => "tool_calls",
    "content_filter" => "content_filter"
  }

  @impl true
  def api_mode, do: "openai_chat"

  @impl true
  @spec convert_messages([map()], keyword()) :: [map()]
  def convert_messages(messages, _opts \\ []) when is_list(messages) do
    # Stored messages are already OpenAI-shaped. Pass through untouched — do not
    # inspect internals, as messages may be atom- or string-keyed (Jason encodes
    # both to JSON string keys).
    messages
  end

  @impl true
  @spec convert_tools([map()] | nil) :: [map()]
  def convert_tools(nil), do: []

  def convert_tools(tools) when is_list(tools) do
    # Tools are already in OpenAI `{"type" => "function", "function" => ...}` form.
    # Only apply the same hygiene as Anthropic: drop empty names, dedup by name.
    tools
    |> Enum.reject(&(&1["function"]["name"] in [nil, ""]))
    |> Enum.uniq_by(& &1["function"]["name"])
  end

  @impl true
  @spec build_kwargs(String.t(), [map()], [map()] | nil, keyword()) :: map()
  def build_kwargs(model, messages, tools, params \\ []) do
    openai_messages = convert_messages(messages)
    openai_tools = if tools, do: convert_tools(tools), else: []

    # makora's GLM/Kimi (and modern OpenAI models) expect `max_completion_tokens`
    # rather than the deprecated `max_tokens`.
    kwargs = %{
      model: model,
      messages: openai_messages,
      max_completion_tokens: Keyword.get(params, :max_tokens, @default_max_tokens)
    }

    kwargs = if openai_tools != [], do: Map.put(kwargs, :tools, openai_tools), else: kwargs

    case Keyword.get(params, :tool_choice) do
      nil -> kwargs
      choice -> Map.put(kwargs, :tool_choice, choice)
    end
  end

  @impl true
  @spec normalize_response(map(), keyword()) :: NormalizedResponse.t()
  def normalize_response(response, opts \\ []) when is_map(response) do
    strip_tool_prefix? = Keyword.get(opts, :strip_tool_prefix, false)

    choice = response |> Map.get("choices", []) |> List.first()
    message = (choice && choice["message"]) || %{}

    content =
      case message["content"] do
        c when is_binary(c) and c != "" -> c
        _ -> nil
      end

    reasoning =
      case message["reasoning_content"] || message["reasoning"] do
        r when is_binary(r) and r != "" -> r
        _ -> nil
      end

    %NormalizedResponse{
      content: content,
      tool_calls: normalize_tool_calls(message["tool_calls"], strip_tool_prefix?),
      finish_reason: map_finish_reason(choice && choice["finish_reason"]),
      reasoning: reasoning,
      usage: extract_usage(response["usage"]),
      provider_data: nil
    }
  end

  defp normalize_tool_calls(tool_calls, _strip?) when tool_calls in [nil, []], do: nil

  defp normalize_tool_calls(tool_calls, strip?) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      fn_map = tc["function"] || %{}

      ToolCall.new(
        id: tc["id"],
        name: maybe_strip_mcp_prefix(fn_map["name"] || "", strip?),
        arguments: fn_map["arguments"] || "{}"
      )
    end)
  end

  defp maybe_strip_mcp_prefix(name, true) do
    if String.starts_with?(name, "mcp__"),
      do: String.replace_prefix(name, "mcp__", ""),
      else: name
  end

  defp maybe_strip_mcp_prefix(name, _), do: name

  defp extract_usage(nil), do: nil

  defp extract_usage(usage) when is_map(usage) do
    cached =
      case usage["prompt_tokens_details"] do
        %{"cached_tokens" => c} when is_integer(c) -> c
        _ -> 0
      end

    %Usage{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0,
      cached_tokens: cached
    }
  end

  @impl true
  @spec validate_response(map() | nil) :: boolean()
  def validate_response(nil), do: false

  def validate_response(response) when is_map(response) do
    match?([_ | _], response["choices"])
  end

  @impl true
  @spec map_finish_reason(String.t() | nil) :: String.t()
  def map_finish_reason(raw_reason) when is_binary(raw_reason) do
    Map.get(@stop_reason_map, raw_reason, "stop")
  end

  def map_finish_reason(_), do: "stop"

  @doc """
  Stream a request to the OpenAI Chat Completions API and return the accumulated
  `NormalizedResponse`.

  Accumulates streamed `delta` content, `reasoning_content`, and (fragmented)
  `tool_calls` into a final response. Returns `{:error, {:http_error, status,
  body}}` for non-2xx responses.
  """
  @spec stream(String.t(), [map()], keyword(), atom()) ::
          {:ok, NormalizedResponse.t()} | {:error, term()}
  def stream(model, messages, opts \\ [], finch_name \\ Hermes.Finch) do
    headers = [
      {"authorization", "Bearer " <> fetch_api_key()},
      {"content-type", "application/json"}
    ]

    tools = Keyword.get(opts, :tools)
    params = Keyword.get(opts, :params, [])

    body =
      build_kwargs(model, messages, tools, params)
      |> Map.put(:stream, true)
      |> Map.put(:stream_options, %{include_usage: true})
      |> Jason.encode!()

    request = Finch.build(:post, chat_completions_url(), headers, body)

    case Finch.stream(request, finch_name, initial_acc(), &handle_stream_chunk/2) do
      {:ok, %{status: status, error_body: body}} when is_integer(status) and status >= 400 ->
        {:error, {:http_error, status, body}}

      {:ok, acc} ->
        {:ok, acc |> flush_buffer() |> build_response_from_acc() |> normalize_response(opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Test seam: run a list of raw SSE chunk binaries through the same accumulation
  # path as `stream/4` (chunks may split JSON lines at arbitrary byte offsets).
  @spec accumulate([binary()]) :: NormalizedResponse.t()
  def accumulate(chunks) when is_list(chunks) do
    chunks
    |> Enum.reduce(initial_acc(), &handle_stream_chunk({:data, &1}, &2))
    |> flush_buffer()
    |> build_response_from_acc()
    |> normalize_response([])
  end

  defp initial_acc do
    %{
      status: nil,
      error_body: "",
      buffer: "",
      content: "",
      reasoning: "",
      # index => %{id, name, arguments}
      tool_calls: %{},
      finish_reason: nil,
      usage: nil
    }
  end

  defp fetch_api_key do
    Application.get_env(:hermes, :openai_api_key) ||
      System.get_env("MAKORA_OPTIMIZE_TOKEN") ||
      System.get_env("OPENAI_API_KEY") ||
      ""
  end

  defp base_url, do: Application.get_env(:hermes, :openai_base_url, @default_base_url)

  defp chat_completions_url, do: String.trim_trailing(base_url(), "/") <> "/chat/completions"

  # --- SSE streaming -------------------------------------------------------

  defp handle_stream_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_stream_chunk({:headers, _headers}, acc), do: acc

  defp handle_stream_chunk({:data, data}, %{status: status} = acc)
       when is_integer(status) and status >= 400 do
    %{acc | error_body: acc.error_body <> data}
  end

  defp handle_stream_chunk({:data, data}, acc) do
    # Buffer partial lines: a `data:` JSON line can be split across TCP chunks
    # (notably tool-call argument fragments).
    {lines, rest} = split_complete_lines(acc.buffer <> data)
    Enum.reduce(lines, %{acc | buffer: rest}, &process_sse_line/2)
  end

  defp handle_stream_chunk(_, acc), do: acc

  defp split_complete_lines(text) do
    parts = String.split(text, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp flush_buffer(%{buffer: ""} = acc), do: acc
  defp flush_buffer(%{buffer: buffer} = acc), do: process_sse_line(buffer, %{acc | buffer: ""})

  defp process_sse_line(line, acc) do
    case String.trim(line) do
      "" ->
        acc

      "data:" <> payload ->
        case String.trim(payload) do
          "[DONE]" -> acc
          json -> decode_and_process(json, acc)
        end

      _ ->
        acc
    end
  end

  defp decode_and_process(json, acc) do
    case Jason.decode(json) do
      {:ok, event} -> process_event(event, acc)
      _ -> acc
    end
  end

  defp process_event(event, acc) do
    acc =
      case event["usage"] do
        usage when is_map(usage) -> %{acc | usage: usage}
        _ -> acc
      end

    case event |> Map.get("choices", []) |> List.first() do
      nil -> acc
      choice -> process_choice(choice, acc)
    end
  end

  defp process_choice(choice, acc) do
    delta = choice["delta"] || %{}

    acc = append_text(acc, :content, delta["content"])
    acc = append_text(acc, :reasoning, delta["reasoning_content"] || delta["reasoning"])
    acc = accumulate_tool_calls(delta["tool_calls"], acc)

    case choice["finish_reason"] do
      nil -> acc
      reason -> %{acc | finish_reason: reason}
    end
  end

  defp append_text(acc, key, text) when is_binary(text),
    do: Map.update!(acc, key, &(&1 <> text))

  defp append_text(acc, _key, _text), do: acc

  defp accumulate_tool_calls(nil, acc), do: acc

  defp accumulate_tool_calls(tool_calls, acc) when is_list(tool_calls) do
    Enum.reduce(tool_calls, acc, fn tc, acc ->
      index = tc["index"] || 0
      existing = Map.get(acc.tool_calls, index, %{id: nil, name: nil, arguments: ""})
      fn_map = tc["function"] || %{}

      updated = %{
        id: existing.id || tc["id"],
        name: existing.name || fn_map["name"],
        arguments: existing.arguments <> (fn_map["arguments"] || "")
      }

      %{acc | tool_calls: Map.put(acc.tool_calls, index, updated)}
    end)
  end

  # Rebuild a non-streaming-shaped response so `normalize_response/2` is the single
  # source of truth for both streaming and (future) non-streaming responses.
  defp build_response_from_acc(acc) do
    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, tc} ->
        %{
          "id" => tc.id,
          "type" => "function",
          "function" => %{"name" => tc.name, "arguments" => tc.arguments}
        }
      end)

    message =
      %{}
      |> maybe_put("content", blank_to_nil(acc.content))
      |> maybe_put("reasoning_content", blank_to_nil(acc.reasoning))
      |> maybe_put("tool_calls", if(tool_calls == [], do: nil, else: tool_calls))

    %{
      "choices" => [%{"message" => message, "finish_reason" => acc.finish_reason}],
      "usage" => acc.usage
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
