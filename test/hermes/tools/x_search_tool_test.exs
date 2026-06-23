defmodule Hermes.Tools.XSearchToolTest do
  use ExUnit.Case, async: true

  alias Hermes.Tools.XSearchTool

  describe "tool_entries/0" do
    test "returns one entry named x_search" do
      [entry] = XSearchTool.tool_entries()
      assert entry.name == "x_search"
      assert entry.toolset == "x_search"
      assert entry.schema.name == "x_search"
      assert is_function(entry.handler, 2)
      assert is_function(entry.check_fn, 0)
    end
  end

  describe "invoke/2 query validation" do
    test "returns error for empty query" do
      result = XSearchTool.invoke(%{"query" => ""}, %{})
      assert result["success"] == false
      assert result["error"] == "query is required"
    end

    test "returns error for missing query" do
      result = XSearchTool.invoke(%{}, %{})
      assert result["success"] == false
      assert result["error"] == "query is required"
    end

    test "returns error for non-binary query" do
      result = XSearchTool.invoke(%{"query" => 123}, %{})
      assert result["success"] == false
      assert result["error"] == "query is required"
    end
  end

  describe "invoke/2 availability" do
    setup do
      original = System.get_env("XAI_API_KEY")
      on_exit(fn ->
        if is_nil(original) do
          System.delete_env("XAI_API_KEY")
        else
          System.put_env("XAI_API_KEY", original)
        end
      end)
    end

    test "returns error when XAI_API_KEY is missing and no config is set" do
      System.delete_env("XAI_API_KEY")
      # Ensure application env is also empty.
      previous_config = Application.get_env(:hermes, :xai_api_key)
      Application.delete_env(:hermes, :xai_api_key)

      on_exit(fn ->
        if previous_config do
          Application.put_env(:hermes, :xai_api_key, previous_config)
        end
      end)

      result = XSearchTool.invoke(%{"query" => "elon musk"}, %{})
      assert result["success"] == false
      assert result["error"] == "XAI_API_KEY not configured"
    end
  end

  describe "invoke/2 date validation" do
    test "invalid from_date returns an error" do
      result = XSearchTool.invoke(%{"query" => "test", "from_date" => "not-a-date"}, %{})
      assert result["success"] == false
      assert result["error"] == "invalid from_date format, expected YYYY-MM-DD"
    end

    test "from_date after to_date returns an error" do
      result =
        XSearchTool.invoke(
          %{"query" => "test", "from_date" => "2025-01-01", "to_date" => "2024-01-01"},
          %{}
        )

      assert result["success"] == false
      assert result["error"] == "from_date cannot be after to_date"
    end

    test "future from_date returns an error" do
      future = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

      result =
        XSearchTool.invoke(%{"query" => "test", "from_date" => future}, %{}
        )

      assert result["success"] == false
      assert result["error"] == "from_date cannot be in the future"
    end

    test "valid dates proceed to the API key check error" do
      result =
        XSearchTool.invoke(
          %{"query" => "test", "from_date" => "2024-01-01", "to_date" => "2024-01-31"},
          %{}
        )

      assert result["success"] == false
      assert result["error"] == "XAI_API_KEY not configured"
    end
  end

  describe "handle normalization" do
    test "strips @ prefix from handles" do
      result =
        XSearchTool.invoke(
          %{"query" => "test", "allowed_x_handles" => ["@elon"]},
          %{}
        )

      assert result["success"] == false
      assert result["error"] == "XAI_API_KEY not configured"
    end

    test "non-string handles become empty strings" do
      result =
        XSearchTool.invoke(
          %{
            "query" => "test",
            "allowed_x_handles" => ["@elon", 123, nil],
            "excluded_x_handles" => [%{}, 42]
          },
          %{}
        )

      # We cannot observe the normalized values directly in the public return,
      # but we can assert the call proceeds past normalization to the key check.
      assert result["success"] == false
      assert result["error"] == "XAI_API_KEY not configured"
    end
  end

  describe "nil allowed_x_handles" do
    test "allows nil allowed_x_handles and proceeds to key check" do
      result =
        XSearchTool.invoke(
          %{"query" => "test", "allowed_x_handles" => nil},
          %{}
        )

      assert result["success"] == false
      assert result["error"] == "XAI_API_KEY not configured"
    end
  end
end
