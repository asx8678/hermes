defmodule Hermes.Test.MockTelegramBot do
  @moduledoc """
  Test double for `Hermes.Gateway.Connectors.TelegramBot`.

  Records every Bot API call and returns canned responses pushed by tests.
  Push either `{:ok, value}` or `{:error, reason}` to control the return value
  of the matching function.
  """

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{calls: [], responses: %{}} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{calls: [], responses: %{}} end)
  end

  def push_response(key, response) do
    Agent.update(__MODULE__, fn state ->
      responses = Map.update(state.responses, key, [response], &(&1 ++ [response]))
      %{state | responses: responses}
    end)
  end

  def calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  def get_me(bot_token) do
    pop_response(:get_me, [bot_token])
  end

  def get_updates(bot_token, offset, timeout) do
    pop_response(:get_updates, [bot_token, offset, timeout])
  end

  def send_message(bot_token, chat_id, text, opts) do
    pop_response(:send_message, [bot_token, chat_id, text, opts])
  end

  defp pop_response(key, args) do
    Agent.get_and_update(__MODULE__, fn state ->
      calls = [{key, args} | state.calls]
      responses = Map.get(state.responses, key, [])

      case responses do
        [head | tail] ->
          new_responses = Map.put(state.responses, key, tail)
          {head, %{state | calls: calls, responses: new_responses}}

        [] ->
          {{:error, :no_mock_response}, %{state | calls: calls}}
      end
    end)
  end
end
