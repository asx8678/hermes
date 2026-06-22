defmodule Hermes.Sessions.SessionServer do
  @moduledoc """
  Per-conversation session GenServer.

  Holds the mutable state for one conversation: messages, model/provider
  configuration, and iteration-budget bookkeeping.

  Each server registers itself in `Hermes.Sessions.Registry` under
  `{Hermes.Sessions.SessionServer, session_id}` so it can be located by
  session id from the Phoenix channel boundary.

  Budget defaults are ported from the Python agent:
  - `agent/iteration_budget.py:17` (`IterationBudget`)
  - `agent/iteration_budget.py:23` (`max_total` default 90)
  """

  use GenServer

  alias Hermes.Sessions.TurnLoop

  @default_model "claude-sonnet-4-20250514"
  @default_provider :anthropic
  @default_api_mode "anthropic_messages"
  @default_max_iterations 90

  defstruct [
    :session_id,
    :model,
    :provider,
    :api_mode,
    :max_iterations,
    :iteration_budget_used,
    :budget_grace_call,
    :status,
    messages: []
  ]

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new_lazy(opts, :session_id, &generate_session_id/0)
    GenServer.start_link(__MODULE__, opts)
  end

  @spec get_state(GenServer.server()) :: map()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @spec add_message(GenServer.server(), map()) :: :ok
  def add_message(pid, message) when is_map(message),
    do: GenServer.cast(pid, {:add_message, message})

  @spec set_status(GenServer.server(), atom()) :: :ok
  def set_status(pid, status) when is_atom(status),
    do: GenServer.cast(pid, {:set_status, status})

  @doc """
  Looks up a session server by its public session id.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(Hermes.Sessions.Registry, {__MODULE__, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Triggers a non-blocking turn for `session_id` using `message` as the user
  prompt.

  The user message is appended to the session history, the session status is
  set to `:running`, and `Hermes.Sessions.TurnLoop.run/1` is executed in an
  unlinked task.  When the turn finishes, the server broadcasts either a
  `turn:complete` or `turn:error` event on the session's PubSub topic.
  """
  @spec run_turn_async(String.t(), String.t()) :: :ok | {:error, :not_found}
  def run_turn_async(session_id, message)
      when is_binary(session_id) and is_binary(message) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:run_turn_async, message})
    end
  end

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    state = %__MODULE__{
      session_id: session_id,
      messages: Keyword.get(opts, :messages, []),
      model: Keyword.get(opts, :model, @default_model),
      provider: Keyword.get(opts, :provider, @default_provider),
      api_mode: Keyword.get(opts, :api_mode, @default_api_mode),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      iteration_budget_used: 0,
      budget_grace_call: false,
      status: :idle
    }

    Process.flag(:trap_exit, true)
    Registry.register(Hermes.Sessions.Registry, {__MODULE__, session_id}, nil)
    broadcast_session_started(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_cast({:add_message, message}, state) do
    {:noreply, %{state | messages: state.messages ++ [message]}}
  end

  @impl true
  def handle_cast({:set_status, status}, state) do
    {:noreply, set_status_and_broadcast(state, status)}
  end

  @impl true
  def handle_cast({:run_turn_async, message}, state) do
    if state.status == :running do
      broadcast_turn_error(state.session_id, %{error: "session busy", partial: true})
      {:noreply, state}
    else
      user_msg = %{role: "user", content: message}
      new_state = %{state | messages: state.messages ++ [user_msg]}
      session_pid = self()

      Task.start(fn -> run_turn_in_task(session_pid, new_state) end)

      {:noreply, set_status_and_broadcast(new_state, :running)}
    end
  end

  @impl true
  def handle_cast({:turn_finished, %{ok: true, result: result}}, state) do
    broadcast_turn_complete(state.session_id, result)

    new_state = %{
      state
      | messages: result.messages,
        iteration_budget_used: state.iteration_budget_used + result.api_calls
    }

    {:noreply, set_status_and_broadcast(new_state, :idle)}
  end

  @impl true
  def handle_cast({:turn_finished, %{ok: false, error: error}}, state) do
    broadcast_turn_error(state.session_id, error)
    {:noreply, set_status_and_broadcast(state, :idle)}
  end

  @impl true
  def terminate(_reason, state) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "sessions",
      {:session_stopped, state.session_id}
    )
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp run_turn_in_task(session_pid, state) do
    opts = [
      session_id: state.session_id,
      messages: state.messages,
      model: state.model,
      provider: provider_module(state.provider),
      api_mode: state.api_mode,
      max_iterations: state.max_iterations,
      session_pid: session_pid
    ]

    case TurnLoop.run(opts) do
      {:ok, result} ->
        Hermes.Curator.BackgroundReview.spawn_review(
          state.session_id,
          result.messages,
          provider: provider_module(state.provider),
          model: state.model,
          api_mode: state.api_mode
        )

        GenServer.cast(session_pid, {:turn_finished, %{ok: true, result: result}})

      {:error, error} ->
        Hermes.Curator.BackgroundReview.spawn_review(
          state.session_id,
          error.messages,
          provider: provider_module(state.provider),
          model: state.model,
          api_mode: state.api_mode
        )

        GenServer.cast(session_pid, {:turn_finished, %{ok: false, error: error}})
    end
  end

  defp provider_module(:anthropic), do: Hermes.Providers.Anthropic
  defp provider_module(mod) when is_atom(mod), do: mod

  defp broadcast_turn_complete(session_id, result) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "session:#{session_id}",
      {:turn_complete,
       %{
         session_id: session_id,
         final_response: result.final_response,
         api_calls: result.api_calls,
         completed: true
       }}
    )
  end

  defp broadcast_turn_error(session_id, %{message: message, partial: partial}) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "session:#{session_id}",
      {:turn_error,
       %{
         session_id: session_id,
         error: message,
         partial: partial
       }}
    )
  end

  defp broadcast_turn_error(session_id, %{error: error, partial: partial}) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "session:#{session_id}",
      {:turn_error,
       %{
         session_id: session_id,
         error: error,
         partial: partial
       }}
    )
  end

  defp set_status_and_broadcast(state, status) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "sessions",
      {:session_status, state.session_id, status}
    )

    %{state | status: status}
  end

  defp broadcast_session_started(state) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "sessions",
      {:session_started,
       %{
         id: state.session_id,
         model: state.model,
         status: state.status,
         message_count: length(state.messages)
       }}
    )
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
