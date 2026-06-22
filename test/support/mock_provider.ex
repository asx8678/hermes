defmodule Hermes.Test.MockProvider do
  @moduledoc """
  Test double for `Hermes.Providers.Anthropic`.

  Stores a queue of canned `NormalizedResponse` structs and returns them
  in order from `stream/4`.  Use `enqueue/1` to load responses and `reset/0`
  to clear the queue between tests.
  """

  use Agent
  alias Hermes.Providers.Types.NormalizedResponse

  def start_link(_ \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def enqueue(%NormalizedResponse{} = response) do
    Agent.update(__MODULE__, fn queue -> queue ++ [response] end)
  end

  @doc """
  Adds a canned error response to the end of the queue.
  """
  @spec enqueue_error(term()) :: :ok
  def enqueue_error(reason) do
    Agent.update(__MODULE__, fn queue -> queue ++ [{:error, reason}] end)
  end

  @doc """
  Clears the response queue.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  @doc """
  Pops the next canned response.

  Returns `{:error, :empty}` when the queue is exhausted.
  """
  @spec stream(String.t(), [map()], keyword(), atom()) ::
          {:ok, NormalizedResponse.t()} | {:error, term()}
  def stream(_model, _messages, _opts, _finch_name) do
    Agent.get_and_update(__MODULE__, fn
      [] -> {{:error, :empty}, []}
      [{:error, reason} | tail] -> {{:error, reason}, tail}
      [head | tail] -> {{:ok, head}, tail}
    end)
  end
end
