defmodule Hermes.Sessions.TurnLoop do
  @moduledoc """
  Agentic conversation turn loop.

  Ported from Python `agent/conversation_loop.py:589`.
  The loop drives a single user turn: it repeatedly calls the configured
  provider, dispatches any returned tool calls, and returns the final
  assistant text response along with the updated message history.

  ## Implemented

  - Iteration budget consume / refund / grace-call logic.
  - Tool-name validation and JSON-argument validation.
  - Tool execution through `Hermes.Tools.Dispatcher`.
  - Context compression via `Hermes.Sessions.Compaction` (token-window driven).
  - Live streaming: providers broadcast `{:stream_delta, text}` when `:stream_to`
    is set.
  - Human-in-the-loop: tool approval (`Hermes.Approvals`) and `clarify` (pauses
    the turn for the user's next message).
  - Outer-loop error handling that fills missing tool results and breaks
    near `max_iterations`.
  - API-error classification (`Hermes.Sessions.ErrorClassifier`) with
    retry/backoff and context-compression recovery.
  - Prompt caching via `Hermes.Sessions.PromptCaching` for Anthropic providers.
  - Codex ack continuation loops for `codex_responses` API mode.
  - Thinking-only prefill recovery and empty-response retries.
  - Plugin pre/post LLM hooks via `Hermes.Plugins.LLMHook`.
  """

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Sessions.IterationBudget

  require Logger

  @default_max_iterations 90

  @doc """
  Runs the turn loop.

  ## Options

    * `:session_id` — session identifier (required).
    * `:messages` — initial message list in OpenAI format (default `[]`).
    * `:model` — model name (default `"claude-sonnet-4-20250514"`).
    * `:provider` — provider module (default `Hermes.Providers.Anthropic`).
    * `:api_mode` — provider API mode string (default `"anthropic_messages"`).
    * `:max_iterations` — hard API-call ceiling (default `90`).
    * `:iteration_budget` — `%IterationBudget{}` (default `IterationBudget.new(max_iterations)`).
    * `:budget_grace_call` — one last call when budget is exhausted (default `false`).
    * `:tools` — OpenAI-format tool schemas (default `[]`).
    * `:finch_name` — Finch pool name (default `Hermes.Finch`).
    * `:system_prompt` — optional system prompt injected into API messages.
    * `:session_pid` — pid of the calling session server (used in tool context).

  ## Returns

      {:ok, %{final_response: String.t(), messages: [map()], api_calls: integer(), completed: true}}
      | {:error, %{message: String.t(), messages: [map()], api_calls: integer(), partial: true}}
  """
  @spec run(keyword()) ::
          {:ok,
           %{final_response: String.t(), messages: [map()], api_calls: integer(), completed: true}}
          | {:error,
             %{message: String.t(), messages: [map()], api_calls: integer(), partial: true}}
  def run(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    messages = Keyword.get(opts, :messages, [])
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    provider = Keyword.get(opts, :provider, Hermes.Providers.Anthropic)
    api_mode = Keyword.get(opts, :api_mode, "anthropic_messages")
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    budget = Keyword.get(opts, :iteration_budget, IterationBudget.new(max_iterations))
    budget_grace_call = Keyword.get(opts, :budget_grace_call, false)
    tools = Keyword.get(opts, :tools, [])
    finch_name = Keyword.get(opts, :finch_name, Hermes.Finch)
    system_prompt = Keyword.get(opts, :system_prompt)
    session_pid = Keyword.get(opts, :session_pid, self())

    initial_state = %{
      session_id: session_id,
      model: model,
      provider: provider,
      api_mode: api_mode,
      max_iterations: max_iterations,
      tools: tools,
      finch_name: finch_name,
      system_prompt: system_prompt,
      session_pid: session_pid,
      # Provider connection config (per-provider base_url/api_key from the catalog).
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      # When set, the provider broadcasts incremental {:stream_delta, text} on
      # "session:<id>" so the TUI/LiveView render tokens live.
      stream_to: Keyword.get(opts, :stream_to),
      # Model context window (tokens) used to trigger context compression.
      context_window: Keyword.get(opts, :context_window),
      messages: messages,
      api_call_count: 0,
      budget: budget,
      budget_grace_call: budget_grace_call,
      final_response: nil,
      exit_reason: initial_exit_reason(budget, budget_grace_call),
      error_message: nil,
      # Codex-style intermediate-ack continuation counter.
      codex_ack_continuations: 0,
      # Recovery counters for thinking-only prefill and empty responses.
      thinking_prefill_retries: 0,
      empty_content_retries: 0
    }

    loop(initial_state)
  end

  defp initial_exit_reason(_budget, true), do: nil

  defp initial_exit_reason(budget, _grace) do
    if IterationBudget.remaining(budget) == 0 do
      "budget_exhausted"
    end
  end

  # ---------------------------------------------------------------------------
  # Loop driver
  # ---------------------------------------------------------------------------

  defp loop(
         %{api_call_count: count, max_iterations: max, budget: budget, budget_grace_call: grace} =
           state
       ) do
    # Matches Python `agent/conversation_loop.py:589`.
    can_run = (count < max and IterationBudget.remaining(budget) > 0) or grace

    if can_run do
      state = %{state | api_call_count: count + 1}

      # Budget handling — `agent/conversation_loop.py:605-614`.
      state =
        if state.budget_grace_call do
          %{state | budget_grace_call: false}
        else
          case IterationBudget.consume(state.budget) do
            {:ok, budget} ->
              %{state | budget: budget}

            {:exhausted, _budget} ->
              %{state | exit_reason: "budget_exhausted"}
          end
        end

      if state.exit_reason do
        finalize(state)
      else
        do_turn(state)
      end
    else
      finalize(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Single turn
  # ---------------------------------------------------------------------------

  defp do_turn(state) do
    tool_schemas = if state.tools == [], do: nil, else: state.tools

    # Compress older history if it is about to exceed the model's context window.
    state = Hermes.Sessions.Compaction.maybe_compress(state)

    api_messages = prepare_api_messages(state.messages, state.system_prompt)

    # Apply Anthropic prompt caching — matches `agent/conversation_loop.py:817-822`.
    api_messages =
      if state.provider == Hermes.Providers.Anthropic or state.api_mode == "anthropic_messages" do
        Hermes.Sessions.PromptCaching.apply_cache_control(api_messages,
          cache_ttl: Application.get_env(:hermes, :cache_ttl, "5m"),
          native_anthropic: state.api_mode == "anthropic_messages"
        )
      else
        api_messages
      end

    provider_opts = [
      tools: tool_schemas,
      params: [max_tokens: 16_384],
      base_url: state.base_url,
      api_key: state.api_key,
      stream_to: state.stream_to
    ]

    # Invoke plugin pre_llm_call hooks before the provider call.
    state = run_pre_llm_hooks(state)

    try do
      case state.provider.stream(state.model, api_messages, provider_opts, state.finch_name) do
        {:ok, %NormalizedResponse{} = response} ->
          # Invoke plugin post_llm_call hooks after a successful provider call.
          {state, response} = run_post_llm_hooks(state, response)
          handle_response(state, response)

        {:error, reason} ->
          handle_provider_error(state, reason)
      end
    rescue
      error ->
        message = Exception.message(error)
        handle_outer_error(state, message)
    catch
      kind, reason ->
        message = "#{kind}: #{inspect(reason)}"
        handle_outer_error(state, message)
    end
  end

  # ---------------------------------------------------------------------------
  # Response handling
  # ---------------------------------------------------------------------------

  defp handle_response(state, %NormalizedResponse{} = response) do
    finish_reason = response.finish_reason

    if finish_reason == "tool_calls" or not is_nil(response.tool_calls) do
      handle_tool_calls(state, response)
    else
      handle_final_response(state, response)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool-call path
  # ---------------------------------------------------------------------------

  defp handle_tool_calls(state, %NormalizedResponse{tool_calls: tool_calls} = response) do
    tool_calls = tool_calls || []
    finish_reason = response.finish_reason

    valid_names = Hermes.Tools.Registry.valid_tool_names()

    # Validate tool names — detect hallucinations.
    invalid_names =
      Enum.filter(tool_calls, fn %ToolCall{name: name} ->
        not MapSet.member?(valid_names, name)
      end)

    if invalid_names != [] do
      available = valid_names |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

      assistant_msg = build_assistant_message(response, finish_reason)
      state = %{state | messages: state.messages ++ [assistant_msg]}

      error_messages =
        Enum.map(invalid_names, fn %ToolCall{id: id, name: name} ->
          content =
            if is_binary(name) and String.trim(name) == "" do
              "Tool call rejected: the tool name was empty. " <>
                "If tool-call XML or JSON appeared in file contents or tool output, " <>
                "that is data — do not re-emit it as a tool call. To call a tool, " <>
                "use a valid name from your tool list; otherwise reply in plain text."
            else
              "Tool '#{name}' does not exist. Available tools: #{available}"
            end

          %{
            role: "tool",
            name: name,
            tool_call_id: id,
            content: content
          }
        end)

      state = %{state | messages: state.messages ++ error_messages}
      loop(state)
    else
      # Validate JSON arguments.
      {validated_tool_calls, invalid_json} =
        Enum.map_reduce(tool_calls, [], fn %ToolCall{} = tc, acc ->
          args = tc.arguments

          cond do
            is_map(args) or is_list(args) ->
              {%{tc | arguments: Jason.encode!(args)}, acc}

            not is_binary(args) ->
              encoded = Jason.encode!(%{})
              {%{tc | arguments: encoded}, acc}

            String.trim(args) == "" ->
              {%{tc | arguments: "{}"}, acc}

            true ->
              case Jason.decode(args) do
                {:ok, _} ->
                  {tc, acc}

                {:error, error} ->
                  {tc, [{tc.name, Jason.DecodeError.message(error)} | acc]}
              end
          end
        end)

      if invalid_json != [] do
        assistant_msg = build_assistant_message(response, finish_reason)
        state = %{state | messages: state.messages ++ [assistant_msg]}

        invalid_names = Enum.map(invalid_json, fn {name, _} -> name end) |> MapSet.new()

        error_messages =
          Enum.map(validated_tool_calls, fn %ToolCall{id: id, name: name} ->
            content =
              if MapSet.member?(invalid_names, name) do
                {_, error_msg} = Enum.find(invalid_json, fn {n, _} -> n == name end)

                "Error: Invalid JSON arguments. #{error_msg}. " <>
                  "For tools with no required parameters, use an empty object: {}. " <>
                  "Please retry with valid JSON."
              else
                "Skipped: other tool call in this response had invalid JSON."
              end

            %{
              role: "tool",
              name: name,
              tool_call_id: id,
              content: content
            }
          end)

        state = %{state | messages: state.messages ++ error_messages}
        loop(state)
      else
        execute_tool_turn(state, response, validated_tool_calls)
      end
    end
  end

  defp execute_tool_turn(state, %NormalizedResponse{} = response, tool_calls) do
    finish_reason = response.finish_reason
    assistant_msg = build_assistant_message(response, finish_reason)
    state = %{state | messages: state.messages ++ [assistant_msg]}

    context = %{
      session_id: state.session_id,
      session_pid: state.session_pid,
      finch_name: state.finch_name,
      repo: Hermes.Repo,
      base_url: state.base_url,
      api_key: state.api_key,
      context_window: state.context_window
    }

    tool_results =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name, arguments: args} ->
        decoded_args =
          case Jason.decode(args) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end

        %{
          role: "tool",
          name: name,
          tool_call_id: id,
          content: execute_one_tool(state, name, decoded_args, context)
        }
      end)

    state = %{state | messages: state.messages ++ tool_results}

    # Refund the iteration if the ONLY tool called was execute_code.
    # Matches `agent/conversation_loop.py:4086-4088`.
    called_names = Enum.map(tool_calls, & &1.name) |> MapSet.new()

    state =
      if MapSet.size(called_names) == 1 and MapSet.member?(called_names, "execute_code") do
        %{state | budget: IterationBudget.refund(state.budget)}
      else
        state
      end

    # `clarify` pauses the turn: the agent posed a question to the user and the
    # turn ends so the user's next message becomes the answer.
    if MapSet.member?(called_names, "clarify") do
      finalize(%{state | final_response: clarify_question(tool_calls), exit_reason: "clarify"})
    else
      loop(state)
    end
  end

  # Run a single tool, gating it behind human approval when required. A denied
  # tool returns a structured error instead of executing.
  defp execute_one_tool(state, name, decoded_args, context) do
    if Hermes.Approvals.required?(name) do
      case Hermes.Approvals.request(state.session_id, name, decoded_args) do
        :approved ->
          invoke_tool(name, decoded_args, context)

        :denied ->
          Jason.encode!(%{
            "error" => "Tool '#{name}' was denied by the user.",
            "denied" => true
          })
      end
    else
      invoke_tool(name, decoded_args, context)
    end
  end

  defp invoke_tool(name, decoded_args, context) do
    Hermes.Tools.Dispatcher.invoke(name, decoded_args, context)
  rescue
    error -> "Error executing tool: #{Exception.message(error)}"
  catch
    kind, reason -> "Error executing tool: #{kind}: #{inspect(reason)}"
  end

  defp clarify_question(tool_calls) do
    Enum.find_value(tool_calls, "Could you clarify your request?", fn %ToolCall{
                                                                        name: name,
                                                                        arguments: args
                                                                      } ->
      with "clarify" <- name,
           {:ok, %{"question" => q}} when is_binary(q) <- Jason.decode(args) do
        q
      else
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Final response path
  # ---------------------------------------------------------------------------

  defp handle_final_response(
         state,
         %NormalizedResponse{content: content, reasoning: reasoning} = response
       ) do
    final_response = strip_think_blocks(content || "") |> String.trim()
    has_inline_thinking = has_inline_thinking?(content || "")
    has_structured = not is_nil(reasoning) or has_inline_thinking

    # Codex ack continuation — `agent/conversation_loop.py:4423-4449`.
    if state.api_mode == "codex_responses" and
         state.codex_ack_continuations < 2 and
         not looks_like_tool_call?(response) and
         looks_like_codex_intermediate_ack?(state.messages, final_response) do
      codex_ack_continuation(state, response, final_response)
    else
      # Thinking-only prefill recovery — `agent/conversation_loop.py:4289-4306`.
      if has_structured and final_response == "" and state.thinking_prefill_retries < 2 do
        thinking_prefill_recovery(state, response)
      else
        # Empty response retry — `agent/conversation_loop.py:4324-4335`.
        prefill_exhausted = has_structured and state.thinking_prefill_retries >= 2
        truly_empty = final_response == ""

        if truly_empty and (not has_structured or prefill_exhausted) and
             state.empty_content_retries < 3 do
          empty_content_retry(state)
        else
          # Reset recovery counters on a successful final response.
          state = %{
            state
            | thinking_prefill_retries: 0,
              empty_content_retries: 0,
              codex_ack_continuations: 0
          }

          assistant_msg = %{role: "assistant", content: final_response}
          state = %{state | messages: state.messages ++ [assistant_msg]}

          finalize(%{state | final_response: final_response, exit_reason: "text_response"})
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  defp handle_provider_error(state, reason) do
    classified = Hermes.Sessions.ErrorClassifier.classify(reason)

    Logger.warning(
      "TurnLoop API error: reason=#{classified.reason} retryable=#{classified.retryable} " <>
        "message=#{classified.message}"
    )

    if classified.retryable and state.api_call_count < state.max_iterations - 1 do
      state =
        if classified.should_compress do
          Hermes.Sessions.Compaction.maybe_compress(state)
        else
          state
        end

      Process.sleep(backoff_ms(classified.reason))
      loop(state)
    else
      message = "Error during API call #{state.api_call_count}: #{classified.message}"

      if classified.retryable do
        handle_outer_error(state, message)
      else
        state = fill_missing_tool_results(state, message)
        finalize(%{state | error_message: message, exit_reason: "non_retryable_error"})
      end
    end
  end

  defp handle_outer_error(state, message) do
    Logger.error("TurnLoop error: #{message}")

    state = fill_missing_tool_results(state, message)

    if state.api_call_count >= state.max_iterations - 1 do
      final_response = "I apologize, but I encountered repeated errors: #{message}"

      state = %{
        state
        | messages: state.messages ++ [%{role: "assistant", content: final_response}]
      }

      finalize(%{
        state
        | final_response: final_response,
          exit_reason: "error_near_max_iterations",
          error_message: message
      })
    else
      loop(state)
    end
  end

  # Matches `agent/conversation_loop.py:4497-4522`.
  defp fill_missing_tool_results(state, error_message) do
    case Enum.reverse(state.messages) do
      [] ->
        state

      reversed ->
        {state, _found} =
          Enum.reduce_while(reversed, {state, false}, fn
            %{role: "tool"}, {state, _found} ->
              {:cont, {state, true}}

            %{role: "assistant", tool_calls: tool_calls} = _msg, {state, _found}
            when is_list(tool_calls) ->
              answered_ids =
                state.messages
                |> Enum.filter(&match?(%{role: "tool"}, &1))
                |> Enum.map(& &1.tool_call_id)
                |> MapSet.new()

              new_results =
                Enum.reduce(tool_calls, [], fn tc, acc ->
                  tc_id = tc["id"]

                  if not MapSet.member?(answered_ids, tc_id) do
                    [
                      %{
                        role: "tool",
                        name: tool_call_name(tc),
                        tool_call_id: tc_id,
                        content: "Error executing tool: #{error_message}"
                      }
                      | acc
                    ]
                  else
                    acc
                  end
                end)

              state = %{state | messages: state.messages ++ Enum.reverse(new_results)}
              {:halt, {state, true}}

            _msg, {state, _found} ->
              {:halt, {state, true}}
          end)

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Finalization
  # ---------------------------------------------------------------------------

  defp finalize(%{final_response: final_response, error_message: nil} = state)
       when is_binary(final_response) do
    {:ok,
     %{
       final_response: final_response,
       messages: state.messages,
       api_calls: state.api_call_count,
       completed: true
     }}
  end

  defp finalize(state) do
    message =
      state.error_message ||
        case state.exit_reason do
          "budget_exhausted" ->
            "budget_exhausted: Iteration budget exhausted (#{IterationBudget.used(state.budget)}/#{state.budget.max_total} iterations used)"

          _ ->
            "Conversation stopped before producing a final response"
        end

    {:error,
     %{
       message: message,
       messages: state.messages,
       api_calls: state.api_call_count,
       partial: true
     }}
  end

  # ---------------------------------------------------------------------------
  # Message preparation
  # ---------------------------------------------------------------------------

  defp prepare_api_messages(messages, system_prompt) do
    messages
    |> Enum.map(&prepare_api_message/1)
    |> maybe_prepend_system(system_prompt)
  end

  defp prepare_api_message(message) when is_map(message) do
    message
    |> Map.drop(["reasoning", "finish_reason", "_thinking_prefill"])
  end

  defp maybe_prepend_system(messages, nil), do: messages
  defp maybe_prepend_system(messages, ""), do: messages

  defp maybe_prepend_system(messages, system_prompt) when is_binary(system_prompt) do
    [%{"role" => "system", "content" => system_prompt} | messages]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_assistant_message(
         %NormalizedResponse{content: content, tool_calls: tool_calls},
         finish_reason
       ) do
    openai_tool_calls =
      Enum.map(tool_calls || [], fn %ToolCall{id: id, name: name, arguments: arguments} ->
        %{
          "id" => id || Ecto.UUID.generate(),
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => arguments
          }
        }
      end)

    msg = %{
      role: "assistant",
      content: content || "",
      finish_reason: finish_reason
    }

    if openai_tool_calls != [] do
      Map.put(msg, :tool_calls, openai_tool_calls)
    else
      msg
    end
  end

  defp tool_call_name(%{"function" => %{"name" => name}}), do: name
  defp tool_call_name(%{function: %{name: name}}), do: name
  defp tool_call_name(_), do: nil

  defp strip_think_blocks(content) when is_binary(content) do
    content
    |> String.replace(~r/<thinking>.*?<\/thinking>/s, "")
    |> String.replace(~r/<reasoning>.*?<\/reasoning>/s, "")
  end

  # Detect in-content <thinking> blocks used by some local models.
  defp has_inline_thinking?(content) do
    Regex.match?(~r/<thinking>.*?<\/thinking>/s, content) or
      Regex.match?(~r/<reasoning>.*?<\/reasoning>/s, content)
  end

  defp looks_like_tool_call?(%NormalizedResponse{
         tool_calls: tool_calls,
         finish_reason: finish_reason
       }) do
    finish_reason == "tool_calls" or not is_nil(tool_calls)
  end

  # Codex-style intermediate-ack detection, ported from
  # `agent/agent_runtime_helpers.py:2126-2195`.
  defp looks_like_codex_intermediate_ack?(messages, assistant_content) do
    has_tool_message? = Enum.any?(messages, &match?(%{role: "tool"}, &1))

    if has_tool_message? do
      false
    else
      assistant_text =
        assistant_content
        |> strip_think_blocks()
        |> String.trim()
        |> String.downcase()

      if assistant_text == "" or String.length(assistant_text) > 1200 do
        false
      else
        has_future_ack =
          Regex.match?(
            ~r/\b(i['']ll|i will|let me|i can do that|i can help with that)\b/,
            assistant_text
          )

        if not has_future_ack do
          false
        else
          action_markers = [
            "look into",
            "look at",
            "inspect",
            "scan",
            "check",
            "analyz",
            "review",
            "explore",
            "read",
            "open",
            "run",
            "test",
            "fix",
            "debug",
            "search",
            "find",
            "walkthrough",
            "report back",
            "summarize"
          ]

          workspace_markers = [
            "directory",
            "current directory",
            "current dir",
            "cwd",
            "repo",
            "repository",
            "codebase",
            "project",
            "folder",
            "filesystem",
            "file tree",
            "files",
            "path"
          ]

          user_message = find_last_user_message(messages) || ""
          user_text = user_message |> String.trim() |> String.downcase()

          user_targets_workspace =
            Enum.any?(workspace_markers, fn marker -> marker in user_text end) or
              String.contains?(user_text, "~/") or
              String.contains?(user_text, "/")

          assistant_mentions_action =
            Enum.any?(action_markers, fn marker -> marker in assistant_text end)

          assistant_targets_workspace =
            Enum.any?(workspace_markers, fn marker -> marker in assistant_text end)

          (user_targets_workspace or assistant_targets_workspace) and
            assistant_mentions_action
        end
      end
    end
  end

  defp find_last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      %{role: "user", content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp codex_ack_continuation(state, response, _final_response) do
    state = %{state | codex_ack_continuations: state.codex_ack_continuations + 1}

    interim_msg = build_assistant_message(response, "incomplete")
    interim_msg = Map.put(interim_msg, "_thinking_prefill", true)

    continue_msg = %{
      role: "user",
      content:
        "[System: Continue now. Execute the required tool calls and only " <>
          "send your final answer after completing the task.]"
    }

    state = %{state | messages: state.messages ++ [interim_msg, continue_msg]}
    loop(state)
  end

  defp thinking_prefill_recovery(state, response) do
    state = %{state | thinking_prefill_retries: state.thinking_prefill_retries + 1}

    Logger.info(
      "Thinking-only response (no visible content) — prefilling to continue " <>
        "(#{state.thinking_prefill_retries}/2)"
    )

    interim_msg = build_assistant_message(response, "incomplete")
    interim_msg = Map.put(interim_msg, "_thinking_prefill", true)
    state = %{state | messages: state.messages ++ [interim_msg]}
    loop(state)
  end

  defp empty_content_retry(state) do
    state = %{state | empty_content_retries: state.empty_content_retries + 1}

    Logger.warning(
      "Empty response (no content or reasoning) — retry #{state.empty_content_retries}/3"
    )

    loop(state)
  end

  # ---------------------------------------------------------------------------
  # Plugin hooks
  # ---------------------------------------------------------------------------

  defp run_pre_llm_hooks(state) do
    hooks = Application.get_env(:hermes, :llm_hooks, [])

    Enum.reduce(hooks, state, fn hook, acc ->
      if Code.ensure_loaded?(hook) and function_exported?(hook, :pre_llm_call, 1) do
        hook.pre_llm_call(acc)
      else
        acc
      end
    end)
  end

  defp run_post_llm_hooks(state, response) do
    hooks = Application.get_env(:hermes, :llm_hooks, [])

    Enum.reduce(hooks, {state, response}, fn hook, {acc_state, acc_response} ->
      if Code.ensure_loaded?(hook) and function_exported?(hook, :post_llm_call, 2) do
        hook.post_llm_call(acc_state, acc_response)
      else
        {acc_state, acc_response}
      end
    end)
  end

  # Backoff duration (ms) keyed by classified error reason.
  defp backoff_ms(:rate_limit), do: 1_000
  defp backoff_ms(:overloaded), do: 500
  defp backoff_ms(:server_error), do: 100
  defp backoff_ms(:timeout), do: 100
  defp backoff_ms(:context_overflow), do: 100
  defp backoff_ms(:unknown), do: 100
  defp backoff_ms(_reason), do: 100
end
