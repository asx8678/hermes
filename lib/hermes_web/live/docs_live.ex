defmodule HermesWeb.DocsLive do
  @moduledoc """
  LiveView for browsing built-in markdown documentation.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    docs_root = Application.app_dir(:hermes, "priv/docs")
    files = list_doc_files(docs_root)

    socket =
      socket
      |> assign(:docs_root, docs_root)
      |> assign(:files, files)
      |> assign(:query, "")
      |> assign(:selected, nil)
      |> assign(:content, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select", %{"file" => filename}, socket) do
    case read_doc_file(socket.assigns.docs_root, filename) do
      {:ok, content} ->
        {:noreply,
         socket
         |> assign(:selected, filename)
         |> assign(:content, content)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:content, nil)
         |> assign(:error, "Could not read #{filename}: #{inspect(reason)}")}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    filtered = filter_files(socket.assigns.files, query)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:files, filtered)}
  end

  def handle_event("clear_search", _params, socket) do
    docs_root = socket.assigns.docs_root

    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:files, list_doc_files(docs_root))}
  end

  defp list_doc_files(docs_root) do
    case File.ls(docs_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&%{filename: &1, title: title_from_filename(&1)})
        |> Enum.sort_by(& &1.filename)

      {:error, _reason} ->
        []
    end
  end

  defp filter_files(files, ""), do: files

  defp filter_files(files, query) do
    downcase_query = String.downcase(query)

    Enum.filter(files, fn file ->
      String.contains?(String.downcase(file.filename), downcase_query) or
        String.contains?(String.downcase(file.title), downcase_query)
    end)
  end

  defp read_doc_file(docs_root, filename) do
    path = Path.join(docs_root, filename)

    if path_within_root?(path, docs_root) do
      File.read(path)
    else
      {:error, :invalid_path}
    end
  end

  defp path_within_root?(path, root) do
    expanded = Path.expand(path)
    root_expanded = Path.expand(root)
    String.starts_with?(expanded, root_expanded)
  end

  defp title_from_filename(filename) do
    filename
    |> String.replace_suffix(".md", "")
    |> String.replace(["_", "-"], " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
