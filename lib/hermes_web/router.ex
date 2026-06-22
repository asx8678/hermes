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
  end

  scope "/api", HermesWeb do
    pipe_through :api
  end
end
