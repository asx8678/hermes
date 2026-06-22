defmodule Hermes.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Hermes.Providers.OpenAI
  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.ToolCall
  alias Hermes.Providers.Types.Usage

  describe "api_mode/0" do
    test "returns openai_chat" do
      assert OpenAI.api_mode() == "openai_chat"
    end
  end

  describe "convert_messages/2" do
    test "passes messages through unchanged" do
      messages = [
        %{"role" => "system", "content" => "You are a helpful assistant."},
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there"}
      ]

      assert OpenAI.convert_messages(messages) == messages
    end
  end

  describe "convert_tools/1" do
    test "passes OpenAI tools through" do
      tools = [
        %{
          "type" => "function",
          "function" => %{
            "name" => "read_file",
            "description" => "Read a file",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ]

      assert OpenAI.convert_tools(tools) == tools
    end

    test "returns empty list for nil" do
      assert OpenAI.convert_tools(nil) == []
    end

    test "rejects empty names and deduplicates by name" do
      tools = [
        %{"type" => "function", "function" => %{"name" => "a", "parameters" => %{}}},
        %{"type" => "function", "function" => %{"name" => "a", "parameters" => %{}}},
        %{"type" => "function", "function" => %{"name" => "", "parameters" => %{}}}
      ]

      assert [%{"function" => %{"name" => "a"}}] = OpenAI.convert_tools(tools)
    end
  end

  describe "build_kwargs/4" do
    test "builds correct kwargs with defaults" do
      kwargs = OpenAI.build_kwargs("kimi", [%{"role" => "user", "content" => "hi"}], nil)

      assert kwargs.model == "kimi"
      assert kwargs.messages == [%{"role" => "user", "content" => "hi"}]
      assert kwargs.max_completion_tokens == 16_384
      refute Map.has_key?(kwargs, :tools)
      refute Map.has_key?(kwargs, :tool_choice)
    end

    test "respects max_tokens param and emits max_completion_tokens" do
      kwargs = OpenAI.build_kwargs("kimi", [], nil, max_tokens: 512)
      assert kwargs.max_completion_tokens == 512
    end

    test "includes tools and tool_choice when present" do
      tools = [%{"type" => "function", "function" => %{"name" => "x", "parameters" => %{}}}]
      kwargs = OpenAI.build_kwargs("kimi", [], tools, tool_choice: "auto")

      assert length(kwargs.tools) == 1
      assert kwargs.tool_choice == "auto"
    end
  end

  describe "normalize_response/2" do
    test "text-only response returns content and stop finish reason" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => "Hello"}, "finish_reason" => "stop"}
        ]
      }

      assert %NormalizedResponse{} = nr = OpenAI.normalize_response(response)
      assert nr.content == "Hello"
      assert nr.tool_calls == nil
      assert nr.finish_reason == "stop"
    end

    test "tool_calls response returns tool_calls with JSON-string arguments" do
      response = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => ~s({"path":"/etc/hosts"})}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      assert %NormalizedResponse{} = nr = OpenAI.normalize_response(response)
      assert nr.content == nil
      assert [%ToolCall{} = tc] = nr.tool_calls
      assert tc.id == "call_1"
      assert tc.name == "read_file"
      assert Jason.decode!(tc.arguments) == %{"path" => "/etc/hosts"}
      assert nr.finish_reason == "tool_calls"
    end

    test "reasoning_content populates reasoning" do
      response = %{
        "choices" => [
          %{
            "message" => %{"content" => "Answer", "reasoning_content" => "thinking..."},
            "finish_reason" => "stop"
          }
        ]
      }

      assert %NormalizedResponse{} = nr = OpenAI.normalize_response(response)
      assert nr.content == "Answer"
      assert nr.reasoning == "thinking..."
    end

    test "populates usage including cached tokens" do
      response = %{
        "choices" => [%{"message" => %{"content" => "Hi"}, "finish_reason" => "stop"}],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "prompt_tokens_details" => %{"cached_tokens" => 3}
        }
      }

      assert %NormalizedResponse{usage: %Usage{} = usage} = OpenAI.normalize_response(response)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.cached_tokens == 3
    end
  end

  describe "validate_response/1" do
    test "nil returns false" do
      refute OpenAI.validate_response(nil)
    end

    test "empty choices returns false" do
      refute OpenAI.validate_response(%{"choices" => []})
    end

    test "non-empty choices returns true" do
      assert OpenAI.validate_response(%{"choices" => [%{"message" => %{}}]})
    end
  end

  describe "map_finish_reason/1" do
    test "maps OpenAI finish reasons" do
      assert OpenAI.map_finish_reason("stop") == "stop"
      assert OpenAI.map_finish_reason("length") == "length"
      assert OpenAI.map_finish_reason("tool_calls") == "tool_calls"
      assert OpenAI.map_finish_reason("function_call") == "tool_calls"
      assert OpenAI.map_finish_reason("content_filter") == "content_filter"
    end

    test "nil and unknown default to stop" do
      assert OpenAI.map_finish_reason(nil) == "stop"
      assert OpenAI.map_finish_reason("weird") == "stop"
    end
  end

  describe "accumulate/1 (SSE streaming)" do
    test "accumulates text deltas across chunks" do
      chunks = [
        ~s(data: {"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}\n\n),
        ~s(data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}]}\n\n),
        ~s(data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}\n\n),
        "data: [DONE]\n\n"
      ]

      nr = OpenAI.accumulate(chunks)
      assert nr.content == "Hello"
      assert nr.finish_reason == "stop"
      assert nr.usage.input_tokens == 4
      assert nr.usage.output_tokens == 2
    end

    test "concatenates tool_call argument fragments split across chunks and indices" do
      chunks = [
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"foo","arguments":"{\\"x\\":"}}]}}]}\n\n),
        # split a chunk mid-JSON-line to exercise the line buffer
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"fun),
        ~s(ction":{"arguments":"1}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"bar","arguments":"{}"}}]}}]}\n\n),
        ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n),
        "data: [DONE]\n\n"
      ]

      nr = OpenAI.accumulate(chunks)
      assert nr.finish_reason == "tool_calls"
      assert [%ToolCall{} = a, %ToolCall{} = b] = nr.tool_calls

      assert a.id == "call_a"
      assert a.name == "foo"
      assert Jason.decode!(a.arguments) == %{"x" => 1}

      assert b.id == "call_b"
      assert b.name == "bar"
      assert Jason.decode!(b.arguments) == %{}
    end

    test "accumulates reasoning_content" do
      chunks = [
        ~s(data: {"choices":[{"index":0,"delta":{"reasoning_content":"think "}}]}\n\n),
        ~s(data: {"choices":[{"index":0,"delta":{"reasoning_content":"more"},"finish_reason":"stop"}]}\n\n),
        "data: [DONE]\n\n"
      ]

      nr = OpenAI.accumulate(chunks)
      assert nr.reasoning == "think more"
    end
  end
end
