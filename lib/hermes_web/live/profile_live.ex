defmodule HermesWeb.ProfileLive do
  @moduledoc """
  LiveView for managing profile memory entries.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:entries, [])
      |> assign(:error, nil)
      |> refresh_profile()

    {:ok, socket}
  end

  @impl true
  def handle_event("add", %{"entry" => %{"content" => content}}, socket) do
    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => "add", "target" => "profile", "content" => content},
        %{}
      )

    socket =
      case result do
        %{"success" => true} ->
          socket
          |> assign(:error, nil)
          |> refresh_profile()

        %{"success" => false, "error" => error} ->
          assign(socket, :error, "add failed: #{error}")

        _ ->
          assign(socket, :error, "add failed: unexpected result")
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"old_text" => old_text}, socket) do
    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => "delete", "target" => "profile", "old_text" => old_text},
        %{}
      )

    socket =
      case result do
        %{"success" => true} ->
          socket
          |> assign(:error, nil)
          |> refresh_profile()

        %{"success" => false, "error" => error} ->
          assign(socket, :error, "delete failed: #{error}")

        _ ->
          assign(socket, :error, "delete failed: unexpected result")
      end

    {:noreply, socket}
  end

  defp refresh_profile(socket) do
    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => "list", "target" => "profile"},
        %{}
      )

    case result do
      %{"success" => true, "entries" => entries} ->
        assign(socket, :entries, entries)
        |> assign(:error, nil)

      %{"success" => false, "error" => error} ->
        assign(socket, :error, error)
        |> assign(:entries, [])

      _ ->
        assign(socket, :error, "unexpected profile result")
        |> assign(:entries, [])
    end
  end
end
