defmodule Hermes.Approvals do
  @moduledoc """
  Human-in-the-loop tool approval.

  Some tools (configured via `config :hermes, :gateway, approval_required: [...]`)
  must be confirmed by the user before they run. When the turn loop is about to
  invoke such a tool, it calls `request/3`, which:

    1. broadcasts an `{:approval_request, ...}` event on the session topic (the
       channel forwards it to the TUI / LiveView as `approval:request`), and
    2. blocks the turn — which runs in its own task — until the UI replies via
       `respond/2`, or a timeout elapses (default: deny).

  The reply is routed back over a unique `"approval:<id>"` PubSub topic that the
  waiting task subscribes to, correlated by the random approval id.
  """

  require Logger

  @default_timeout_ms 120_000

  @doc "Returns true when the given tool requires explicit user approval."
  @spec required?(String.t()) :: boolean()
  def required?(tool_name) when is_binary(tool_name) do
    tool_name in required_tools()
  end

  @doc """
  Requests approval for `tool_name` and blocks until the user responds (or the
  timeout elapses). Returns `:approved` or `:denied`.
  """
  @spec request(String.t(), String.t(), map(), keyword()) :: :approved | :denied
  def request(session_id, tool_name, args, opts \\ []) do
    approval_id = generate_id()
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    topic = "approval:#{approval_id}"

    Phoenix.PubSub.subscribe(Hermes.PubSub, topic)

    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "session:#{session_id}",
      {:approval_request,
       %{
         approval_id: approval_id,
         tool: tool_name,
         args: args,
         reason: "Tool '#{tool_name}' requires your approval before running."
       }}
    )

    result =
      receive do
        {:approval_response, ^approval_id, approved} ->
          if approved, do: :approved, else: :denied
      after
        timeout ->
          Logger.info("Approval for #{tool_name} (#{approval_id}) timed out — denying")
          :denied
      end

    Phoenix.PubSub.unsubscribe(Hermes.PubSub, topic)
    result
  end

  @doc """
  Delivers the user's decision for `approval_id` to the waiting turn.
  """
  @spec respond(String.t(), boolean()) :: :ok
  def respond(approval_id, approved) when is_binary(approval_id) and is_boolean(approved) do
    Phoenix.PubSub.broadcast(
      Hermes.PubSub,
      "approval:#{approval_id}",
      {:approval_response, approval_id, approved}
    )
  end

  # Map configured approval actions to concrete tool names. `:file_write` covers
  # the file-modifying tools.
  defp required_tools do
    :hermes
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:approval_required, [])
    |> Enum.flat_map(fn
      :file_write -> ["write_file", "patch"]
      action when is_atom(action) -> [Atom.to_string(action)]
      action when is_binary(action) -> [action]
      _ -> []
    end)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
