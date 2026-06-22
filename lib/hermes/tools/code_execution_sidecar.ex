defmodule Hermes.Tools.CodeExecutionSidecar do
  @moduledoc """
  OS-isolated code execution sidecar manager.

  Owns a long-lived `Port` to the `hermes-sidecar code-execution` Rust binary.
  Code runs in a separate OS process with timeout and memory limits, so a crash
  or runaway script cannot bring down the BEAM.

  Port of `tools/code_execution_tool.py:1837`.
  """

  use GenServer

  require Logger

  @default_timeout 30
  @line_buffer 1_048_576

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute code through the code-execution sidecar.

  ## Options

    * `:language` - `"python"` or `"elixir"` (default `"elixir"`)
    * `:timeout` - maximum seconds to wait for the script (default #{@default_timeout})
    * `:allowed_tools` - when given, runs with the `hermes_tools` sandbox stubs
  """
  @spec execute(String.t(), keyword()) :: map()
  def execute(code, opts \\ []) when is_binary(code) do
    ensure_binary()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    language = Keyword.get(opts, :language, "elixir")
    allowed_tools = Keyword.get(opts, :allowed_tools)

    # Give the sidecar the requested timeout plus a grace period for overhead.
    call_timeout = :timer.seconds(timeout + 10)

    request =
      if allowed_tools do
        {:execute_with_tools, code, allowed_tools, timeout}
      else
        {:execute, code, language, timeout}
      end

    case GenServer.call(__MODULE__, request, call_timeout) do
      {:ok, result} -> result
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  @doc """
  Return the path to the `hermes-sidecar` binary, building it if necessary.
  """
  @spec ensure_binary() :: String.t()
  def ensure_binary do
    case find_binary() do
      {:ok, path} ->
        path

      :error ->
        build_binary!()

        case find_binary() do
          {:ok, path} -> path
          :error -> raise "hermes-sidecar binary not found after build"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      next_id: 1,
      pending: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, code, language, timeout}, from, state) do
    {port, state} = ensure_port(state)
    id = state.next_id

    request = %{
      id: id,
      method: "execute",
      code: code,
      language: language,
      timeout_secs: timeout,
      memory_limit_mb: 256
    }

    send_message(port, request)

    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | next_id: id + 1, pending: pending}}
  end

  def handle_call({:execute_with_tools, code, allowed_tools, timeout}, from, state) do
    {port, state} = ensure_port(state)
    id = state.next_id

    request = %{
      id: id,
      method: "execute_with_tools",
      code: code,
      allowed_tools: allowed_tools,
      timeout_secs: timeout,
      memory_limit_mb: 256
    }

    send_message(port, request)

    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | next_id: id + 1, pending: pending}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = handle_response(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, fragment}}}, %{port: port} = state) do
    Logger.warning("code execution sidecar sent oversized line: #{inspect(fragment)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("code execution sidecar exited with status #{status}")
    state = fail_pending(state, "sidecar process exited with status #{status}")
    {:noreply, %{state | port: nil}}
  end

  def handle_info({_port, _msg}, state) do
    # Stale message from a previous port; ignore.
    {:noreply, state}
  end

  def handle_info(:ensure_port, state) do
    {_, state} = ensure_port(state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("CodeExecutionSidecar unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp ensure_port(%{port: port} = state) when is_port(port) do
    if Port.info(port) do
      {port, state}
    else
      open_port(%{state | port: nil})
    end
  end

  defp ensure_port(state), do: open_port(state)

  defp open_port(state) do
    path = ensure_binary()
    abs_path = Path.expand(path)

    opts = [
      {:args, ["code-execution"]},
      :binary,
      :exit_status,
      :hide,
      {:line, @line_buffer},
      :use_stdio
    ]

    port = Port.open({:spawn_executable, abs_path}, opts)
    {port, %{state | port: port}}
  end

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    send(port, {self(), {:command, line}})
  end

  defp handle_response(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} when is_map_key(state.pending, id) ->
        {from, pending} = Map.pop!(state.pending, id)
        result = normalize_response(response)
        GenServer.reply(from, {:ok, result})
        %{state | pending: pending}

      {:ok, response} ->
        Logger.warning("code execution sidecar response with unknown id: #{inspect(response)}")
        state

      {:error, reason} ->
        Logger.warning("code execution sidecar sent invalid JSON: #{inspect(reason)}")
        state
    end
  end

  defp normalize_response(%{"method" => "execute_result"} = response) do
    stdout = Map.get(response, "stdout", "")
    stderr = Map.get(response, "stderr", "")
    exit_code = Map.get(response, "exit_code", -1)

    %{
      "success" => exit_code == 0,
      "stdout" => stdout,
      "stderr" => stderr,
      "exit_code" => exit_code
    }
  end

  defp normalize_response(%{"method" => "error", "message" => message}) do
    %{
      "success" => false,
      "stdout" => "",
      "stderr" => "",
      "exit_code" => -1,
      "error" => message
    }
  end

  defp normalize_response(response) do
    %{
      "success" => false,
      "stdout" => "",
      "stderr" => "",
      "exit_code" => -1,
      "error" => "unexpected sidecar response: #{inspect(response)}"
    }
  end

  defp fail_pending(state, reason) do
    pending = state.pending

    for {_id, from} <- pending do
      GenServer.reply(from, {:error, reason})
    end

    %{state | pending: %{}}
  end

  # ---------------------------------------------------------------------------
  # Binary discovery / build
  # ---------------------------------------------------------------------------

  defp find_binary do
    candidates = [
      System.get_env("HERMES_SIDECAR_PATH"),
      System.get_env("CARGO_BIN_EXE_hermes-sidecar"),
      Path.join([File.cwd!(), "host", "target", "debug", "hermes-sidecar"]),
      Path.join([File.cwd!(), "host", "target", "release", "hermes-sidecar"]),
      System.find_executable("hermes-sidecar")
    ]

    Enum.find_value(candidates, :error, fn
      nil -> false
      path -> if File.exists?(path), do: {:ok, path}, else: false
    end)
  end

  defp build_binary! do
    Logger.info("code execution sidecar binary not found; building with cargo...")

    case System.cmd("cargo", ["build", "--bin", "hermes-sidecar"],
           cd: "host",
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, _} ->
        raise "failed to build hermes-sidecar: #{output}"
    end
  end
end
