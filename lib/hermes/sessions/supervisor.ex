defmodule Hermes.Sessions.Supervisor do
  @moduledoc """
  DynamicSupervisor for conversation session processes.

  Each session runs under its own `Hermes.Sessions.SessionServer` so a crash
  in one session cannot bring down other sessions or the VM.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new session under the supervisor.

  Returns `{:ok, pid, session_id}` on success.
  """
  @spec start_session(keyword()) :: {:ok, pid(), String.t()} | DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    opts = Keyword.put(opts, :session_id, session_id)

    spec = {Hermes.Sessions.SessionServer, opts}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid, session_id}
      other -> other
    end
  end

  @doc """
  Stops a running session by PID.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
