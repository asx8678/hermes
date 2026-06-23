defmodule Hermes.Gateway.Webhook do
  @moduledoc """
  HTTP webhook receiver for gateway connectors.

  Parses inbound webhook payloads and forwards them to the running connector
  process identified by the URL path. The connector is responsible for
  authenticating and interpreting the platform-specific payload.

  Per-connector authentication (shared secrets, signatures, etc.) is expected
  to be handled inside each connector's `handle_inbound/2` callback.
  """

  import Plug.Conn

  require Logger

  @default_timeout 30_000

  def init(opts), do: opts

  def call(conn, _opts) do
    connector_name = List.last(conn.path_info) || ""

    case running_connector(connector_name) do
      nil ->
        Logger.warning("Webhook received for unavailable connector: #{connector_name}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "connector_not_found"}))

      pid ->
        payload = conn.body_params || %{}

        case GenServer.call(pid, {:handle_inbound, payload}, @default_timeout) do
          {:ok, _} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{status: "ok"}))

          {:error, reason} ->
            Logger.warning(
              "Connector #{connector_name} failed to handle webhook: #{inspect(reason)}"
            )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, Jason.encode!(%{error: "handler_failed"}))
        end
    end
  end

  defp running_connector(name) when is_binary(name) and name != "" do
    Hermes.Gateway.Registry.list_connectors()
    |> Enum.find(fn entry -> Atom.to_string(entry.name) == name end)
    |> case do
      nil -> nil
      entry -> Hermes.Gateway.Registry.whereis(entry.name)
    end
  end

  defp running_connector(_name), do: nil
end
