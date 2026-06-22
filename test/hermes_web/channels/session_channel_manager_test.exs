defmodule HermesWeb.SessionChannelManagerTest do
  @moduledoc """
  Tests for the model/provider manager handlers on `HermesWeb.SessionChannel`
  (`/model` and `/providers`).
  """

  use HermesWeb.ChannelCase, async: false

  setup do
    {:ok, _, socket} = socket(@endpoint) |> join(HermesWeb.SessionChannel, "session:new")
    ref = push(socket, "session:create", %{"model" => "gpt-4o", "provider" => "makora"})
    assert_reply ref, :ok, %{session_id: session_id}
    %{socket: socket, session_id: session_id}
  end

  describe "session:config (fixes the /model no-op)" do
    test "updates the live session model/provider and pushes a confirmation", %{socket: socket} do
      ref = push(socket, "session:config", %{"model" => "moonshotai/Kimi-K2.7-Code"})
      assert_reply ref, :ok, %{model: "moonshotai/Kimi-K2.7-Code"}
      assert_push "session:config", %{model: "moonshotai/Kimi-K2.7-Code"}
    end

    test "can switch provider", %{socket: socket, session_id: session_id} do
      ref = push(socket, "session:config", %{"provider" => "anthropic"})
      assert_reply ref, :ok, %{provider: "anthropic"}

      state =
        Hermes.Sessions.SessionServer.get_state(Hermes.Sessions.SessionServer.whereis(session_id))

      assert state.provider == "anthropic"
    end
  end

  describe "providers:list / providers:add / providers:remove" do
    test "lists built-in providers", %{socket: socket} do
      ref = push(socket, "providers:list", %{})
      assert_reply ref, :ok, %{}
      assert_push "providers:listed", %{providers: providers}
      names = Enum.map(providers, & &1.name)
      assert "makora" in names and "anthropic" in names
    end

    test "adds a custom provider and it appears in the refreshed list", %{socket: socket} do
      ref =
        push(socket, "providers:add", %{
          "name" => "mylab",
          "kind" => "openai",
          "base_url" => "http://localhost:9000/v1",
          "api_key" => "sk-x"
        })

      assert_reply ref, :ok, %{}
      assert_push "providers:listed", %{providers: providers}
      assert Enum.any?(providers, &(&1.name == "mylab"))
    end

    test "rejects an invalid provider kind", %{socket: socket} do
      ref = push(socket, "providers:add", %{"name" => "x", "kind" => "bogus"})
      assert_reply ref, :error, %{reason: reason}
      assert reason =~ "kind"
    end

    test "removes a custom provider", %{socket: socket} do
      ref =
        push(socket, "providers:add", %{
          "name" => "tmp",
          "kind" => "openai",
          "base_url" => "http://x/v1"
        })

      assert_reply ref, :ok, %{}
      # Consume the refreshed list pushed by the add before checking the remove.
      assert_push "providers:listed", %{providers: after_add}
      assert Enum.any?(after_add, &(&1.name == "tmp"))

      ref = push(socket, "providers:remove", %{"name" => "tmp"})
      assert_reply ref, :ok, %{}
      assert_push "providers:listed", %{providers: providers}
      refute Enum.any?(providers, &(&1.name == "tmp"))
    end
  end

  describe "models:list / models:add" do
    test "lists models for a provider", %{socket: socket} do
      ref = push(socket, "models:list", %{"provider" => "makora"})
      assert_reply ref, :ok, %{}
      assert_push "models:listed", %{provider: "makora", models: models}
      assert Enum.any?(models, &(&1.model_id == "moonshotai/Kimi-K2.7-Code"))
    end

    test "adds a custom model with metadata", %{socket: socket} do
      ref =
        push(socket, "models:add", %{
          "provider_name" => "makora",
          "model_id" => "custom-x",
          "context_window" => 50_000
        })

      assert_reply ref, :ok, %{}
      assert_push "models:listed", %{models: models}
      added = Enum.find(models, &(&1.model_id == "custom-x"))
      assert added.context_window == 50_000
    end
  end

  describe "session:list" do
    test "pushes the session list", %{socket: socket} do
      ref = push(socket, "session:list", %{})
      assert_reply ref, :ok, %{}
      assert_push "sessions:listed", %{sessions: sessions}
      assert is_list(sessions)
    end
  end
end
