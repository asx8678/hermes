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
  def connect(params, socket, _connect_info) do
    case fetch_auth_token() do
      nil ->
        # No token configured — localhost boundary, allow all (Milestone A compat)
        {:ok, socket}

      expected_token ->
        case params["token"] || params["Authorization"] do
          nil ->
            {:error, :missing_token}

          token when is_binary(token) ->
            token = String.replace_prefix(token, "Bearer ", "")

            if String.equivalent?(token, expected_token) do
              {:ok, socket}
            else
              {:error, :unauthorized}
            end

          _ ->
            {:error, :unauthorized}
        end
    end
  end

  defp fetch_auth_token do
    Application.get_env(:hermes, :channel_auth_token) ||
      System.get_env("HERMES_CHANNEL_TOKEN")
  end

  @impl true
  def id(_socket), do: nil
end
