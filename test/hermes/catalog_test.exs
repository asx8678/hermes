defmodule Hermes.CatalogTest do
  use Hermes.DataCase, async: false

  alias Hermes.Catalog

  describe "built-in providers and models" do
    test "built-ins are always listed without any DB rows" do
      names = Catalog.list_providers() |> Enum.map(& &1.name)
      assert "makora" in names
      assert "openai" in names
      assert "anthropic" in names
      assert "mock" in names
    end

    test "resolve_provider returns module + config for a built-in" do
      assert %{module: Hermes.Providers.OpenAI, base_url: "https://inference.makora.com/v1"} =
               Catalog.resolve_provider("makora")

      assert %{module: Hermes.Providers.Anthropic} = Catalog.resolve_provider("anthropic")
      assert %{module: Hermes.Providers.Mock} = Catalog.resolve_provider("mock")
    end

    test "resolve_provider accepts atoms and is case-insensitive" do
      assert %{name: "anthropic"} = Catalog.resolve_provider(:anthropic)
      assert %{name: "makora"} = Catalog.resolve_provider("MAKORA")
    end

    test "context_window resolves built-in model metadata" do
      assert Catalog.context_window("makora", "moonshotai/Kimi-K2.7-Code") == 262_144
      assert Catalog.context_window("anthropic", "claude-sonnet-4-20250514") == 200_000
      assert Catalog.context_window("makora", "unknown-model") == nil
    end

    test "resolve_provider returns nil for an unknown provider" do
      assert Catalog.resolve_provider("does-not-exist") == nil
    end
  end

  describe "custom providers" do
    test "upsert + resolve a custom OpenAI-compatible provider with its own base_url" do
      assert {:ok, _} =
               Catalog.upsert_provider(%{
                 name: "localllm",
                 label: "Local LLM",
                 kind: "openai",
                 base_url: "http://localhost:1234/v1",
                 api_key: "sk-local"
               })

      assert %{
               module: Hermes.Providers.OpenAI,
               base_url: "http://localhost:1234/v1",
               api_key: "sk-local"
             } = Catalog.resolve_provider("localllm")

      assert "localllm" in Enum.map(Catalog.list_providers(), & &1.name)
    end

    test "api_key resolves from a named env var when no key is stored" do
      System.put_env("CUSTOM_TEST_KEY", "from-env")
      on_exit(fn -> System.delete_env("CUSTOM_TEST_KEY") end)

      {:ok, _} =
        Catalog.upsert_provider(%{
          name: "envllm",
          kind: "openai",
          base_url: "http://x/v1",
          api_key_env: "CUSTOM_TEST_KEY"
        })

      assert %{api_key: "from-env"} = Catalog.resolve_provider("envllm")
    end

    test "a custom row overrides a built-in of the same name" do
      {:ok, _} =
        Catalog.upsert_provider(%{name: "makora", kind: "openai", base_url: "http://override/v1"})

      assert %{base_url: "http://override/v1"} = Catalog.resolve_provider("makora")
      entry = Enum.find(Catalog.list_providers(), &(&1.name == "makora"))
      assert entry.builtin == true
    end

    test "delete_provider removes the custom provider and its models" do
      {:ok, _} = Catalog.upsert_provider(%{name: "temp", kind: "openai", base_url: "http://x/v1"})
      {:ok, _} = Catalog.upsert_model(%{provider_name: "temp", model_id: "m1"})

      :ok = Catalog.delete_provider("temp")

      assert Catalog.resolve_provider("temp") == nil
      assert Catalog.list_models("temp") == []
    end

    test "invalid kind is rejected" do
      assert {:error, changeset} = Catalog.upsert_provider(%{name: "bad", kind: "nonsense"})
      assert %{kind: _} = errors_on(changeset)
    end
  end

  describe "custom models" do
    test "upsert a custom model with metadata and resolve its context window" do
      {:ok, _} =
        Catalog.upsert_model(%{
          provider_name: "makora",
          model_id: "my-finetune",
          label: "My Finetune",
          context_window: 32_000,
          max_output_tokens: 4_096,
          supports_tools: 1
        })

      assert Catalog.context_window("makora", "my-finetune") == 32_000

      model = Enum.find(Catalog.list_models("makora"), &(&1.model_id == "my-finetune"))
      assert model.label == "My Finetune"
      assert model.supports_tools == true
    end

    test "list_models filters by provider" do
      models = Catalog.list_models("anthropic")
      assert Enum.all?(models, &(&1.provider_name == "anthropic"))
    end

    test "rejects a non-positive context window" do
      assert {:error, changeset} =
               Catalog.upsert_model(%{provider_name: "makora", model_id: "x", context_window: 0})

      assert %{context_window: _} = errors_on(changeset)
    end
  end
end
