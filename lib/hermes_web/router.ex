defmodule HermesWeb.Router do
  use HermesWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", HermesWeb do
    pipe_through :api
  end
end
