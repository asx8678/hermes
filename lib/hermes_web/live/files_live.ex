defmodule HermesWeb.FilesLive do
  @moduledoc """
  LiveView for browsing files in the workspace root.
  """

  use HermesWeb, :live_view

  @default_limit 50

  @impl true
  def mount(_params, _session, socket) do
    root = Application.get_env(:hermes, :workspace_root, File.cwd!())

    socket =
      socket
      |> assign(:root, root)
      |> assign(:pattern, "")
      |> assign(:files, [])
      |> assign(:error, nil)
      |> refresh_files()

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"pattern" => pattern}, socket) do
    socket =
      socket
      |> assign(:pattern, pattern)
      |> refresh_files()

    {:noreply, socket}
  end

  def handle_event("search", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("change_path", %{"path" => path}, socket) do
    root = Application.get_env(:hermes, :workspace_root, File.cwd!())
    expanded = Path.expand(path, root)

    if String.starts_with?(expanded, root) and File.dir?(expanded) do
      socket =
        socket
        |> assign(:root, expanded)
        |> refresh_files()

      {:noreply, socket}
    else
      {:noreply, assign(socket, :error, "invalid directory: #{path}")}
    end
  end

  def handle_event("change_path", _params, socket) do
    {:noreply, socket}
  end

  defp refresh_files(socket) do
    root = socket.assigns.root
    pattern = socket.assigns.pattern

    result =
      Hermes.Tools.FileTools.invoke(
        "search_files",
        %{
          "path" => root,
          "pattern" => pattern,
          "target" => "files",
          "limit" => @default_limit
        }
      )

    case result do
      %{"success" => true, "matches" => matches} ->
        files =
          matches
          |> Enum.map(&%{path: &1, name: Path.basename(&1)})
          |> Enum.sort_by(& &1.name)

        assign(socket, :files, files)
        |> assign(:error, nil)

      %{"success" => false, "error" => error} ->
        assign(socket, :error, error)
        |> assign(:files, [])

      _ ->
        assign(socket, :error, "unexpected search result")
        |> assign(:files, [])
    end
  end
end
