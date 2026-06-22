defmodule Hermes.Providers.Mock do
  @moduledoc """
  Mock provider transport for CI smoke tests.

  Returns a deterministic assistant response without making any network call,
  so the desktop smoke test can boot the full binary and run one turn
  without a real API key.
  """

  @behaviour Hermes.Providers.Transport

  alias Hermes.Providers.Types.NormalizedResponse
  alias Hermes.Providers.Types.Usage

  @impl true
  def api_mode, do: "mock"

  @impl true
  def convert_messages(messages, _opts \\ []) when is_list(messages), do: {nil, messages}

  @impl true
  def convert_tools(_tools), do: []

  @impl true
  def build_kwargs(_model, messages, _tools, _params \\ []) do
    %{model: "mock", messages: messages}
  end

  @impl true
  def normalize_response(_response, _opts \\ []) do
    %NormalizedResponse{
      content: "Hello from the mock provider. This is a smoke-test response.",
      finish_reason: "stop",
      usage: %Usage{input_tokens: 0, output_tokens: 12, cached_tokens: 0}
    }
  end

  @impl true
  def validate_response(_response), do: true

  @impl true
  def map_finish_reason(_raw_reason), do: "stop"

  @doc """
  Return a fixed assistant response. Arguments mirror
  `Hermes.Providers.Anthropic.stream/4` so the TurnLoop can call either
  provider transparently.
  """
  @spec stream(String.t(), [map()], keyword(), atom()) ::
          {:ok, NormalizedResponse.t()} | {:error, term()}
  def stream(_model, _messages, _opts \\ [], _finch_name \\ Hermes.Finch) do
    {:ok,
     %NormalizedResponse{
       content: "Hello from the mock provider. This is a smoke-test response.",
       finish_reason: "stop",
       usage: %Usage{input_tokens: 0, output_tokens: 12, cached_tokens: 0}
     }}
  end
end
