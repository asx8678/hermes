defmodule Hermes.Repo do
  use Ecto.Repo,
    otp_app: :hermes,
    adapter: Ecto.Adapters.SQLite3
end
