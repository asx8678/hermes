defmodule Hermes.Sessions.PromptCaching do
  @moduledoc """
  Anthropic prompt-caching strategy.

  Ported from Python `agent/prompt_caching.py:49-80`.
  Applies the `system_and_3` layout: up to four `cache_control` breakpoints
  — the system prompt plus the last three non-system messages, all with the
  same TTL (`5m` or `1h`).
  """

  @doc """
  Apply Anthropic cache-control breakpoints to a list of API messages.

  Returns a deep-copied list of `api_messages` with `cache_control` markers
  injected. The strategy is `system_and_3`:

    * If the first message is a system message, mark it.
    * Mark up to the remaining budget of breakpoints on the last non-system
      messages (up to 3).

  ## Options

    * `:cache_ttl` — `"5m"` (default) or `"1h"`.
    * `:native_anthropic` — when `true`, tool messages receive the top-level
      `cache_control` marker instead of content-level markers.

  """
  @spec apply_cache_control([map()], keyword()) :: [map()]
  def apply_cache_control(api_messages, opts \\ []) do
    cache_ttl = Keyword.get(opts, :cache_ttl, "5m")
    native_anthropic = Keyword.get(opts, :native_anthropic, false)

    messages = deep_copy(api_messages)

    if messages == [] do
      []
    end

    marker = build_marker(cache_ttl)
    breakpoints_used = 0

    {messages, breakpoints_used} =
      if match?(%{"role" => "system"}, List.first(messages)) do
        messages = List.update_at(messages, 0, &apply_marker(&1, marker, native_anthropic))
        {messages, breakpoints_used + 1}
      else
        {messages, breakpoints_used}
      end

    remaining = 4 - breakpoints_used

    non_system_indices =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _idx} -> msg["role"] != "system" end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    target_indices = Enum.take(non_system_indices, -remaining)

    Enum.reduce(target_indices, messages, fn idx, acc ->
      List.update_at(acc, idx, &apply_marker(&1, marker, native_anthropic))
    end)
  end

  defp build_marker(ttl) do
    marker = %{"type" => "ephemeral"}

    if ttl == "1h" do
      Map.put(marker, "ttl", "1h")
    else
      marker
    end
  end

  defp apply_marker(%{"role" => "tool"} = msg, marker, true) do
    Map.put(msg, "cache_control", marker)
  end

  defp apply_marker(%{"role" => "tool"}, _marker, false) do
    # Tool messages only receive cache markers in native Anthropic layout.
    nil
  end

  defp apply_marker(msg, marker, _native_anthropic) do
    content = msg["content"]

    cond do
      is_nil(content) or content == "" or content == %{} ->
        Map.put(msg, "cache_control", marker)

      is_binary(content) ->
        Map.put(msg, "content", [
          %{"type" => "text", "text" => content, "cache_control" => marker}
        ])

      is_list(content) and content != [] ->
        last = List.last(content)

        if is_map(last) do
          updated_last = Map.put(last, "cache_control", marker)
          Map.put(msg, "content", List.replace_at(content, -1, updated_last))
        else
          msg
        end

      true ->
        msg
    end
  end

  defp deep_copy(messages) when is_list(messages) do
    Enum.map(messages, &deep_copy/1)
  end

  defp deep_copy(%{} = map) do
    map
    |> Map.to_list()
    |> Enum.map(fn {k, v} -> {k, deep_copy(v)} end)
    |> Enum.into(%{})
  end

  defp deep_copy(other), do: other
end
