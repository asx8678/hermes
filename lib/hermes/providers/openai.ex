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
  def convert_messages(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model)
    strip_extra_content = not model_consumes_thought_signature?(model)

    needs_sanitize =
      Enum.any?(messages, fn
        msg when not is_map(msg) -> false
        msg ->
          cond do
            # Strip Codex Responses API fields, tool_name, timestamp
            Map.has_key?(msg, "codex_reasoning_items") or
              Map.has_key?(msg, "codex_message_items") or
              Map.has_key?(msg, "tool_name") or
              Map.has_key?(msg, "timestamp") ->
              true

            # Strip Hermes-internal scaffolding markers (_-prefixed keys)
            Enum.any?(Map.keys(msg), fn k ->
              is_binary(k) and String.starts_with?(k, "_")
            end) ->
              true

            # Strip extra_content on tool_calls for non-Gemini models
            case msg["tool_calls"] do
              tcs when is_list(tcs) ->
                Enum.any?(tcs, fn tc ->
                  is_map(tc) and (
                    Map.has_key?(tc, "call_id") or
                    Map.has_key?(tc, "response_item_id") or
                    (strip_extra_content and Map.has_key?(tc, "extra_content"))
                  )
                end)

              _ ->
                false
            end

            true ->
              false
          end
      end)

    if needs_sanitize do
      Enum.map(messages, &sanitize_message(&1, strip_extra_content))
    else
      messages
    end
  end

  defp sanitize_message(msg, strip_extra_content) when is_map(msg) do
    msg
    |> Map.drop(~w(codex_reasoning_items codex_message_items tool_name timestamp))
    |> drop_internal_markers()
    |> sanitize_tool_calls(strip_extra_content)
  end

  defp sanitize_message(msg, _), do: msg

  defp drop_internal_markers(msg) do
    Enum.reduce(Map.keys(msg), msg, fn
      k, acc when is_binary(k) and binary_part(k, 0, 1) == "_" ->
        Map.delete(acc, k)
      _, acc -> acc
    end)
  end

  defp sanitize_tool_calls(%{"tool_calls" => tcs} = msg, strip_extra_content)
       when is_list(tcs) do
    cleaned =
      Enum.map(tcs, fn
        tc when is_map(tc) ->
          tc =
            if strip_extra_content,
              do: Map.delete(tc, "extra_content"),
              else: tc

          tc
          |> Map.delete("call_id")
          |> Map.delete("response_item_id")

        tc ->
          tc
      end)

    Map.put(msg, "tool_calls", cleaned)
  end

  defp sanitize_tool_calls(msg, _), do: msg

  # Gemini 3 thinking models consume thought_signature via extra_content on tool_calls.
  defp model_consumes_thought_signature?(model) when is_binary(model) do
    m = String.downcase(model)
    String.contains?(m, "gemini") or String.contains?(m, "gemini-3")
  end

  defp model_consumes_thought_signature?(_), do: false

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
    openai_messages = convert_messages(messages, model: model)
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
    finish_reason = map_finish_reason(choice && choice["finish_reason"])

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

    # Capture reasoning_content and reasoning_details in provider_data for
    # downstream replay (thinking prefill, cross-turn coherence).
    # Ports Python chat_completions.py:652-668.
    provider_data =
      []
      |> maybe_put_provider(:reasoning_content, message["reasoning_content"])
      |> maybe_put_provider(:reasoning_details, message["reasoning_details"])

    # OpenAI structured-refusal: when a model declines, the API populates
    # message.refusal and leaves content empty. Without capturing it the
    # refusal looks like an empty response, triggering 3 retries of a
    # deterministic refusal. Promote to content + content_filter finish.
    # Ports Python chat_completions.py:670-702.
    {content, finish_reason, provider_data} =
      handle_refusal(message, content, finish_reason, provider_data)

    %NormalizedResponse{
      content: content,
      tool_calls: normalize_tool_calls(message["tool_calls"], strip_tool_prefix?),
      finish_reason: finish_reason,
      reasoning: reasoning,
      usage: extract_usage(response["usage"]),
      provider_data: if(provider_data == [], do: nil, else: Map.new(provider_data))
    }
  end

  defp handle_refusal(message, content, finish_reason, provider_data) do
    refusal = message["refusal"]

    if is_binary(refusal) and String.trim(refusal) != "" do
      provider_data = [{:refusal, refusal} | provider_data]
      has_text = is_binary(content) and String.trim(content) != ""
      has_tool_calls = is_list(message["tool_calls"]) and message["tool_calls"] != []

      if not has_text and not has_tool_calls do
        {refusal, promote_refusal_finish(finish_reason), provider_data}
      else
        {content, finish_reason, provider_data}
      end
    else
      {content, finish_reason, provider_data}
    end
  end

  defp promote_refusal_finish("stop"), do: "content_filter"
  defp promote_refusal_finish(nil), do: "content_filter"
  defp promote_refusal_finish(other), do: other

  defp maybe_put_provider(acc, _key, nil), do: acc
  defp maybe_put_provider(acc, _key, ""), do: acc
  defp maybe_put_provider(acc, key, value), do: [{key, value} | acc]

  defp normalize_tool_calls(tool_calls, _strip?) when tool_calls in [nil, []], do: nil

  defp normalize_tool_calls(tool_calls, strip?) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      fn_map = tc["function"] || %{}

      # Preserve provider-specific extras (Gemini thought_signature via
      # extra_content) for cross-turn replay. Ports Python
      # chat_completions.py:619-641.
      provider_data =
        case tc["extra_content"] do
          nil -> nil
          ec -> %{"extra_content" => ec}
        end

      ToolCall.new(
        id: tc["id"],
        name: maybe_strip_mcp_prefix(fn_map["name"] || "", strip?),
        arguments: fn_map["arguments"] || "{}",
        provider_data: provider_data
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
    api_key = Keyword.get(opts, :api_key) || fetch_api_key()

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]

    tools = Keyword.get(opts, :tools)
    params = Keyword.get(opts, :params, [])
    stream_to = Keyword.get(opts, :stream_to)

    body =
      build_kwargs(model, messages, tools, params)
      |> Map.put(:stream, true)
      |> Map.put(:stream_options, %{include_usage: true})
      |> Jason.encode!()

    request =
      Finch.build(:post, chat_completions_url(Keyword.get(opts, :base_url)), headers, body)

    case Finch.stream(request, finch_name, initial_acc(stream_to), &handle_stream_chunk/2) do
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

  defp initial_acc(stream_to \\ nil) do
    %{
      status: nil,
      error_body: "",
      buffer: "",
      content: "",
      reasoning: "",
      # index => %{id, name, arguments}
      tool_calls: %{},
      finish_reason: nil,
      usage: nil,
      # session id to broadcast incremental deltas to, or nil
      stream_to: stream_to
    }
  end

  defp fetch_api_key do
    Application.get_env(:hermes, :openai_api_key) ||
      System.get_env("MAKORA_OPTIMIZE_TOKEN") ||
      System.get_env("OPENAI_API_KEY") ||
      ""
  end

  defp base_url, do: Application.get_env(:hermes, :openai_base_url, @default_base_url)

  defp chat_completions_url(override) do
    base = override || base_url()
    String.trim_trailing(base, "/") <> "/chat/completions"
  end

  # Broadcast an incremental content delta to the session topic so the TUI and
  # LiveView render tokens as they arrive. No-op unless a session id was passed.
  defp maybe_broadcast_delta(nil, _text), do: :ok
  defp maybe_broadcast_delta(_session_id, text) when text in [nil, ""], do: :ok

  defp maybe_broadcast_delta(session_id, text) when is_binary(text) do
    Phoenix.PubSub.broadcast(Hermes.PubSub, "session:#{session_id}", {:stream_delta, text})
    :ok
  end

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

    maybe_broadcast_delta(acc.stream_to, delta["content"])

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
