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

  @doc """
  Returns a list of all active sessions as dashboard-friendly maps.
  """
  @spec list_sessions() :: [
          %{id: String.t(), model: String.t(), status: atom(), message_count: non_neg_integer()}
        ]
  def list_sessions do
    Hermes.Sessions.Registry
    |> Registry.select([
      {{{Hermes.Sessions.SessionServer, :"$1"}, :"$2", :_}, [], [:"$2"]}
    ])
    |> Enum.flat_map(fn pid ->
      case SessionServer.get_state(pid) do
        %{session_id: id, model: model, status: status, messages: messages} ->
          [%{id: id, model: model, status: status, message_count: length(messages)}]

        _ ->
          []
      end
    end)
  end

  @doc """
  Triggers a non-blocking turn for the session identified by `session_id`.

  See `Hermes.Sessions.SessionServer.run_turn_async/2`.
  """
  @spec run_turn_async(String.t(), String.t()) :: :ok | {:error, :not_found}
  def run_turn_async(session_id, message)
      when is_binary(session_id) and is_binary(message) do
    SessionServer.run_turn_async(session_id, message)
  end
end
