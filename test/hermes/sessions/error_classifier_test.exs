defmodule Hermes.Sessions.ErrorClassifierTest do
  @moduledoc """
  Tests for `Hermes.Sessions.ErrorClassifier.classify/1`.

  Asserts the retryable/non-retryable taxonomy and the `should_compress` flag
  for common provider failure modes.
  """

  use ExUnit.Case, async: true

  alias Hermes.Sessions.ErrorClassifier

  describe "classify/1" do
    test "HTTP 429 rate limit is retryable and not compressed" do
      assert %{
               reason: :rate_limit,
               retryable: true,
               should_compress: false
             } = ErrorClassifier.classify({:http_error, 429, "rate limit exceeded"})
    end

    test "HTTP 401 invalid API key is non-retryable auth" do
      assert %{
               reason: :auth,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify({:http_error, 401, "invalid api key"})
    end

    test "HTTP 500 server error is retryable" do
      assert %{
               reason: :server_error,
               retryable: true,
               should_compress: false
             } = ErrorClassifier.classify({:http_error, 500, "internal server error"})
    end

    test "context_length_exceeded message triggers context overflow with compression" do
      assert %{
               reason: :context_overflow,
               retryable: true,
               should_compress: true
             } = ErrorClassifier.classify("this is a context length exceeded error")
    end

    test "{:error, :timeout} is retryable timeout" do
      assert %{
               reason: :timeout,
               retryable: true,
               should_compress: false
             } = ErrorClassifier.classify({:error, :timeout})
    end

    test "insufficient credits message is non-retryable billing" do
      assert %{
               reason: :billing,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify("insufficient credits")
    end

    test "content_policy_violation message is non-retryable content policy" do
      assert %{
               reason: :content_policy_blocked,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify("this is a content policy violation")
    end

    test "unknown random string defaults to retryable unknown" do
      assert %{
               reason: :unknown,
               retryable: true,
               should_compress: false
             } = ErrorClassifier.classify("some random unknown failure")
    end

    test ":empty is non-retryable unknown" do
      assert %{
               reason: :unknown,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify(:empty)
    end

    test ":noproc is non-retryable" do
      assert %{
               reason: :unknown,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify(:noproc)
    end

    test "DBConnection.OwnershipError is non-retryable test setup" do
      exception = %DBConnection.OwnershipError{
        message: "cannot find ownership process for #PID<0.1.0>"
      }

      assert %{
               reason: :test_setup,
               retryable: false,
               should_compress: false
             } = ErrorClassifier.classify(exception)
    end
  end
end
