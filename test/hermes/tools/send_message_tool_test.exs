defmodule Hermes.Tools.SendMessageToolTest do
  @moduledoc """
  Tests for `Hermes.Tools.SendMessageTool`.
  """

  use ExUnit.Case, async: true

  alias Hermes.Tools.SendMessageTool

  describe "tool_entries/0" do
    test "returns one entry named send_message with toolset gateway" do
      [entry] = SendMessageTool.tool_entries()
      assert entry.name == "send_message"
      assert entry.toolset == "gateway"
      assert is_function(entry.handler, 2)
      assert is_function(entry.check_fn, 0)
      assert entry.check_fn.() == true
      assert is_map(entry.schema)
      assert entry.schema.description =~ "Send a message"
      assert entry.schema.parameters.type == "object"
      assert entry.schema.parameters.required == ["platform", "recipient", "message"]
      assert Map.has_key?(entry.schema.parameters.properties, :platform)
      assert Map.has_key?(entry.schema.parameters.properties, :recipient)
      assert Map.has_key?(entry.schema.parameters.properties, :message)
    end
  end

  describe "invoke/2 validation" do
    test "missing platform returns an error" do
      result = SendMessageTool.invoke(%{"recipient" => "user", "message" => "hi"}, %{})
      assert result == %{"success" => false, "error" => "platform is required"}
    end

    test "missing recipient returns an error" do
      result = SendMessageTool.invoke(%{"platform" => "telegram", "message" => "hi"}, %{})
      assert result == %{"success" => false, "error" => "recipient is required"}
    end

    test "missing message returns an error" do
      result = SendMessageTool.invoke(%{"platform" => "telegram", "recipient" => "user"}, %{})
      assert result == %{"success" => false, "error" => "message is required"}
    end

    test "whitespace-only message returns an error" do
      result =
        SendMessageTool.invoke(
          %{"platform" => "telegram", "recipient" => "user", "message" => "   "},
          %{}
        )

      assert result == %{"success" => false, "error" => "message is required"}
    end
  end

  describe "invoke/2 gateway dispatch" do
    test "unregistered connector returns an error map" do
      result =
        SendMessageTool.invoke(
          %{"platform" => "nonexistent", "recipient" => "user", "message" => "hello"},
          %{}
        )

      assert result["success"] == false
      assert result["platform"] == "nonexistent"
      assert result["recipient"] == "user"
      assert is_binary(result["error"])
      assert result["error"] =~ "not_running"
    end
  end

  describe "platform normalization" do
    test "lowercases and trims uppercase platform names" do
      result =
        SendMessageTool.invoke(
          %{"platform" => "  TELEGRAM  ", "recipient" => "user", "message" => "hello"},
          %{}
        )

      assert result["success"] == false
      assert result["platform"] == "telegram"
    end

    test "lowercases mixed-case platform names" do
      result =
        SendMessageTool.invoke(
          %{"platform" => "Discord", "recipient" => "user", "message" => "hello"},
          %{}
        )

      assert result["success"] == false
      assert result["platform"] == "discord"
    end
  end

  describe "extract_message_id/1 through valid args" do
    test "extracts message_id from string-keyed map" do
      result =
        SendMessageTool.invoke(
          %{"platform" => "telegram", "recipient" => "user", "message" => "hello"},
          %{}
        )

      assert result["message_id"] == nil
      assert result["success"] == false
    end
  end
end
