defmodule Hermes.Tools.Registry do
  @moduledoc """
  Singleton registry for tool schemas and handlers.

  Ported from the Python source `tools/registry.py:57,234`.

  Tools register themselves as entries of the shape:

      %{
        name: "read_file",
        toolset: "file",
        schema: %{name: ..., description: ..., parameters: ...},
        handler: fn args, context -> ... end,
        check_fn: fn -> true end
      }

  The schema stored in an entry is the *inner* function definition; callers
  such as `list_schemas/1` wrap it in the OpenAI `type: "function"` envelope.
  """

  use Agent

  @name __MODULE__

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts the registry agent.
  """
  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> %{entries: %{}, toolsets: %{}} end, name: @name)
  end

  @doc """
  Ensures the registry is running and the built-in tool set is loaded.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(@name) do
      nil ->
        case start_link() do
          {:ok, _} -> register_builtins()
          {:error, {:already_started, _}} -> register_builtins()
        end

      _pid ->
        register_builtins()
    end
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Registers a tool entry.
  """
  @spec register(String.t(), String.t(), map(), fun(), fun() | nil) :: :ok
  def register(name, toolset, schema, handler, check_fn \\ nil) do
    ensure_started()

    entry = %{
      name: name,
      toolset: toolset,
      schema: schema,
      handler: handler,
      check_fn: check_fn
    }

    Agent.update(@name, fn state ->
      state
      |> put_in([:entries, name], entry)
      |> put_toolset_check(toolset, check_fn)
    end)
  end

  defp put_toolset_check(state, _toolset, nil), do: state

  defp put_toolset_check(state, toolset, check_fn) when is_function(check_fn, 0) do
    put_in(state, [:toolsets, toolset], check_fn)
  end

  @doc """
  Registers the irreducible-6 (and supporting) built-in tools.
  """
  @spec register_builtins() :: :ok
  def register_builtins do
    builtin_modules = [
      Hermes.Tools.FileTools,
      Hermes.Tools.TerminalTool,
      Hermes.Tools.CodeExecutionTool,
      Hermes.Tools.SkillTools,
      Hermes.Tools.MemoryTool,
      Hermes.Tools.DelegateTool,
      Hermes.Tools.TodoTool
    ]

    for mod <- builtin_modules do
      if Code.ensure_loaded?(mod) and function_exported?(mod, :tool_entries, 0) do
        for entry <- mod.tool_entries() do
          _register_from_entry(entry)
        end
      end
    end

    :ok
  end

  defp _register_from_entry(
         %{name: name, toolset: toolset, schema: schema, handler: handler} = entry
       ) do
    check_fn = Map.get(entry, :check_fn)

    Agent.update(@name, fn state ->
      state
      |> put_in([:entries, name], %{
        name: name,
        toolset: toolset,
        schema: schema,
        handler: handler,
        check_fn: check_fn
      })
      |> put_toolset_check(toolset, check_fn)
    end)
  end

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  @doc """
  Returns a registered tool entry by name, or `nil`.
  """
  @spec get_entry(String.t()) :: map() | nil
  def get_entry(name) do
    ensure_started()
    Agent.get(@name, &get_in(&1, [:entries, name]))
  end

  @doc """
  Returns all registered tool entries.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    ensure_started()
    Agent.get(@name, fn %{entries: entries} -> Map.values(entries) end)
  end

  @doc """
  Returns OpenAI function-calling schemas for the requested tool names.
  """
  @spec list_schemas([String.t()]) :: [map()]
  def list_schemas(tool_names) when is_list(tool_names) do
    ensure_started()

    entries =
      Agent.get(@name, fn %{entries: entries} ->
        for name <- tool_names, entry = entries[name], do: entry
      end)

    Enum.map(entries, fn entry ->
      %{
        type: "function",
        function: entry.schema
      }
    end)
  end

  @doc """
  Returns a `MapSet` of all registered tool names.
  """
  @spec valid_tool_names() :: MapSet.t(String.t())
  def valid_tool_names do
    ensure_started()
    Agent.get(@name, fn %{entries: entries} -> Map.keys(entries) |> MapSet.new() end)
  end
end
