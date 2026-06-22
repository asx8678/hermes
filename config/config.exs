# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hermes,
  ecto_repos: [Hermes.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :hermes, HermesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: HermesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hermes.PubSub,
  live_view: [signing_salt: "kcjQlOom"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :hermes, :skills,
  stale_after_days: 30,
  archive_after_days: 90,
  consolidate: false,
  prune_builtins: false,
  hub_skills: []

config :hermes, :gateway,
  allowlist: [],
  approval_required: [:file_write],
  streaming_throttle_ms: 500

config :hermes, Oban,
  engine: Oban.Engines.Lite,
  repo: Hermes.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 */6 * * *", Hermes.Curator.Worker}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
