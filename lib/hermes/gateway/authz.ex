defmodule Hermes.Gateway.Authz do
  @moduledoc """
  Gateway authorization and approval middleware.

  Ports the allowlist and pairing checks from
  `../hermes-agent/gateway/authz_mixin.py:176-454` and the dangerous-command
  approval flow from `../hermes-agent/gateway/run.py:2616-6218`. The module
  answers two questions for every outbound or inbound gateway interaction:

    1. Is this user/chat allowed to use the connector at all?
    2. Does this action require explicit user approval before it runs?

  Allowlists are read from application config. An empty allowlist is treated
  as "allow all" during development, matching the Python dev-mode behaviour.
  Approval requests are broadcast over `Hermes.PubSub` so any interface
  (connector, CLI, web) can present them and call `respond_to_approval/2`.
  """
  use GenServer

  alias Phoenix.PubSub

  @pubsub_topic "gateway:approvals"
  @default_approval_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the authorization manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns true if `user_id` is allowed to use `connector`.

  An empty allowlist configuration allows everyone (development mode). When one
  or more allowlists are configured, the user must appear in at least one of
  them. The special value `"*"` in any list means "allow everyone".
  """
  @spec is_allowed?(connector :: atom(), user_id :: String.t()) :: boolean()
  def is_allowed?(_connector, nil), do: allow_empty?()

  def is_allowed?(connector, user_id) do
    config = gateway_config()

    cond do
      "*" in allowlist(config) -> true
      user_id in allowlist(config) -> true
      "*" in connector_allowlist(connector, config) -> true
      user_id in connector_allowlist(connector, config) -> true
      allow_empty?(config) -> true
      true -> false
    end
  end

  @doc """
  Returns true when `action` requires explicit approval on `connector`.

  The default dangerous actions are `:send_message`, `:execute_tool`, and
  `:file_write`; the exact set is configurable per connector via the
  `:approval_required config key.
  """
  @spec requires_approval?(connector :: atom(), action :: atom()) :: boolean()
  def requires_approval?(connector, action) do
    config = gateway_config()

    required =
      Keyword.get(config, :approval_required, [:send_message, :execute_tool, :file_write])

    connector_required = get_in(config, [:connector_approval, connector]) || []
    action in required or action in connector_required
  end

  @doc """
  Creates an approval request and blocks until it is approved or denied.

  The request is broadcast on the `gateway:approvals` PubSub topic so callers
  can render it to the user. The user (or an automated gate) resolves the
  request with `respond_to_approval/2`. Returns `{:ok, approval_id}` on
  approval or `{:denied, reason}` on denial or timeout.
  """
  @spec request_approval(String.t(), atom(), map()) :: {:ok, String.t()} | {:denied, String.t()}
  def request_approval(session_id, action, details) do
    PubSub.subscribe(Hermes.PubSub, @pubsub_topic)

    approval_id =
      GenServer.call(__MODULE__, {:create_approval, session_id, action, details})

    PubSub.broadcast(
      Hermes.PubSub,
      @pubsub_topic,
      {:approval_request, approval_id, session_id, action, details}
    )

    timeout = approval_timeout_ms()

    receive do
      {:approval_respond, ^approval_id, true} -> {:ok, approval_id}
      {:approval_respond, ^approval_id, false} -> {:denied, "approval denied"}
    after
      timeout ->
        GenServer.cast(__MODULE__, {:expire_approval, approval_id})
        {:denied, "approval timeout"}
    end
  end

  @doc """
  Resolves a pending approval request.

  `approved` must be `true` or `false`. The matching waiter, if any, will
  receive the response and unblock. Returns `:ok` if the request existed,
  otherwise returns `{:error, :not_found}`.
  """
  @spec respond_to_approval(String.t(), boolean()) :: :ok | {:error, :not_found}
  def respond_to_approval(approval_id, approved) when is_boolean(approved) do
    GenServer.call(__MODULE__, {:respond_to_approval, approval_id, approved})
  end

  @doc """
  Returns the IDs of all pending approvals.
  """
  @spec pending_approvals() :: [String.t()]
  def pending_approvals do
    GenServer.call(__MODULE__, :pending_approvals)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{approvals: %{}, approval_counter: 0}}
  end

  @impl true
  def handle_call({:create_approval, session_id, action, details}, _from, state) do
    counter = state.approval_counter + 1
    approval_id = "#{System.system_time(:millisecond)}-#{counter}"

    approval = %{
      id: approval_id,
      session_id: session_id,
      action: action,
      details: details,
      status: :pending,
      created_at: DateTime.utc_now()
    }

    new_state = %{
      state
      | approvals: Map.put(state.approvals, approval_id, approval),
        approval_counter: counter
    }

    {:reply, approval_id, new_state}
  end

  @impl true
  def handle_call({:respond_to_approval, approval_id, approved}, _from, state) do
    case Map.pop(state.approvals, approval_id) do
      {nil, _state} ->
        {:reply, {:error, :not_found}, state}

      {_approval, new_approvals} ->
        PubSub.broadcast(
          Hermes.PubSub,
          @pubsub_topic,
          {:approval_respond, approval_id, approved}
        )

        {:reply, :ok, %{state | approvals: new_approvals}}
    end
  end

  @impl true
  def handle_call(:pending_approvals, _from, state) do
    {:reply, Map.keys(state.approvals), state}
  end

  @impl true
  def handle_cast({:expire_approval, approval_id}, state) do
    {:noreply, %{state | approvals: Map.delete(state.approvals, approval_id)}}
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp gateway_config do
    Application.get_env(:hermes, :gateway, [])
  end

  defp allowlist(config) do
    Keyword.get(config, :allowlist, [])
    |> normalize_allowlist()
  end

  defp connector_allowlist(connector, config) do
    config
    |> Keyword.get(:connector_allowlist, [])
    |> Keyword.get(connector, [])
    |> normalize_allowlist()
  end

  defp normalize_allowlist(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_allowlist(""), do: []
  defp normalize_allowlist(nil), do: []
  defp normalize_allowlist(other) when is_binary(other), do: String.split(other, ",")
  defp normalize_allowlist(_), do: []

  defp allow_empty? do
    allow_empty?(gateway_config())
  end

  defp allow_empty?(config) do
    allowlist(config) == [] and
      Keyword.get(config, :connector_allowlist, []) == []
  end

  defp approval_timeout_ms do
    gateway_config()
    |> Keyword.get(:approval_timeout_ms, @default_approval_timeout_ms)
  end
end
