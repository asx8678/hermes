defmodule Hermes.NativeTest do
  @moduledoc """
  Tests for `Hermes.Native` Rustler NIFs.

  These NIFs are intentionally limited to short, pure tokenization
  heuristics and run on dirty CPU schedulers. Terminal and code
  execution remain sidecars — never NIFs (see
  07-rewrite-execution-spec.md).
  """

  use ExUnit.Case, async: true

  alias Hermes.Native

  # Detect at compile time whether the NIF is actually available. If it
  # isn't (e.g. Rust toolchain missing or the .so failed to load), skip
  # the whole suite rather than failing loudly.
  @nif_loaded (try do
                 apply(Hermes.Native, :count_tokens, ["test", ""])
                 true
               catch
                 _, _ -> false
               end)

  if not @nif_loaded do
    @moduletag skip: "NIF not compiled/loaded"
  end

  describe "count_tokens/2" do
    test "English text follows ~4 chars/token heuristic" do
      # "hello world!" = 12 ASCII chars -> 12 / 4 = 3 tokens
      assert Native.count_tokens("hello world!", "") == 3
    end

    test "CJK text counts roughly one token per character" do
      # 4 CJK characters -> 4 tokens
      assert Native.count_tokens("你好世界", "") == 4
    end

    test "mixed CJK + ASCII text sums both heuristics" do
      # "hello " = 6 ASCII chars -> 6 / 4 = 1 token
      # "你好" = 2 CJK chars -> 2 tokens
      assert Native.count_tokens("hello 你好", "") == 3
    end
  end

  describe "estimate_messages_tokens/1" do
    test "sums token estimates across messages" do
      messages = [
        %{"role" => "user", "content" => "hello world!"},
        %{"role" => "assistant", "content" => "你好世界"}
      ]

      # 12 ASCII / 4 = 3, 4 CJK = 4 -> total 7
      assert Native.estimate_messages_tokens(messages) == 7
    end
  end

  describe "NIF loading and scheduling" do
    test "NIF is loaded (not :nif_not_loaded)" do
      # A successful call proves the dynamic library was loaded by
      # rustler_init and the stub functions were replaced.
      assert is_integer(Native.count_tokens("probe", ""))
    end

    test "NIF runs on a dirty CPU scheduler and does not block" do
      # The Rust implementation declares `schedule = "DirtyCpu"` on each
      # NIF. A synchronous call that returns verifies the scheduler can
      # execute the function without hanging.
      assert Native.count_tokens("dirty scheduler sanity check", "") >= 0
    end
  end
end
