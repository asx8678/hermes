defmodule Hermes.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Hermes.Providers.Anthropic
  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Providers.Types.Usage

  describe "api_mode/0" do
    test "returns anthropic_messages" do
      assert Anthropic.api_mode() == "anthropic_messages"
    end
  end

  describe "convert_messages/2" do
    test "extracts system role and preserves user/assistant messages" do
      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there"}
      ]

      assert {system, rest} = Anthropic.convert_messages(messages)
      assert system == "You are a helpful assistant."

      assert rest == [
               %{"role" => "user", "content" => "Hello"},
               %{"role" => "assistant", "content" => "Hi there"}
             ]
    end

    test "preserves system content blocks with cache_control" do
      messages = [
        %{
          "role" => "system",
          "content" => [
            %{"type" => "text", "text" => "sys", "cache_control" => %{"type" => "ephemeral"}}
          ]
        },
        %{"role" => "user", "content" => "Hello"}
      ]

      assert {system, rest} = Anthropic.convert_messages(messages)

      assert system == [
               %{"type" => "text", "text" => "sys", "cache_control" => %{"type" => "ephemeral"}}
             ]

      assert rest == [%{"role" => "user", "content" => "Hello"}]
    end
  end

  describe "convert_tools/1" do
    test "maps OpenAI parameters to Anthropic input_schema" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}}
            }
          }
        }
      ]

      assert [tool] = Anthropic.convert_tools(tools)
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file"

      assert tool["input_schema"] == %{
               "type" => "object",
               "properties" => %{"path" => %{"type" => "string"}}
             }
    end

    test "returns empty list for nil" do
      assert Anthropic.convert_tools(nil) == []
    end

    test "deduplicates tools by name" do
      tools = [
        %{"type" => "function", "function" => %{"name" => "a", "parameters" => %{}}},
        %{"type" => "function", "function" => %{"name" => "a", "parameters" => %{}}}
      ]

      assert length(Anthropic.convert_tools(tools)) == 1
    end
  end

  describe "build_kwargs/4" do
    test "builds correct kwargs with defaults" do
      kwargs =
        Anthropic.build_kwargs("claude-test", [%{"role" => "user", "content" => "hi"}], nil)

      assert kwargs.model == "claude-test"
      assert kwargs.messages == [%{"role" => "user", "content" => "hi"}]
      assert kwargs.max_tokens == 16_384
      refute Map.has_key?(kwargs, :system)
      refute Map.has_key?(kwargs, :tools)
    end

    test "includes system, tools, tool_choice and reasoning_config" do
      params = [tool_choice: "auto", reasoning_config: %{"type" => "enabled"}]
      tools = [%{"type" => "function", "function" => %{"name" => "x", "parameters" => %{}}}]

      kwargs =
        Anthropic.build_kwargs(
          "claude-test",
          [
            %{"role" => "system", "content" => "sys"},
            %{"role" => "user", "content" => "hi"}
          ],
          tools,
          params
        )

      assert kwargs.system == "sys"
      assert length(kwargs.tools) == 1
      assert kwargs.tool_choice == "auto"
      assert kwargs.reasoning == %{"type" => "enabled"}
    end
  end

  describe "normalize_response/2" do
    test "text-only response returns content and stop finish reason" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "stop_reason" => "end_turn"
      }

      assert %NormalizedResponse{} = nr = Anthropic.normalize_response(response)
      assert nr.content == "Hello"
      assert nr.tool_calls == nil
      assert nr.finish_reason == "stop"
    end

    test "joins multiple text blocks with newlines" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Line 1"},
          %{"type" => "text", "text" => "Line 2"}
        ],
        "stop_reason" => "end_turn"
      }

      assert Anthropic.normalize_response(response).content == "Line 1\nLine 2"
    end

    test "tool_use response returns tool_calls and tool_calls finish reason" do
      response = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "read_file",
            "input" => %{"path" => "/etc/passwd"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      assert %NormalizedResponse{} = nr = Anthropic.normalize_response(response)
      assert nr.content == nil
      assert [%ToolCall{} = tc] = nr.tool_calls
      assert tc.id == "tu_1"
      assert tc.name == "read_file"
      assert Jason.decode!(tc.arguments) == %{"path" => "/etc/passwd"}
      assert nr.finish_reason == "tool_calls"
    end

    test "thinking block populates reasoning" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "I should think about this."},
          %{"type" => "text", "text" => "Answer"}
        ],
        "stop_reason" => "end_turn"
      }

      assert %NormalizedResponse{} = nr = Anthropic.normalize_response(response)
      assert nr.content == "Answer"
      assert nr.reasoning == "I should think about this."
    end

    test "populates usage when present" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Hi"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cache_read_input_tokens" => 3
        }
      }

      assert %NormalizedResponse{usage: %Usage{} = usage} = Anthropic.normalize_response(response)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.cached_tokens == 3
    end
  end

  describe "validate_response/1" do
    test "nil returns false" do
      refute Anthropic.validate_response(nil)
    end

    test "non-list content returns false" do
      refute Anthropic.validate_response(%{"content" => "not a list"})
    end

    test "empty content with end_turn returns true" do
      assert Anthropic.validate_response(%{"content" => [], "stop_reason" => "end_turn"})
    end

    test "empty content with refusal returns true" do
      assert Anthropic.validate_response(%{"content" => [], "stop_reason" => "refusal"})
    end

    test "empty content with other stop reason returns false" do
      refute Anthropic.validate_response(%{"content" => [], "stop_reason" => "tool_use"})
    end

    test "normal response returns true" do
      assert Anthropic.validate_response(%{"content" => [%{"type" => "text", "text" => "x"}]})
    end
  end

  describe "map_finish_reason/1" do
    test "maps all stop reasons" do
      assert Anthropic.map_finish_reason("end_turn") == "stop"
      assert Anthropic.map_finish_reason("tool_use") == "tool_calls"
      assert Anthropic.map_finish_reason("max_tokens") == "length"
      assert Anthropic.map_finish_reason("stop_sequence") == "stop"
      assert Anthropic.map_finish_reason("refusal") == "content_filter"
      assert Anthropic.map_finish_reason("model_context_window_exceeded") == "length"
    end

    test "unknown reason defaults to stop" do
      assert Anthropic.map_finish_reason("unknown") == "stop"
    end
  end
end
