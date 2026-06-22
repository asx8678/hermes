defmodule Hermes.Tools.DispatcherTest do
  @moduledoc """
  Tests for the tool registry, dispatcher, and irreducible-6 core tools.

  Covers the contract from `agent/agent_runtime_helpers.py:1733` and
  the core tool families in `02-core-tools.md`.
  """

  use Hermes.DataCase, async: false

  alias Hermes.Repo
  alias Hermes.Sessions.Message
  alias Hermes.Sessions.Session
  alias Hermes.Tools.Dispatcher
  alias Hermes.Tools.Registry

  setup do
    # Each test gets its own tool registry instance.
    Registry.start_link()
    :ok
  end

  describe "Registry" do
    test "register/get_entry round-trip" do
      :ok =
        Registry.register(
          "echo",
          "test",
          %{
            name: "echo",
            description: "Echo test tool",
            parameters: %{type: "object", properties: %{}, required: []}
          },
          fn args, _ctx -> %{"echo" => args["message"]} end
        )

      entry = Registry.get_entry("echo")
      assert entry.name == "echo"
      assert entry.toolset == "test"
    end

    test "list_schemas returns OpenAI function envelopes" do
      Registry.register(
        "echo",
        "test",
        %{name: "echo", description: "Echo", parameters: %{}},
        fn args, _ctx -> args end
      )

      schemas = Registry.list_schemas(["echo"])
      assert [%{type: "function", function: %{name: "echo"}}] = schemas
    end

    test "valid_tool_names includes built-ins after first use" do
      names = Registry.valid_tool_names()
      assert MapSet.member?(names, "read_file")
      assert MapSet.member?(names, "terminal")
      assert MapSet.member?(names, "memory")
      assert MapSet.member?(names, "delegate_task")
    end
  end

  describe "Dispatcher" do
    test "dispatches a registered custom tool" do
      Registry.register(
        "double",
        "math",
        %{name: "double", description: "Double", parameters: %{}},
        fn args, _ctx -> %{"result" => args["n"] * 2} end
      )

      result = Dispatcher.invoke("double", %{"n" => 21}, default_context())
      assert Jason.decode!(result) == %{"result" => 42}
    end

    test "returns error for unknown tool" do
      result = Dispatcher.invoke("no_such_tool", %{}, default_context())
      decoded = Jason.decode!(result)
      assert decoded["error"] =~ "unknown tool"
    end

    test "coerces invalid args to an empty map" do
      result = Dispatcher.invoke("read_file", "not-a-map", default_context())
      decoded = Jason.decode!(result)
      assert decoded["success"] == false
    end
  end

  describe "FileTools" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hermes_file_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "read/write/patch/search round-trip", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "round_trip.txt")

      # write_file
      write_result =
        Dispatcher.invoke(
          "write_file",
          %{"path" => file, "content" => "hello world\nsecond line\n"},
          default_context()
        )

      assert Jason.decode!(write_result)["success"] == true

      # read_file
      read_result = Dispatcher.invoke("read_file", %{"path" => file}, default_context())
      decoded = Jason.decode!(read_result)
      assert decoded["content"] =~ "1|hello world"
      assert decoded["total_lines"] == 3

      # patch
      patch_result =
        Dispatcher.invoke(
          "patch",
          %{"path" => file, "old_string" => "world", "new_string" => "hermes"},
          default_context()
        )

      assert Jason.decode!(patch_result)["success"] == true

      # search_files content
      search_result =
        Dispatcher.invoke(
          "search_files",
          %{"pattern" => "hermes", "path" => tmp_dir},
          default_context()
        )

      decoded = Jason.decode!(search_result)
      assert [match] = decoded["matches"]
      assert match["path"] == Path.expand(file)
      assert match["content"] =~ "hermes"

      # search_files files
      files_result =
        Dispatcher.invoke(
          "search_files",
          %{"pattern" => "round_trip", "target" => "files", "path" => tmp_dir},
          default_context()
        )

      decoded = Jason.decode!(files_result)
      assert [path] = decoded["matches"]
      assert Path.basename(path) == "round_trip.txt"
    end

    test "rejects paths with traversal", %{tmp_dir: tmp_dir} do
      file = Path.join([tmp_dir, "..", "escape.txt"])

      result =
        Dispatcher.invoke(
          "read_file",
          %{"path" => file},
          default_context()
        )

      decoded = Jason.decode!(result)
      assert decoded["success"] == false
      assert decoded["error"] =~ "traversal"
    end
  end

  describe "TerminalTool" do
    test "echo hello returns stdout containing hello" do
      result = Dispatcher.invoke("terminal", %{"command" => "echo hello"}, default_context())
      decoded = Jason.decode!(result)
      assert decoded["exit_code"] == 0
      assert decoded["stdout"] =~ "hello"
    end

    test "returns error when command is missing" do
      result = Dispatcher.invoke("terminal", %{}, default_context())
      decoded = Jason.decode!(result)
      assert decoded["success"] == false
    end
  end

  describe "CodeExecutionTool" do
    test "executes elixir code" do
      result =
        Dispatcher.invoke(
          "execute_code",
          %{"code" => "IO.puts(1 + 2)", "language" => "elixir"},
          default_context()
        )

      decoded = Jason.decode!(result)
      assert decoded["exit_code"] == 0
      assert decoded["stdout"] =~ "3"
    end
  end

  describe "SkillTools" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hermes_skills_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      previous = Application.get_env(:hermes, :skills_dir)
      Application.put_env(:hermes, :skills_dir, tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)

        if previous do
          Application.put_env(:hermes, :skills_dir, previous)
        else
          Application.delete_env(:hermes, :skills_dir)
        end
      end)

      :ok
    end

    test "create, list, view a skill" do
      content = "# Test Skill\n\nA test skill for unit tests.\n"

      create_result =
        Dispatcher.invoke(
          "skill_manage",
          %{"action" => "create", "name" => "test-skill", "content" => content},
          default_context()
        )

      assert Jason.decode!(create_result)["success"] == true

      list_result = Dispatcher.invoke("skills_list", %{}, default_context())
      decoded = Jason.decode!(list_result)
      assert decoded["count"] == 1
      assert Enum.any?(decoded["skills"], &(&1["name"] == "test-skill"))

      view_result =
        Dispatcher.invoke("skill_view", %{"name" => "test-skill"}, default_context())

      decoded = Jason.decode!(view_result)
      assert decoded["success"] == true
      assert decoded["content"] == content
    end
  end

  describe "MemoryTool" do
    test "add, get, replace, delete memory entries" do
      # add
      add_result =
        Dispatcher.invoke(
          "memory",
          %{"action" => "add", "target" => "notes", "content" => "user likes dark mode"},
          default_context()
        )

      assert Jason.decode!(add_result)["success"] == true

      # get
      get_result =
        Dispatcher.invoke(
          "memory",
          %{"action" => "get", "target" => "notes", "content" => "dark mode"},
          default_context()
        )

      decoded = Jason.decode!(get_result)
      assert decoded["count"] == 1
      assert hd(decoded["entries"])["value"] == "user likes dark mode"

      # replace
      replace_result =
        Dispatcher.invoke(
          "memory",
          %{
            "action" => "replace",
            "target" => "notes",
            "old_text" => "dark mode",
            "content" => "light mode"
          },
          default_context()
        )

      assert Jason.decode!(replace_result)["success"] == true

      # delete
      delete_result =
        Dispatcher.invoke(
          "memory",
          %{"action" => "delete", "target" => "notes", "old_text" => "light mode"},
          default_context()
        )

      assert Jason.decode!(delete_result)["success"] == true
      assert Jason.decode!(delete_result)["deleted"] == 1
    end
  end

  describe "DelegateTool" do
    test "spawns a child session" do
      result =
        Dispatcher.invoke(
          "delegate_task",
          %{"goal" => "subtask", "context" => "some context"},
          default_context()
        )

      decoded = Jason.decode!(result)
      assert decoded["success"] == true
      assert is_binary(decoded["session_id"])
      assert decoded["status"] == "spawned"
    end
  end

  describe "session_search tool" do
    test "browse mode returns a successful result" do
      result = Dispatcher.invoke("session_search", %{}, default_context())
      decoded = Jason.decode!(result)
      assert decoded["success"] == true
      assert decoded["mode"] == "browse"
    end

    test "discovery mode searches messages" do
      insert_test_session_and_message()

      result =
        Dispatcher.invoke(
          "session_search",
          %{"query" => "searchable content", "limit" => 3},
          default_context()
        )

      decoded = Jason.decode!(result)
      assert decoded["success"] == true
      assert decoded["mode"] == "discover"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp default_context do
    %{
      session_id: "sess_#{System.unique_integer([:positive])}",
      session_pid: self(),
      finch_name: Hermes.Finch,
      repo: Hermes.Repo
    }
  end

  defp insert_test_session_and_message do
    session_id = "sess_#{System.unique_integer([:positive])}"

    %Session{}
    |> Session.changeset(%{
      id: session_id,
      source: "test",
      started_at: :erlang.system_time(:millisecond) / 1000.0
    })
    |> Repo.insert!()

    %Message{}
    |> Message.changeset(%{
      session_id: session_id,
      role: "user",
      content: "searchable content here",
      timestamp: :erlang.system_time(:millisecond) / 1000.0
    })
    |> Repo.insert!()
  end
end
