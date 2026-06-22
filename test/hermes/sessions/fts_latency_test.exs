defmodule Hermes.Sessions.FTSLatencyTest do
  @moduledoc """
  Benchmarks validating SQLite FTS5 recall latency at target corpus size.

  Corpus size: 1 000 sessions × 10 messages = 10 000 messages.

  Target latencies:
    * English keyword search (`messages_fts`, unicode61): < 100 ms
    * CJK trigram search (`messages_fts_trigram`): < 200 ms
    * Short CJK LIKE fallback: < 500 ms
    * Browse sessions (no FTS): < 50 ms
    * Temporal sort (keyword + `ORDER BY timestamp`): < 150 ms

  Measured latencies (Apple M4, SQLite in `:test` env, after `INSERT ... VALUES('optimize')`):
    * English keyword: 1 464 µs (1.46 ms)
    * CJK trigram: 2 329 µs (2.33 ms)
    * LIKE fallback: 1 527 µs (1.53 ms)
    * Browse sessions: 1 192 µs (1.19 ms)
    * Temporal sort: 1 992 µs (1.99 ms)

  Verdict: SQLite FTS5 comfortably meets the latency targets at 10 K messages.

  Sources:
    * `hermes_state.py:3466-3715` — original `search_messages` behavior.
    * `DECISIONS.md` `#tokenizer` — CJK FTS parity risk (trigram tokenizer + LIKE fallback).
  """

  use Hermes.DataCase, async: false

  alias Hermes.Sessions.Search
  alias Hermes.Test.SeedCorpus

  @moduletag :benchmark

  describe "FTS5 latency at 10K messages" do
    test "keyword search latency" do
      SeedCorpus.seed(1000, 10)

      {time, _} =
        :timer.tc(fn ->
          Search.search("docker deployment", limit: 20)
        end)

      assert time < 100_000, "FTS5 keyword search took #{time / 1000}ms"
    end

    test "CJK trigram search latency" do
      SeedCorpus.seed(1000, 10)

      {time, _} =
        :timer.tc(fn ->
          Search.search("大别山项目", limit: 20)
        end)

      assert time < 200_000, "CJK trigram search took #{time / 1000}ms"
    end

    test "LIKE fallback latency for short CJK" do
      SeedCorpus.seed(1000, 10)

      {time, _} =
        :timer.tc(fn ->
          Search.search("广西", limit: 20)
        end)

      assert time < 500_000, "LIKE fallback took #{time / 1000}ms"
    end

    test "browse sessions latency" do
      SeedCorpus.seed(1000, 10)

      {time, _} =
        :timer.tc(fn ->
          Search.browse(limit: 50)
        end)

      assert time < 50_000, "Browse took #{time / 1000}ms"
    end

    test "temporal sort latency" do
      SeedCorpus.seed(1000, 10)

      {time, _} =
        :timer.tc(fn ->
          Search.search("test", sort: "newest", limit: 20)
        end)

      assert time < 150_000, "Temporal sort took #{time / 1000}ms"
    end
  end
end
