defmodule HermesWeb.MemoryLive do
  @moduledoc """
  LiveView for viewing, searching, adding, and deleting memory notes.
  Supports switching between "notes" and "profile" targets.
  """

  use HermesWeb, :live_view

  @targets ["notes", "profile"]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:target, "notes")
      |> assign(:query, "")
      |> assign(:entries, [])
      |> assign(:error, nil)
      |> refresh_entries()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_target", %{"target" => target}, socket) when target in @targets do
    socket =
      socket
      |> assign(:target, target)
      |> assign(:query, "")
      |> refresh_entries()

    {:noreply, socket}
  end

  def handle_event("switch_target", _params, socket) do
    {:noreply, assign(socket, :error, "invalid target")}
  end

  def handle_event("search", %{"query" => %{"text" => query}}, socket) do
    socket =
      socket
      |> assign(:query, query)
      |> refresh_entries()

    {:noreply, socket}
  end

  def handle_event("search", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add", %{"entry" => %{"content" => content}}, socket) do
    target = socket.assigns.target

    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => "add", "target" => target, "content" => content},
        %{}
      )

    socket =
      case result do
        %{"success" => true} ->
          socket
          |> assign(:error, nil)
          |> refresh_entries()

        %{"success" => false, "error" => error} ->
          assign(socket, :error, "add failed: #{error}")

        _ ->
          assign(socket, :error, "add failed: unexpected result")
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"old_text" => old_text}, socket) do
    target = socket.assigns.target

    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => "delete", "target" => target, "old_text" => old_text},
        %{}
      )

    socket =
      case result do
        %{"success" => true} ->
          socket
          |> assign(:error, nil)
          |> refresh_entries()

        %{"success" => false, "error" => error} ->
          assign(socket, :error, "delete failed: #{error}")

        _ ->
          assign(socket, :error, "delete failed: unexpected result")
      end

    {:noreply, socket}
  end

  defp refresh_entries(socket) do
    target = socket.assigns.target
    query = socket.assigns.query

    action = if String.trim(query) == "", do: "list", else: "get"

    result =
      Hermes.Tools.MemoryTool.invoke(
        %{"action" => action, "target" => target, "content" => query},
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
        assign(socket, :error, "unexpected memory result")
        |> assign(:entries, [])
    end
  end
end
