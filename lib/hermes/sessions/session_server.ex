defmodule Hermes.Sessions.SessionServer do
  @moduledoc """
  Per-conversation session GenServer.

  Holds the mutable state for one conversation: messages, model/provider
  configuration, and iteration-budget bookkeeping.

  Budget defaults are ported from the Python agent:
  - `agent/iteration_budget.py:17` (`IterationBudget`)
  - `agent/iteration_budget.py:23` (`max_total` default 90)
  """

  use GenServer

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

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      messages: Keyword.get(opts, :messages, []),
      model: Keyword.get(opts, :model, @default_model),
      provider: Keyword.get(opts, :provider, @default_provider),
      api_mode: Keyword.get(opts, :api_mode, @default_api_mode),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      iteration_budget_used: 0,
      budget_grace_call: false,
      status: :idle
    }

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
    {:noreply, %{state | status: status}}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
