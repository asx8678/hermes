defmodule HermesWeb.Router do
  use HermesWeb, :router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HermesWeb do
    pipe_through :browser

    live "/dashboard", SessionLive.Index
    live "/sessions/:id", SessionLive.Show
    live "/files", FilesLive
    live "/skills", SkillsLive
    live "/models", ModelsLive
    live "/cron", CronLive
    live "/logs", LogsLive
    live "/analytics", AnalyticsLive
    live "/channels", ChannelsLive
    live "/webhooks", WebhooksLive
    live "/config", ConfigLive
    live "/memory", MemoryLive
    live "/profile", ProfileLive
    live "/system", SystemLive
    live "/plugins", PluginsLive
    live "/mcp", MCPLive
    live "/docs", DocsLive
    live "/chat", ChatLive
  end

  scope "/api", HermesWeb do
    pipe_through :api
  end

  forward "/webhooks", Hermes.Gateway.Webhook
end
