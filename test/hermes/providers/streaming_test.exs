defmodule Hermes.Providers.StreamingTest do
  use ExUnit.Case, async: false

  alias Hermes.Providers.Mock

  test "stream/4 broadcasts an incremental delta to the session topic when :stream_to is set" do
    session_id = "stream-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")

    {:ok, _resp} = Mock.stream("mock", [], stream_to: session_id)

    assert_receive {:stream_delta, text}, 500
    assert text =~ "mock provider"
  end

  test "stream/4 does not broadcast when :stream_to is absent" do
    session_id = "stream-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")

    {:ok, _resp} = Mock.stream("mock", [])

    refute_receive {:stream_delta, _}, 200
  end
end
