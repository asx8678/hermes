defmodule HermesWeb.CronLive do
  @moduledoc """
  LiveView for listing, scheduling, and deleting cron routines.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:routines, [])
      |> assign(:error, nil)
      |> assign(:success, nil)
      |> assign(:form, %{"name" => "", "cron" => "", "prompt" => "", "session_id" => ""})
      |> refresh_routines()

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "schedule",
        %{
          "name" => name,
          "cron" => cron,
          "prompt" => prompt,
          "session_id" => session_id
        },
        socket
      ) do
    result =
      Hermes.Tools.CronjobTool.invoke(
        %{
          "action" => "schedule",
          "name" => name,
          "cron" => cron,
          "prompt" => prompt,
          "session_id" => maybe_nil(session_id)
        },
        %{}
      )

    socket =
      case result do
        %{"success" => true} = ok ->
          socket
          |> assign(:success, Map.get(ok, "message", "Scheduled"))
          |> assign(:error, nil)
          |> assign(:form, %{"name" => "", "cron" => "", "prompt" => "", "session_id" => ""})
          |> refresh_routines()

        %{"success" => false, "error" => error} ->
          socket
          |> assign(:error, error)
          |> assign(:success, nil)

        _ ->
          assign(socket, :error, "unexpected schedule result")
      end

    {:noreply, socket}
  end

  def handle_event("schedule", _params, socket) do
    {:noreply, assign(socket, :error, "name, cron, and prompt are required")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    result =
      Hermes.Tools.CronjobTool.invoke(
        %{"action" => "delete", "id" => id},
        %{}
      )

    socket =
      case result do
        %{"success" => true} = ok ->
          socket
          |> assign(:success, Map.get(ok, "message", "Deleted"))
          |> assign(:error, nil)
          |> refresh_routines()

        %{"success" => false, "error" => error} ->
          socket
          |> assign(:error, error)
          |> assign(:success, nil)

        _ ->
          assign(socket, :error, "unexpected delete result")
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:noreply, assign(socket, :error, "routine id is required")}
  end

  def handle_event("form_change", params, socket) do
    form = Map.take(params, ["name", "cron", "prompt", "session_id"])
    {:noreply, assign(socket, :form, Map.merge(socket.assigns.form, form))}
  end

  def handle_event("clear_messages", _params, socket) do
    {:noreply, assign(socket, error: nil, success: nil)}
  end

  @impl true
  def handle_info({:cron_routine_changed, _routine_id}, socket) do
    {:noreply, refresh_routines(socket)}
  end

  defp refresh_routines(socket) do
    result = Hermes.Tools.CronjobTool.invoke(%{"action" => "list"}, %{})

    case result do
      %{"success" => true, "routines" => routines} ->
        assign(socket, :routines, routines || [])

      %{"success" => false, "error" => error} ->
        assign(socket, :error, error)

      _ ->
        assign(socket, :error, "unexpected list result")
    end
  end

  defp maybe_nil(""), do: nil
  defp maybe_nil(session_id) when is_binary(session_id), do: session_id
  defp maybe_nil(_), do: nil
end
