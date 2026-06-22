defmodule Hermes.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HermesWeb.Telemetry,
      Hermes.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:hermes, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:hermes, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hermes.PubSub},
      {Registry, keys: :unique, name: Hermes.Sessions.Registry},
      {Finch, name: Hermes.Finch},
      {Hermes.Sessions.Supervisor, name: Hermes.Sessions.Supervisor},
      {Hermes.Gateway.Registry, name: Hermes.Gateway.Registry},
      {Hermes.Gateway.Supervisor, name: Hermes.Gateway.Supervisor},
      # Start to serve requests, typically the last entry
      HermesWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hermes.Supervisor]
    Supervisor.start_link(children, opts)
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
end
