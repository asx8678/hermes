defmodule Hermes.Tools.SendMessageTool do
  @moduledoc """
  Cross-platform message sending tool.

  Port of `tools/send_message_tool.py`. Delegates delivery to the active
  gateway connector via `Hermes.Gateway.send_message/3`.
  """

  alias Hermes.Gateway

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "send_message",
        toolset: "gateway",
        schema: send_message_schema(),
        handler: &invoke/2,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Sends a message through a gateway connector.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    platform = Map.get(args, "platform") |> normalize_platform()
    recipient = Map.get(args, "recipient", "")
    message = Map.get(args, "message", "")

    cond do
      is_nil(platform) or platform == "" ->
        %{"success" => false, "error" => "platform is required"}

      not is_binary(recipient) or String.trim(recipient) == "" ->
        %{"success" => false, "error" => "recipient is required"}

      not is_binary(message) or String.trim(message) == "" ->
        %{"success" => false, "error" => "message is required"}

      true ->
        connector = String.to_atom(platform)

        case Gateway.send_message(connector, recipient, message, []) do
          {:ok, result} ->
            %{
              "success" => true,
              "platform" => platform,
              "recipient" => recipient,
              "message_id" => extract_message_id(result),
              "result" => result
            }

          {:error, reason} ->
            %{
              "success" => false,
              "platform" => platform,
              "recipient" => recipient,
              "error" => format_error(reason)
            }
        end
    end
  end

  defp normalize_platform(platform) when is_binary(platform) do
    platform |> String.downcase() |> String.trim()
  end

  defp normalize_platform(_), do: nil

  defp extract_message_id(%{message_id: id}), do: id
  defp extract_message_id(%{"message_id" => id}), do: id
  defp extract_message_id(%{id: id}), do: id
  defp extract_message_id(_), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp always_available, do: true

  defp send_message_schema do
    %{
      name: "send_message",
      description: "Send a message to a recipient via a gateway platform.",
      parameters: %{
        type: "object",
        properties: %{
          platform: %{
            type: "string",
            description: "Platform/connector name (e.g. telegram, discord, slack, email)."
          },
          recipient: %{
            type: "string",
            description: "Recipient identifier (chat id, phone number, email address, etc.)."
          },
          message: %{
            type: "string",
            description: "Plain text message to send."
          }
        },
        required: ["platform", "recipient", "message"]
      }
    }
  end
end
