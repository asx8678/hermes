defmodule HermesWeb.PluginsLive do
  @moduledoc """
  LiveView for listing installed plugin LLM hooks.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:hooks, [])
      |> refresh_hooks()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_hooks(socket)}
  end

  def handle_event("toggle_details", %{"module" => module_name}, socket) do
    expanded = socket.assigns.expanded

    expanded_set =
      if module_name in expanded do
        MapSet.delete(MapSet.new(expanded), module_name)
      else
        MapSet.put(MapSet.new(expanded), module_name)
      end

    {:noreply, assign(socket, expanded: MapSet.to_list(expanded_set))}
  end

  defp refresh_hooks(socket) do
    hooks =
      Application.get_env(:hermes, :llm_hooks, [])
      |> Enum.map(fn hook ->
        module = normalize_module(hook)

        %{
          module: module,
          pre_exported: function_exported?(hook, :pre_llm_call, 1),
          post_exported: function_exported?(hook, :post_llm_call, 2)
        }
      end)

    assign(socket, hooks: hooks, expanded: [])
  end

  defp normalize_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp normalize_module(other), do: inspect(other)
end
