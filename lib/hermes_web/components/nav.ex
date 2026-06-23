defmodule HermesWeb.Components.Nav do
  @moduledoc """
  Shared navigation component for the Hermes web dashboard.
  """

  use Phoenix.Component

  def nav(assigns) do
    assigns =
      assign(assigns,
        links: [
          {"Dashboard", "/dashboard"},
          {"Sessions", "/sessions/first"},
          {"Files", "/files"},
          {"Skills", "/skills"},
          {"Models", "/models"},
          {"Cron", "/cron"},
          {"Logs", "/logs"},
          {"Analytics", "/analytics"},
          {"Channels", "/channels"},
          {"Webhooks", "/webhooks"},
          {"Config", "/config"},
          {"Memory", "/memory"},
          {"Profile", "/profile"},
          {"System", "/system"},
          {"Plugins", "/plugins"},
          {"MCP", "/mcp"},
          {"Docs", "/docs"},
          {"Chat", "/chat"}
        ]
      )

    ~H"""
    <nav class="hermes-nav">
      <ul>
        <%= for {label, path} <- @links do %>
          <li><a href={path}><%= label %></a></li>
        <% end %>
      </ul>
    </nav>
    """
  end
end
