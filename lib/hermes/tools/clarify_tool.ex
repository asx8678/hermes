defmodule Hermes.Tools.ClarifyTool do
  @moduledoc """
  The `clarify` tool — ask the user a question and pause the turn for their
  answer.

  When the agent calls `clarify`, the dispatcher broadcasts a `clarify:request`
  event on the session topic (the channel forwards it to the UI), and the turn
  loop finalizes the current turn so the user's next message answers the
  question. This module exists so `clarify` is a registered, valid tool name;
  the actual behaviour lives in `Hermes.Tools.Dispatcher` (which has the session
  context) and `Hermes.Sessions.TurnLoop` (which pauses the turn).
  """

  @doc false
  def tool_entries do
    [
      %{
        name: "clarify",
        toolset: "planning",
        schema: %{
          "name" => "clarify",
          "description" =>
            "Ask the user a clarifying question when the request is ambiguous. " <>
              "The current turn pauses and the user's next message is the answer.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{
                "type" => "string",
                "description" => "The question to ask the user."
              },
              "choices" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Optional list of suggested answers."
              }
            },
            "required" => ["question"]
          }
        },
        handler: fn _args, _ctx ->
          # Real invocation goes through Dispatcher.dispatch/3 by name; this
          # handler is only a registry fallback and should not normally run.
          %{"status" => "asked"}
        end
      }
    ]
  end
end
