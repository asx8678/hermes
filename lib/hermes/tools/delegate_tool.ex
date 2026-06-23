defmodule Hermes.Tools.DelegateTool do
  @moduledoc """
  Delegation tool: spawns a child session via `Hermes.Sessions`.

  Minimal port of `tools/delegate_tool.py:3160`. The child session is a
  supervised `Hermes.Sessions.SessionServer` process, preserving the
  per-session fault-isolation architecture.
  """

  @default_model "moonshotai/Kimi-K2.7-Code"
  @default_provider :openai

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "delegate_task",
        toolset: "delegation",
        schema: delegate_task_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Spawns a child session and returns a JSON-encodable result.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, context) do
    goal = Map.get(args, "goal", "")

    if not is_binary(goal) or String.trim(goal) == "" do
      %{"success" => false, "error" => "goal is required"}
    else
      parent_session_id = Map.get(context, :session_id)

      opts = [
        model: Map.get(args, "model", @default_model),
        provider: normalize_provider(Map.get(args, "provider", "anthropic")),
        system_prompt: Map.get(args, "context", ""),
        parent_session_id: parent_session_id,
        base_url: Map.get(context, :base_url),
        api_key: Map.get(context, :api_key),
        context_window: Map.get(context, :context_window)
      ]

      opts = Keyword.reject(opts, fn {_k, v} -> is_nil(v) end)

      case Hermes.Sessions.start_session(opts) do
        {:ok, pid, session_id} ->
          %{
            "success" => true,
            "session_id" => session_id,
            "parent_session_id" => parent_session_id,
            "status" => "spawned",
            "goal" => goal,
            "pid" => inspect(pid)
          }

        other ->
          %{"success" => false, "error" => "failed to spawn session: #{inspect(other)}"}
      end
    end
  end

  defp normalize_provider(provider) when is_binary(provider) do
    try do
      String.to_existing_atom(provider)
    rescue
      ArgumentError -> String.to_atom(provider)
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(_), do: @default_provider

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp delegate_task_schema do
    %{
      name: "delegate_task",
      description: "Spawn a child agent session to handle a delegated task.",
      parameters: %{
        type: "object",
        properties: %{
          goal: %{
            type: "string",
            description: "What the child agent should accomplish."
          },
          context: %{
            type: "string",
            description: "Background information for the child agent."
          },
          model: %{
            type: "string",
            description: "Model for the child session.",
            default: @default_model
          },
          provider: %{
            type: "string",
            description:
              "Provider for the child session (e.g. \"anthropic\", \"openai\", \"makora\").",
            default: "anthropic"
          }
        },
        required: ["goal"]
      }
    }
  end
end
