require Logger

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

  alias Hermes.Catalog
  alias Hermes.Curator.BackgroundReview
  alias Hermes.Sessions.Store
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
    :source,
    :base_url,
    :api_key,
    :context_window,
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
  Updates the session's model and/or provider live (used by the `/model` and
  `/providers` managers). Accepts a map with optional `:model` and `:provider`
  keys. Returns the new effective `%{model, provider}`.
  """
  @spec set_config(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def set_config(session_id, params) when is_binary(session_id) and is_map(params) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:set_config, params})
    end
  end

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
  Forces a context-compaction pass on the session now (the `/compact` command).
  Returns `{:ok, %{before, after}}` message counts.
  """
  @spec compact(String.t()) :: {:ok, map()} | {:error, :not_found}
  def compact(session_id) when is_binary(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :compact)
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
    provider = normalize_provider(Keyword.get(opts, :provider))

    model =
      Keyword.get(opts, :model) || Catalog.default_model(to_string(provider)) || @default_model

    source = Keyword.get(opts, :source, "tui")
    messages = Keyword.get(opts, :messages, [])

    state = %__MODULE__{
      session_id: session_id,
      messages: messages,
      model: model,
      provider: provider,
      api_mode: Keyword.get(opts, :api_mode) || api_mode_for(provider),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      iteration_budget_used: 0,
      budget_grace_call: false,
      status: :idle,
      source: source,
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      context_window: Keyword.get(opts, :context_window)
    }

    Process.flag(:trap_exit, true)
    Registry.register(Hermes.Sessions.Registry, {__MODULE__, session_id}, nil)

    case Store.create_session(session_id,
           source: source,
           model: model,
           parent_session_id: Keyword.get(opts, :parent_session_id)
         ) do
      {:error, reason} -> Logger.warning("SessionServer create_session failed: #{reason}")
      :ok -> :ok
    end

    case Store.persist_messages(session_id, messages) do
      {:error, reason} -> Logger.warning("SessionServer persist_messages failed: #{reason}")
      :ok -> :ok
    end

    broadcast_session_started(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  def handle_call({:set_config, params}, _from, state) do
    provider =
      case Map.get(params, "provider") || Map.get(params, :provider) do
        nil -> state.provider
        p -> normalize_provider(p)
      end

    model =
      case Map.get(params, "model") || Map.get(params, :model) do
        nil -> state.model
        m -> to_string(m)
      end

    new_state = %{state | provider: provider, model: model, api_mode: api_mode_for(provider)}

    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "session:#{state.session_id}",
      {:session_config, %{session_id: state.session_id, model: model, provider: provider}}
    )

    {:reply, {:ok, %{model: model, provider: provider}}, new_state}
  end

  def handle_call(:compact, _from, state) do
    before = length(state.messages)
    resolved = resolve_provider(state)

    comp_state = %{
      session_id: state.session_id,
      provider: resolved.module,
      model: state.model,
      base_url: resolved.base_url,
      api_key: resolved.api_key,
      finch_name: Hermes.Finch,
      context_window: Catalog.context_window(state.provider, state.model),
      messages: state.messages
    }

    new_messages = Hermes.Sessions.Compaction.force(comp_state).messages

    {:reply, {:ok, %{before: before, after: length(new_messages)}},
     %{state | messages: new_messages}}
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

      # Persist the user message now; the turn's outputs are persisted as a
      # value-delta on completion (robust to context compression).
      case Store.persist_messages(state.session_id, [user_msg]) do
        {:error, reason} ->
          Logger.warning("SessionServer persist_messages failed: #{reason}")

        :ok ->
          :ok
      end

      Task.start(fn -> run_turn_in_task(session_pid, new_state) end)

      {:noreply, set_status_and_broadcast(new_state, :running)}
    end
  end

  @impl true
  def handle_cast({:turn_finished, %{ok: true, result: result}}, state) do
    broadcast_turn_complete(state.session_id, result)

    # Persist only the messages added this turn (value-delta), so context
    # compression rewriting the in-memory list never re-persists old history.
    new_messages = result.messages -- state.messages

    case Store.persist_messages(state.session_id, new_messages) do
      {:error, reason} ->
        Logger.warning("SessionServer persist_messages failed: #{reason}")

      :ok ->
        :ok
    end

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
    try do
      resolved = resolve_provider(state)
      base_url = state.base_url || resolved.base_url
      api_key = state.api_key || resolved.api_key
      context_window = state.context_window || Catalog.context_window(state.provider, state.model)

      opts = [
        session_id: state.session_id,
        messages: state.messages,
        model: state.model,
        provider: resolved.module,
        api_mode: state.api_mode,
        max_iterations: state.max_iterations,
        session_pid: session_pid,
        base_url: base_url,
        api_key: api_key,
        stream_to: state.session_id,
        context_window: context_window
      ]

      review_opts = [
        provider: resolved.module,
        model: state.model,
        api_mode: state.api_mode,
        base_url: base_url,
        api_key: api_key
      ]

      case TurnLoop.run(opts) do
        {:ok, result} ->
          BackgroundReview.spawn_review(state.session_id, result.messages, review_opts)
          GenServer.cast(session_pid, {:turn_finished, %{ok: true, result: result}})

        {:error, error} ->
          BackgroundReview.spawn_review(state.session_id, error.messages, review_opts)
          GenServer.cast(session_pid, {:turn_finished, %{ok: false, error: error}})
      end
    rescue
      error ->
        GenServer.cast(
          session_pid,
          {:turn_finished,
           %{
             ok: false,
             error: %{
               message: Exception.message(error),
               messages: state.messages,
               api_calls: 0,
               partial: true
             }
           }}
        )
    catch
      kind, reason ->
        GenServer.cast(
          session_pid,
          {:turn_finished,
           %{
             ok: false,
             error: %{
               message: "#{kind}: #{inspect(reason)}",
               messages: state.messages,
               api_calls: 0,
               partial: true
             }
           }}
        )
    end
  end

  # Resolve the session's provider to a concrete module + connection config.
  # Accepts three forms, preserved from how it was started:
  #   * a transport module (e.g. Hermes.Providers.Mock) — used directly
  #   * a built-in atom (:anthropic / :openai / :makora) — resolved by name
  #   * a name string ("makora", a custom provider) — resolved via the catalog
  defp resolve_provider(%{provider: provider}), do: resolve_provider_value(provider)

  defp resolve_provider_value(mod) when is_atom(mod) and not is_nil(mod) do
    if provider_module?(mod) do
      %{name: inspect(mod), kind: "custom", module: mod, base_url: nil, api_key: nil}
    else
      resolve_by_name(Atom.to_string(mod))
    end
  end

  defp resolve_provider_value(name) when is_binary(name), do: resolve_by_name(name)
  defp resolve_provider_value(_), do: resolve_by_name(Catalog.default_provider())

  defp resolve_by_name(name) do
    Catalog.resolve_provider(name) ||
      Catalog.resolve_provider(Catalog.default_provider()) ||
      %{
        name: "anthropic",
        kind: "anthropic",
        module: Hermes.Providers.Anthropic,
        base_url: nil,
        api_key: nil
      }
  end

  # A transport module exports stream/4; a plain name atom like :anthropic does not.
  defp provider_module?(mod), do: Code.ensure_loaded?(mod) and function_exported?(mod, :stream, 4)

  # Keep the provider value as it was passed (atom/module/string) so callers and
  # tests see what they set; only nil falls back to the default.
  defp normalize_provider(nil), do: @default_provider
  defp normalize_provider(provider), do: provider

  defp api_mode_for(provider) do
    case resolve_provider_value(provider) do
      %{module: module} ->
        if function_exported?(module, :api_mode, 0),
          do: module.api_mode(),
          else: @default_api_mode

      _ ->
        @default_api_mode
    end
  end

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
