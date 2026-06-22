defmodule Hermes.Tools.TerminalSidecar do
  @moduledoc """
  OS-isolated terminal sidecar manager.

  Owns a long-lived `Port` to the `hermes-sidecar terminal` Rust binary.
  The sidecar runs in a separate OS process, so a crash or runaway shell
  command cannot bring down the BEAM. Requests and responses are correlated
  by an id over newline-delimited JSON-RPC stdio.

  Port of `tools/terminal_tool.py:2738`.
  """

  use GenServer

  require Logger

  @default_timeout 60
  @line_buffer 1_048_576

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a shell command through the terminal sidecar.

  ## Options

    * `:timeout` - maximum seconds to wait for the command (default #{@default_timeout})
    * `:cwd` - working directory for the command
  """
  @spec execute(String.t(), keyword()) :: map()
  def execute(command, opts \\ []) when is_binary(command) do
    ensure_binary()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = Keyword.get(opts, :cwd)

    # Give the sidecar the requested timeout plus a grace period for overhead.
    call_timeout = :timer.seconds(timeout + 10)

    case GenServer.call(__MODULE__, {:execute, command, timeout, cwd}, call_timeout) do
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
  def handle_call({:execute, command, timeout, cwd}, from, state) do
    {port, state} = ensure_port(state)
    id = state.next_id

    request = %{
      id: id,
      method: "execute",
      command: command,
      timeout_secs: timeout,
      cwd: cwd
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
    Logger.warning("terminal sidecar sent oversized line: #{inspect(fragment)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("terminal sidecar exited with status #{status}")
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
    Logger.debug("TerminalSidecar unexpected message: #{inspect(msg)}")
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
      {:args, ["terminal"]},
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
        Logger.warning("terminal sidecar response with unknown id: #{inspect(response)}")
        state

      {:error, reason} ->
        Logger.warning("terminal sidecar sent invalid JSON: #{inspect(reason)}")
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
    Logger.info("terminal sidecar binary not found; building with cargo...")

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
