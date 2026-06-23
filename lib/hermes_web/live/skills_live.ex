defmodule HermesWeb.SkillsLive do
  @moduledoc """
  LiveView for listing, viewing, creating, and deleting skills.
  """

  use HermesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:skills, [])
      |> assign(:categories, [])
      |> assign(:query, "")
      |> assign(:category, "")
      |> assign(:viewing, nil)
      |> assign(:error, nil)
      |> assign(:create_open, false)
      |> refresh_skills()

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query, "category" => category}, socket) do
    socket =
      socket
      |> assign(:query, query)
      |> assign(:category, category)
      |> refresh_skills()

    {:noreply, socket}
  end

  def handle_event("search", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("view", %{"name" => name}, socket) do
    result = Hermes.Tools.SkillTools.invoke("skill_view", %{"name" => name})

    case result do
      %{"success" => true, "content" => content} ->
        {:noreply,
         assign(socket, :viewing, %{name: name, content: content})
         |> assign(:error, nil)}

      %{"success" => false, "error" => error} ->
        {:noreply, assign(socket, :error, "view failed: #{error}")}

      _ ->
        {:noreply, assign(socket, :error, "unexpected view result")}
    end
  end

  def handle_event("close_view", _params, socket) do
    {:noreply, assign(socket, :viewing, nil)}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    result =
      Hermes.Tools.SkillTools.invoke("skill_manage", %{"action" => "delete", "name" => name})

    case result do
      %{"success" => true} ->
        {:noreply,
         socket
         |> refresh_skills()
         |> assign(:error, nil)}

      %{"success" => false, "error" => error} ->
        {:noreply, assign(socket, :error, "delete failed: #{error}")}

      _ ->
        {:noreply, assign(socket, :error, "unexpected delete result")}
    end
  end

  def handle_event("toggle_create", _params, socket) do
    {:noreply, assign(socket, :create_open, not socket.assigns.create_open)}
  end

  def handle_event(
        "create",
        %{"name" => name, "category" => category, "content" => content},
        socket
      ) do
    category_header = if category != "", do: "# Category: #{category}\n", else: ""
    full_content = category_header <> content

    result =
      Hermes.Tools.SkillTools.invoke("skill_manage", %{
        "action" => "create",
        "name" => name,
        "content" => full_content
      })

    case result do
      %{"success" => true} ->
        {:noreply,
         socket
         |> refresh_skills()
         |> assign(:create_open, false)
         |> assign(:error, nil)}

      %{"success" => false, "error" => error} ->
        {:noreply, assign(socket, :error, "create failed: #{error}")}

      _ ->
        {:noreply, assign(socket, :error, "unexpected create result")}
    end
  end

  defp refresh_skills(socket) do
    query = socket.assigns.query |> String.downcase()
    category = socket.assigns.category

    result =
      Hermes.Tools.SkillTools.invoke(
        "skills_list",
        if(category != "", do: %{"category" => category}, else: %{})
      )

    case result do
      %{"success" => true, "skills" => skills, "categories" => categories} ->
        filtered =
          skills
          |> Enum.filter(fn skill ->
            q = String.downcase(skill["name"] || "")

            String.contains?(q, query) or
              String.contains?(String.downcase(skill["category"] || ""), query)
          end)
          |> Enum.map(
            &%{name: &1["name"], category: &1["category"], description: &1["description"]}
          )

        assign(socket, :skills, filtered)
        |> assign(:categories, categories)
        |> assign(:error, nil)

      %{"success" => false, "error" => error} ->
        assign(socket, :error, "list failed: #{error}")
        |> assign(:skills, [])

      _ ->
        assign(socket, :error, "unexpected list result")
        |> assign(:skills, [])
    end
  end
end
