defmodule Hermes.Sessions.IterationBudgetTest do
  @moduledoc """
  Tests for `Hermes.Sessions.IterationBudget`.

  Ports the behavior exercised by `agent/iteration_budget.py:17-62`.
  """

  use ExUnit.Case, async: true

  alias Hermes.Sessions.IterationBudget

  describe "new/1" do
    test "defaults to 90 total iterations" do
      budget = IterationBudget.new()
      assert budget.max_total == 90
      assert budget.used == 0
    end

    test "accepts a custom max_total" do
      budget = IterationBudget.new(5)
      assert budget.max_total == 5
      assert budget.used == 0
    end
  end

  describe "consume/1" do
    test "increments used while budget remains" do
      budget = IterationBudget.new(2)

      assert {:ok, budget} = IterationBudget.consume(budget)
      assert budget.used == 1

      assert {:ok, budget} = IterationBudget.consume(budget)
      assert budget.used == 2

      assert {:exhausted, budget} = IterationBudget.consume(budget)
      assert budget.used == 2
    end
  end

  describe "refund/1" do
    test "decrements used but never below zero" do
      budget = IterationBudget.new(2)

      {:ok, budget} = IterationBudget.consume(budget)
      assert budget.used == 1

      budget = IterationBudget.refund(budget)
      assert budget.used == 0

      budget = IterationBudget.refund(budget)
      assert budget.used == 0
    end
  end

  describe "remaining/1" do
    test "returns max_total - used floored at zero" do
      budget = IterationBudget.new(3)

      assert IterationBudget.remaining(budget) == 3

      {:ok, budget} = IterationBudget.consume(budget)
      assert IterationBudget.remaining(budget) == 2

      {:ok, budget} = IterationBudget.consume(budget)
      {:ok, budget} = IterationBudget.consume(budget)
      assert IterationBudget.remaining(budget) == 0
      assert IterationBudget.consume(budget) == {:exhausted, budget}
    end
  end

  describe "used/1" do
    test "returns the used count" do
      budget = IterationBudget.new(5)
      assert IterationBudget.used(budget) == 0

      {:ok, budget} = IterationBudget.consume(budget)
      assert IterationBudget.used(budget) == 1
    end
  end
end
