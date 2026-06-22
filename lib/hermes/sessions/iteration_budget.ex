defmodule Hermes.Sessions.IterationBudget do
  @moduledoc """
  Pure-data iteration budget.

  Ported from Python `agent/iteration_budget.py:17`.
  The Python class uses a `threading.Lock` to serialize `consume/1`,
  `refund/1`, `used` and `remaining`; in Elixir the calling `SessionServer`
  serializes access, so this module keeps no process state.

  `execute_code` turns are refunded by the turn loop so cheap programmatic
  tool calls do not eat into the conversation budget.
  """

  defstruct max_total: 90, used: 0

  @type t :: %__MODULE__{
          max_total: non_neg_integer(),
          used: non_neg_integer()
        }

  @doc """
  Creates a new budget.

  Defaults mirror `agent/iteration_budget.py:23`.
  """
  @spec new(non_neg_integer()) :: t()
  def new(max_total \\ 90) when is_integer(max_total) and max_total >= 0 do
    %__MODULE__{max_total: max_total, used: 0}
  end

  @doc """
  Consumes one iteration.

  Returns `{:ok, budget}` when an iteration is available, otherwise
  `{:exhausted, budget}`. Matches `agent/iteration_budget.py:37-43`.
  """
  @spec consume(t()) :: {:ok, t()} | {:exhausted, t()}
  def consume(%__MODULE__{used: used, max_total: max_total} = budget)
      when used >= max_total do
    {:exhausted, budget}
  end

  def consume(%__MODULE__{used: used} = budget) do
    {:ok, %{budget | used: used + 1}}
  end

  @doc """
  Refunds one iteration, but never below zero.

  Matches `agent/iteration_budget.py:45-49`.
  """
  @spec refund(t()) :: t()
  def refund(%__MODULE__{used: 0} = budget), do: budget

  def refund(%__MODULE__{used: used} = budget) do
    %{budget | used: used - 1}
  end

  @doc """
  Remaining iterations, floored at zero.

  Matches `agent/iteration_budget.py:56-59`.
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{max_total: max_total, used: used}) do
    max(0, max_total - used)
  end

  @doc """
  Iterations already consumed.

  Matches `agent/iteration_budget.py:51-54`.
  """
  @spec used(t()) :: non_neg_integer()
  def used(%__MODULE__{used: used}), do: used
end
