defmodule Hermes.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API transport.

  Ported from Python `agent/transports/anthropic.py:13-245` and
  `agent/anthropic_adapter.py:1504-2497`.
  """

  @behaviour Hermes.Providers.Transport

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Providers.Types.Usage

  @default_max_tokens 16_384

  @stop_reason_map %{
    "end_turn" => "stop",
    "tool_use" => "tool_calls",
    "max_tokens" => "length",
    "stop_sequence" => "stop",
    "refusal" => "content_filter",
    "model_context_window_exceeded" => "length"
  }

  @api_version "2023-06-01"
  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def api_mode, do: "anthropic_messages"

  @impl true
  @spec convert_messages([map()], keyword()) :: {String.t() | [map()] | nil, [map()]}
  def convert_messages(messages, _opts \\ []) when is_list(messages) do
    {system, rest} =
      Enum.reduce(messages, {nil, []}, fn msg, {sys, acc} ->
        case msg["role"] do
          "system" -> {extract_system_content(msg["content"]), acc}
          _ -> {sys, [msg | acc]}
        end
      end)

    {system, Enum.reverse(rest)}
  end

  defp extract_system_content(content) when is_binary(content), do: content

  defp extract_system_content(content) when is_list(content) do
    has_cache? = Enum.any?(content, &match?(%{"cache_control" => _}, &1))

    if has_cache? do
      Enum.filter(content, &is_map/1)
    else
      content
      |> Enum.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map_join("\n", & &1["text"])
    end
  end

  defp extract_system_content(_), do: nil

  @impl true
  @spec convert_tools([map()]) :: [map()]
  def convert_tools(tools) when is_list(tools) do
    tools
    |> Enum.reject(&(&1["function"]["name"] == ""))
    |> Enum.uniq_by(& &1["function"]["name"])
    |> Enum.map(fn tool ->
      fn_map = tool["function"]

      %{
        "name" => fn_map["name"],
        "description" => fn_map["description"] || "",
        "input_schema" => fn_map["parameters"] || %{"type" => "object", "properties" => %{}}
      }
    end)
  end

  def convert_tools(nil), do: []

  @impl true
  @spec build_kwargs(String.t(), [map()], [map()] | nil, keyword()) :: map()
  def build_kwargs(model, messages, tools, params \\ []) do
    {system, anthropic_messages} = convert_messages(messages)
    anthropic_tools = if tools, do: convert_tools(tools), else: []

    kwargs = %{
      model: model,
      messages: anthropic_messages,
      max_tokens: Keyword.get(params, :max_tokens, @default_max_tokens)
    }

    kwargs = if system, do: Map.put(kwargs, :system, system), else: kwargs
    kwargs = if anthropic_tools != [], do: Map.put(kwargs, :tools, anthropic_tools), else: kwargs

    kwargs =
      case Keyword.get(params, :tool_choice) do
        nil -> kwargs
        choice -> Map.put(kwargs, :tool_choice, choice)
      end

    kwargs =
      case Keyword.get(params, :reasoning_config) do
        nil -> kwargs
        config -> Map.put(kwargs, :reasoning, config)
      end

    kwargs
  end

  @impl true
  @spec normalize_response(map(), keyword()) :: NormalizedResponse.t()
  def normalize_response(response, opts \\ []) when is_map(response) do
    strip_tool_prefix? = Keyword.get(opts, :strip_tool_prefix, false)
    mcp_prefix = "mcp__"

    {text_parts, reasoning_parts, tool_calls} =
      Enum.reduce(response["content"] || [], {[], [], []}, fn block, {texts, reasoning, tcs} ->
        case block["type"] do
          "text" ->
            {[block["text"] | texts], reasoning, tcs}

          t when t in ["thinking", "redacted_thinking"] ->
            reasoning =
              if t == "thinking" do
                [block["thinking"] | reasoning]
              else
                reasoning
              end

            {texts, reasoning, tcs}

          "tool_use" ->
            name = block["name"]

            name =
              if strip_tool_prefix? and String.starts_with?(name, mcp_prefix) do
                String.replace_prefix(name, mcp_prefix, "")
              else
                name
              end

            tc =
              ToolCall.new(
                id: block["id"],
                name: name,
                arguments: block["input"] || %{}
              )

            {texts, reasoning, [tc | tcs]}

          _ ->
            {texts, reasoning, tcs}
        end
      end)

    content = if text_parts != [], do: Enum.reverse(text_parts) |> Enum.join("\n"), else: nil

    reasoning =
      if reasoning_parts != [], do: Enum.reverse(reasoning_parts) |> Enum.join("\n\n"), else: nil

    tool_calls = if tool_calls != [], do: Enum.reverse(tool_calls), else: nil

    usage = extract_usage(response["usage"])

    provider_data =
      if response["provider_data"] do
        response["provider_data"]
      else
        nil
      end

    %NormalizedResponse{
      content: content,
      tool_calls: tool_calls,
      finish_reason: map_finish_reason(response["stop_reason"]),
      reasoning: reasoning,
      usage: usage,
      provider_data: provider_data
    }
  end

  defp extract_usage(nil), do: nil

  defp extract_usage(usage) when is_map(usage) do
    %Usage{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cached_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  @impl true
  @spec validate_response(map() | nil) :: boolean()
  def validate_response(nil), do: false

  def validate_response(response) when is_map(response) do
    content = response["content"]

    cond do
      not is_list(content) ->
        false

      content == [] ->
        response["stop_reason"] in ["end_turn", "refusal"]

      true ->
        true
    end
  end

  @impl true
  @spec map_finish_reason(String.t() | nil) :: String.t()
  def map_finish_reason(raw_reason) when is_binary(raw_reason) do
    Map.get(@stop_reason_map, raw_reason, "stop")
  end

  def map_finish_reason(_), do: "stop"

  @doc """
  Stream a request to the Anthropic Messages API and return the accumulated
  `NormalizedResponse`.

  For Milestone A this accumulates text and tool_use blocks from SSE events
  into a final response. Incremental streaming to `Hermes.PubSub` will be
  added later.
  """
  @spec stream(String.t(), [map()], keyword(), atom()) ::
          {:ok, NormalizedResponse.t()} | {:error, term()}
  def stream(model, messages, opts \\ [], finch_name \\ Hermes.Finch) do
    api_key = Keyword.get(opts, :api_key) || fetch_api_key()
    url = anthropic_url(Keyword.get(opts, :base_url))

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    tools = Keyword.get(opts, :tools)
    params = Keyword.get(opts, :params, [])

    body =
      build_kwargs(model, messages, tools, params)
      |> Map.put(:stream, true)
      |> Jason.encode!()

    request = Finch.build(:post, url, headers, body)

    acc = %{
      blocks: [],
      current: nil,
      stop_reason: nil,
      usage: nil,
      event: nil,
      stream_to: Keyword.get(opts, :stream_to)
    }

    result =
      Finch.stream(request, finch_name, acc, fn chunk, inner_acc ->
        handle_stream_chunk(chunk, inner_acc)
      end)

    case result do
      {:ok, final_acc} ->
        response = build_response_from_acc(final_acc)
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_api_key do
    Application.get_env(:hermes, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY") ||
      ""
  end

  defp anthropic_url(nil), do: @api_url

  defp anthropic_url(base) when is_binary(base),
    do: String.trim_trailing(base, "/") <> "/messages"

  defp maybe_broadcast_delta(nil, _text), do: :ok
  defp maybe_broadcast_delta(_session_id, text) when text in [nil, ""], do: :ok

  defp maybe_broadcast_delta(session_id, text) when is_binary(text) do
    Phoenix.PubSub.broadcast(Hermes.PubSub, "session:#{session_id}", {:stream_delta, text})
    :ok
  end

  defp handle_stream_chunk({:data, data}, acc) do
    lines = String.split(data, "\n")

    Enum.reduce(lines, acc, fn line, inner_acc ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "event:") ->
          event = String.trim(String.replace_prefix(line, "event:", ""))
          %{inner_acc | event: event}

        String.starts_with?(line, "data:") ->
          json = String.trim(String.replace_prefix(line, "data:", ""))

          case Jason.decode(json) do
            {:ok, event_data} -> process_event(inner_acc.event, event_data, inner_acc)
            _ -> inner_acc
          end

        true ->
          inner_acc
      end
    end)
  end

  defp handle_stream_chunk(_, acc), do: acc

  defp process_event("content_block_start", %{"content_block" => block}, acc) do
    %{acc | current: block}
  end

  defp process_event("content_block_delta", %{"delta" => delta}, acc) do
    current = acc.current || %{}

    updated =
      case delta["type"] do
        "text_delta" ->
          maybe_broadcast_delta(acc.stream_to, delta["text"])
          text = current["text"] || ""
          Map.put(current, "text", text <> (delta["text"] || ""))

        "input_json_delta" ->
          partial = current["partial_json"] || ""
          Map.put(current, "partial_json", partial <> (delta["partial_json"] || ""))

        _ ->
          current
      end

    %{acc | current: updated}
  end

  defp process_event("content_block_stop", _, acc) do
    block = acc.current
    blocks = if block, do: [block | acc.blocks], else: acc.blocks
    %{acc | blocks: blocks, current: nil}
  end

  defp process_event("message_delta", %{"delta" => delta, "usage" => usage}, acc) do
    %{
      acc
      | stop_reason: delta["stop_reason"],
        usage: usage
    }
  end

  defp process_event("message_stop", _, acc) do
    acc
  end

  defp process_event(_, _, acc), do: acc

  defp build_response_from_acc(acc) do
    blocks = Enum.reverse(acc.blocks)

    response = %{
      "content" => blocks,
      "stop_reason" => acc.stop_reason,
      "usage" => acc.usage
    }

    normalize_response(response)
  end
end
