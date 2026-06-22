defmodule HermesWeb.UserSocket do
  @moduledoc """
  WebSocket entry point for the Phoenix channel boundary.

  Ports the transport-agnostic handler semantics of
  `tui_gateway/server.py:898` from JSON-RPC/stdio to Phoenix Channels over
  a localhost WebSocket.  No authentication is enforced in Milestone A; the
  boundary is expected to run locally.
  """

  use Phoenix.Socket

  channel "session:*", HermesWeb.SessionChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
