defmodule HermesWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint HermesWeb.Endpoint

      use HermesWeb, :verified_routes

      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import HermesWeb.ChannelCase
    end
  end

  setup tags do
    Hermes.DataCase.setup_sandbox(tags)
    :ok
  end
end
