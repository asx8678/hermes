defmodule Hermes.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Hermes.Repo,
      {Oban, Application.fetch_env!(:hermes, Oban)},
      {Ecto.Migrator,
       repos: Application.fetch_env!(:hermes, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:hermes, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hermes.PubSub},
      {Registry, keys: :unique, name: Hermes.Sessions.Registry},
      {Hermes.Sessions.Supervisor, name: Hermes.Sessions.Supervisor},
      {Hermes.Tools.TerminalSidecar, name: Hermes.Tools.TerminalSidecar},
      {Hermes.Tools.CodeExecutionSidecar, name: Hermes.Tools.CodeExecutionSidecar},
      {Hermes.Gateway.Registry, name: Hermes.Gateway.Registry},
      {Hermes.Gateway.Supervisor, name: Hermes.Gateway.Supervisor},
      {Hermes.Gateway.Streaming, name: Hermes.Gateway.Streaming},
      {Hermes.Gateway.Authz, name: Hermes.Gateway.Authz},
      # Start to serve requests, typically the last entry
      HermesWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hermes.Supervisor]

    with {:ok, sup_pid} <- Supervisor.start_link(children, opts) do
      # Register built-in connectors. Connectors that require environment
      # variables are registered regardless, but they cannot be started until
      # their required env vars are present.
      _ = Hermes.Gateway.Registry.register(telegram_connector_entry())
      _ = Hermes.Gateway.Registry.register(discord_connector_entry())
      _ = Hermes.Gateway.Registry.register(slack_connector_entry())
      _ = Hermes.Gateway.Registry.register(whatsapp_connector_entry())
      _ = Hermes.Gateway.Registry.register(signal_connector_entry())
      _ = Hermes.Gateway.Registry.register(email_connector_entry())
      _ = Hermes.Gateway.Registry.register(feishu_connector_entry())
      {:ok, sup_pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HermesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp telegram_connector_entry do
    %{
      name: :telegram,
      label: "Telegram",
      module: Hermes.Gateway.Connectors.Telegram,
      check_fn: fn -> System.get_env("TELEGRAM_BOT_TOKEN") != nil end,
      required_env: ["TELEGRAM_BOT_TOKEN"]
    }
  end

  defp discord_connector_entry do
    %{
      name: :discord,
      label: "Discord",
      module: Hermes.Gateway.Connectors.Discord,
      check_fn: fn -> System.get_env("DISCORD_BOT_TOKEN") != nil end,
      required_env: ["DISCORD_BOT_TOKEN"]
    }
  end

  defp slack_connector_entry do
    %{
      name: :slack,
      label: "Slack",
      module: Hermes.Gateway.Connectors.Slack,
      check_fn: fn -> System.get_env("SLACK_BOT_TOKEN") != nil end,
      required_env: ["SLACK_BOT_TOKEN"]
    }
  end

  defp whatsapp_connector_entry do
    %{
      name: :whatsapp,
      label: "WhatsApp",
      module: Hermes.Gateway.Connectors.WhatsApp,
      check_fn: fn ->
        System.get_env("WHATSAPP_TOKEN") != nil and
          System.get_env("WHATSAPP_PHONE_NUMBER_ID") != nil
      end,
      required_env: ["WHATSAPP_TOKEN", "WHATSAPP_PHONE_NUMBER_ID"]
    }
  end

  defp signal_connector_entry do
    %{
      name: :signal,
      label: "Signal",
      module: Hermes.Gateway.Connectors.Signal,
      check_fn: fn ->
        System.get_env("SIGNAL_PHONE_NUMBER") != nil and
          System.get_env("SIGNAL_API_URL") != nil
      end,
      required_env: ["SIGNAL_PHONE_NUMBER", "SIGNAL_API_URL"]
    }
  end

  defp email_connector_entry do
    %{
      name: :email,
      label: "Email",
      module: Hermes.Gateway.Connectors.Email,
      check_fn: fn ->
        System.get_env("IMAP_HOST") != nil and
          System.get_env("IMAP_USER") != nil and
          System.get_env("IMAP_PASSWORD") != nil and
          System.get_env("SMTP_HOST") != nil and
          System.get_env("SMTP_USER") != nil and
          System.get_env("SMTP_PASSWORD") != nil
      end,
      required_env: [
        "IMAP_HOST",
        "IMAP_USER",
        "IMAP_PASSWORD",
        "SMTP_HOST",
        "SMTP_USER",
        "SMTP_PASSWORD"
      ]
    }
  end

  defp feishu_connector_entry do
    %{
      name: :feishu,
      label: "Feishu",
      module: Hermes.Gateway.Connectors.Feishu,
      check_fn: fn ->
        System.get_env("FEISHU_APP_ID") != nil and
          System.get_env("FEISHU_APP_SECRET") != nil
      end,
      required_env: ["FEISHU_APP_ID", "FEISHU_APP_SECRET"]
    }
  end
end
