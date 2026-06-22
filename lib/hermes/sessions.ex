defmodule Hermes.Sessions do
  @moduledoc """
  Public API for managing conversation sessions.

  Each session is a supervised `Hermes.Sessions.SessionServer` process, giving
  per-session fault isolation through `Hermes.Sessions.Supervisor`.
  """

  alias Hermes.Sessions.SessionServer
  alias Hermes.Sessions.Supervisor, as: SessionsSupervisor

  @type session_id :: String.t()

  @doc """
  Starts a new session.

  Accepts `model`, `provider`, `api_mode`, `max_iterations`, and `session_id`
  options; any omitted field uses the server defaults.

  Returns `{:ok, pid, session_id}`.
  """
  @spec start_session(keyword()) ::
          {:ok, pid(), session_id()} | DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    SessionsSupervisor.start_session(opts)
  end

  @doc """
  Returns the current state of the session as a map.
  """
  @spec get_session(pid()) :: map()
  def get_session(pid) when is_pid(pid) do
    SessionServer.get_state(pid)
  end

  @doc """
  Stops a running session.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    SessionsSupervisor.stop_session(pid)
  end

  @doc """
  Adds a message to the session's message list.
  """
  @spec add_message(pid(), map()) :: :ok
  def add_message(pid, message) when is_pid(pid) and is_map(message) do
    SessionServer.add_message(pid, message)
  end

  @doc """
  Updates the session status.
  """
  @spec set_status(pid(), atom()) :: :ok
  def set_status(pid, status) when is_pid(pid) and is_atom(status) do
    SessionServer.set_status(pid, status)
  end
end
