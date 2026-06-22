defmodule Hermes.Tools.ClarifyTest do
  use ExUnit.Case, async: false

  alias Hermes.Tools.Dispatcher
  alias Hermes.Tools.Registry

  test "clarify is a registered, valid tool name" do
    assert MapSet.member?(Registry.valid_tool_names(), "clarify")
  end

  test "invoking clarify broadcasts a clarify_request and returns an 'asked' status" do
    session_id = "clarify-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")

    context = %{
      session_id: session_id,
      session_pid: self(),
      finch_name: Hermes.Finch,
      repo: Hermes.Repo
    }

    result = Dispatcher.invoke("clarify", %{"question" => "Which file did you mean?"}, context)

    assert result =~ "asked"
    assert_receive {:clarify_request, %{question: "Which file did you mean?"}}, 1_000
  end
end
