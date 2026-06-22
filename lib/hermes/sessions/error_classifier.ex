defmodule Hermes.Sessions.ErrorClassifier do
  @moduledoc """
  API error classification for smart recovery.

  Ports the taxonomy and priority pipeline from
  `hermes-agent/agent/error_classifier.py` to Elixir.

  Given an opaque error returned by a provider (a string, tuple, map, or
  exception), `classify/1` returns:

    * `:reason` — atom such as `:rate_limit`, `:server_error`, `:timeout`,
      `:context_overflow`, `:auth`, `:unknown`, etc.
    * `:retryable` — whether the turn loop should retry the call.
    * `:should_compress` — whether to run context compression before retrying.
    * `:message` — the most informative human-readable message available.

  The classifier is intentionally defensive: unknown errors default to
  `retryable: true` so transient glitches are retried with backoff rather
  than aborting the turn immediately.
  """


  @type classified :: %{
          reason: atom(),
          retryable: boolean(),
          should_compress: boolean(),
          message: String.t()
        }

  # ── Taxonomy atoms ────────────────────────────────────────────────────────
  #
  # Mirrors `FailoverReason` from agent/error_classifier.py.
  @reason_auth :auth
  @reason_billing :billing
  @reason_rate_limit :rate_limit
  @reason_overloaded :overloaded
  @reason_server_error :server_error
  @reason_timeout :timeout
  @reason_context_overflow :context_overflow
  @reason_payload_too_large :payload_too_large
  @reason_image_too_large :image_too_large
  @reason_model_not_found :model_not_found
  @reason_provider_policy_blocked :provider_policy_blocked
  @reason_content_policy_blocked :content_policy_blocked
  @reason_format_error :format_error
  @reason_thinking_signature :thinking_signature
  @reason_unknown :unknown

  # ── Message pattern lists ─────────────────────────────────────────────────

  @billing_patterns [
    "insufficient credits",
    "insufficient_quota",
    "insufficient balance",
    "credit balance",
    "credits exhausted",
    "credits have been exhausted",
    "no usable credits",
    "top up your credits",
    "payment required",
    "billing hard limit",
    "exceeded your current quota",
    "account is deactivated",
    "plan does not include",
    "out of funds",
    "run out of funds",
    "balance_depleted",
    "model_not_supported_on_free_tier",
    "not available on the free tier"
  ]

  @rate_limit_patterns [
    "rate limit",
    "rate_limit",
    "too many requests",
    "throttled",
    "requests per minute",
    "tokens per minute",
    "requests per day",
    "try again in",
    "please retry after",
    "resource_exhausted",
    "rate increased too quickly",
    "throttlingexception",
    "too many concurrent requests",
    "servicequotaexceededexception"
  ]

  @usage_limit_patterns [
    "usage limit",
    "quota",
    "limit exceeded",
    "key limit exceeded"
  ]

  @usage_limit_transient_signals [
    "try again",
    "retry",
    "resets at",
    "reset in",
    "wait",
    "requests remaining",
    "periodic",
    "window"
  ]

  @payload_too_large_patterns [
    "request entity too large",
    "payload too large",
    "error code: 413"
  ]

  @image_too_large_patterns [
    "image exceeds",
    "image too large",
    "image_too_large",
    "image size exceeds",
    "image dimensions exceed",
    "dimensions exceed max allowed size",
    "max allowed size: 8000"
  ]

  @context_overflow_patterns [
    "context length",
    "context size",
    "maximum context",
    "token limit",
    "too many tokens",
    "reduce the length",
    "exceeds the limit",
    "context window",
    "prompt is too long",
    "prompt exceeds max length",
    "max_tokens",
    "maximum number of tokens",
    "exceeds the max_model_len",
    "max_model_len",
    "prompt length",
    "input is too long",
    "maximum model length",
    "context length exceeded",
    "truncating input",
    "slot context",
    "n_ctx_slot",
    "超过最大长度",
    "上下文长度",
    "max input token",
    "input token",
    "exceeds the maximum number of input tokens"
  ]

  @model_not_found_patterns [
    "is not a valid model",
    "invalid model",
    "model not found",
    "model_not_found",
    "does not exist",
    "no such model",
    "unknown model",
    "unsupported model"
  ]

  @provider_policy_blocked_patterns [
    "no endpoints available matching your guardrail restrictions",
    "data policy"
  ]

  @auth_patterns [
    "invalid api key",
    "incorrect api key",
    "unauthorized",
    "authentication",
    "auth token",
    "access token",
    "invalid token",
    "credentials",
    "not authenticated"
  ]

  @content_policy_blocked_patterns [
    "content policy",
    "safety system",
    "flagged by",
    "usage policies",
    "violates our",
    "content filter",
    "moderation",
    "refusal",
    "blocked"
  ]

  @timeout_message_patterns [
    "timed out",
    "timeout",
    "time out",
    "read timeout",
    "connect timeout",
    "request timeout"
  ]

  @server_disconnect_patterns [
    "connection reset",
    "connection refused",
    "connection closed",
    "broken pipe",
    "remote end closed connection",
    "server closed connection",
    "unexpected eof",
    "eof occurred"
  ]

  @ssl_transient_patterns [
    "bad record mac",
    "ssl alert",
    "tls alert",
    "sslv3 alert",
    "handshake failure"
  ]

  @request_validation_patterns [
    "unknown parameter",
    "unsupported parameter",
    "invalid parameter",
    "unrecognized request argument",
    "error parsing grammar",
    "json-schema-to-grammar"
  ]

  @thinking_signature_patterns [
    "signature",
    "cannot be modified",
    "must remain as they were"
  ]

  @doc """
  Classify an API error.

  Accepts strings, tuples, maps, and exceptions. Returns a map with
  `:reason`, `:retryable`, `:should_compress`, and `:message`.
  """
  @spec classify(term()) :: classified()
  def classify(reason) do
    {status, error_msg, body} = extract(reason)
    error_code = extract_error_code(body)

    classified =
      classify_by_status(status, error_msg, error_code, body) ||
        classify_by_error_code(error_code, error_msg) ||
        classify_by_message(error_msg)

    case classified do
      nil -> unknown_result(error_message(reason))
      %{message: nil} = r -> %{r | message: error_message(reason)}
      r -> r
    end
  end

  # ── Extraction helpers ────────────────────────────────────────────────────

  defp extract({:http_error, status, body}) when is_integer(status) do
    {status, to_string(body), parse_body(body)}
  end

  defp extract(%{status: status, body: body}) when is_integer(status) do
    {status, body_to_message(body), parse_body(body)}
  end

  defp extract(%{"status" => status, "body" => body}) when is_integer(status) do
    {status, body_to_message(body), parse_body(body)}
  end

  defp extract(%{status: status} = reason) when is_integer(status) do
    {status, error_message(reason), nil}
  end

  defp extract(%{"status" => status} = reason) when is_integer(status) do
    {status, error_message(reason), nil}
  end

  defp extract(%{reason: reason} = err) when is_atom(reason) do
    {nil, error_message(err), nil}
  end

  defp extract(reason) when is_binary(reason) do
    {nil, reason, nil}
  end

  defp extract(reason) when is_atom(reason) do
    {nil, Atom.to_string(reason), nil}
  end

  defp extract(reason) when is_tuple(reason) do
    {nil, error_message(reason), nil}
  end

  defp extract(reason) do
    {nil, error_message(reason), nil}
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp error_message(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp error_message(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(%{reason: reason}) when is_binary(reason), do: reason

  defp error_message(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&to_message/1)
    |> Enum.join(" ")
  end

  defp error_message(reason), do: inspect(reason, limit: 500)

  defp to_message(item) when is_binary(item), do: item
  defp to_message(item) when is_atom(item), do: Atom.to_string(item)
  defp to_message(item), do: inspect(item, limit: 200)

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp parse_body(body) when is_map(body), do: body
  defp parse_body(_), do: nil

  defp body_to_message(nil), do: ""
  defp body_to_message(body) when is_binary(body), do: body
  defp body_to_message(body), do: inspect(body, limit: 500)

  defp extract_error_code(nil), do: ""

  defp extract_error_code(body) when is_map(body) do
    code =
      body["error_code"] ||
        get_in(body, ["error", "code"]) ||
        get_in(body, ["error", "type"]) ||
        body["code"]

    if is_binary(code) or is_atom(code), do: to_string(code), else: ""
  end


  # ── Status code classification ────────────────────────────────────────────

  defp classify_by_status(nil, _error_msg, _error_code, _body), do: nil

  defp classify_by_status(401, _error_msg, _error_code, _body) do
    result(@reason_auth, retryable: false)
  end

  defp classify_by_status(403, error_msg, _error_code, _body) do
    if billing?(error_msg) do
      result(@reason_billing, retryable: false)
    else
      result(@reason_auth, retryable: false)
    end
  end

  defp classify_by_status(402, error_msg, _error_code, _body) do
    if usage_limit_transient?(error_msg) do
      result(@reason_rate_limit, retryable: true)
    else
      result(@reason_billing, retryable: false)
    end
  end

  defp classify_by_status(404, error_msg, _error_code, _body) do
    cond do
      billing?(error_msg) ->
        result(@reason_billing, retryable: false)

      policy_blocked?(error_msg) ->
        result(@reason_provider_policy_blocked, retryable: false)

      model_not_found?(error_msg) ->
        result(@reason_model_not_found, retryable: false)

      true ->
        result(@reason_unknown, retryable: true)
    end
  end

  defp classify_by_status(413, _error_msg, _error_code, _body) do
    result(@reason_payload_too_large, retryable: true, should_compress: true)
  end

  defp classify_by_status(429, error_msg, _error_code, _body) do
    if long_context_tier?(error_msg) do
      result(@reason_context_overflow, retryable: true, should_compress: true)
    else
      result(@reason_rate_limit, retryable: true)
    end
  end

  defp classify_by_status(400, error_msg, error_code, body) do
    classify_400(error_msg, error_code, body)
  end

  defp classify_by_status(status, error_msg, error_code, _body)
       when status in [500, 502] do
    if request_validation?(error_msg) or error_code in ["invalid_request_error"] do
      result(@reason_format_error, retryable: false)
    else
      result(@reason_server_error, retryable: true)
    end
  end

  defp classify_by_status(status, _error_msg, _error_code, _body)
       when status in [503, 529] do
    result(@reason_overloaded, retryable: true)
  end

  defp classify_by_status(status, _error_msg, _error_code, _body)
       when is_integer(status) and status >= 400 and status < 500 do
    result(@reason_format_error, retryable: false)
  end

  defp classify_by_status(status, _error_msg, _error_code, _body)
       when is_integer(status) and status >= 500 and status < 600 do
    result(@reason_server_error, retryable: true)
  end

  defp classify_by_status(_status, _error_msg, _error_code, _body), do: nil

  defp classify_400(error_msg, error_code, body) do
    cond do
      thinking_signature?(error_msg) ->
        result(@reason_thinking_signature, retryable: true)

      long_context_beta_forbidden?(error_msg) ->
        result(@reason_context_overflow, retryable: true, should_compress: true)

      request_validation?(error_msg) or error_code in ["unknown_parameter", "unsupported_parameter"] ->
        result(@reason_format_error, retryable: false)

      image_too_large?(error_msg) ->
        result(@reason_image_too_large, retryable: true)

      context_overflow?(error_msg) ->
        result(@reason_context_overflow, retryable: true, should_compress: true)

      policy_blocked?(error_msg) ->
        result(@reason_provider_policy_blocked, retryable: false)

      model_not_found?(error_msg) ->
        result(@reason_model_not_found, retryable: false)

      rate_limit?(error_msg) ->
        result(@reason_rate_limit, retryable: true)

      billing?(error_msg) ->
        result(@reason_billing, retryable: false)

      content_policy_blocked?(error_msg) ->
        result(@reason_content_policy_blocked, retryable: false)

      generic_context_overflow?(error_msg, body) ->
        result(@reason_context_overflow, retryable: true, should_compress: true)

      true ->
        result(@reason_format_error, retryable: false)
    end
  end

  # ── Error code classification ─────────────────────────────────────────────

  defp classify_by_error_code("", _error_msg), do: nil

  defp classify_by_error_code(code, _error_msg) when is_binary(code) do
    code_lower = String.downcase(code)

    cond do
      code_lower in ["resource_exhausted", "throttled", "rate_limit_exceeded"] ->
        result(@reason_rate_limit, retryable: true)

      code_lower in [
        "insufficient_quota",
        "billing_not_active",
        "payment_required",
        "insufficient_credits",
        "no_usable_credits",
        "balance_depleted",
        "model_not_supported_on_free_tier"
      ] ->
        result(@reason_billing, retryable: false)

      code_lower in ["model_not_found", "model_not_available", "invalid_model"] ->
        result(@reason_model_not_found, retryable: false)

      code_lower in ["context_length_exceeded", "max_tokens_exceeded"] ->
        result(@reason_context_overflow, retryable: true, should_compress: true)

      true ->
        nil
    end
  end

  # ── Message pattern classification ────────────────────────────────────────

  defp classify_by_message(error_msg) do
    cond do
      payload_too_large?(error_msg) ->
        result(@reason_payload_too_large, retryable: true, should_compress: true)

      image_too_large?(error_msg) ->
        result(@reason_image_too_large, retryable: true)

      usage_limit?(error_msg) ->
        if usage_limit_transient?(error_msg) do
          result(@reason_rate_limit, retryable: true)
        else
          result(@reason_billing, retryable: false)
        end

      billing?(error_msg) ->
        result(@reason_billing, retryable: false)

      rate_limit?(error_msg) ->
        result(@reason_rate_limit, retryable: true)

      content_policy_blocked?(error_msg) ->
        result(@reason_content_policy_blocked, retryable: false)

      context_overflow?(error_msg) ->
        result(@reason_context_overflow, retryable: true, should_compress: true)

      auth?(error_msg) ->
        result(@reason_auth, retryable: false)

      policy_blocked?(error_msg) ->
        result(@reason_provider_policy_blocked, retryable: false)

      model_not_found?(error_msg) ->
        result(@reason_model_not_found, retryable: false)

      timeout?(error_msg) ->
        result(@reason_timeout, retryable: true)

      ssl_transient?(error_msg) ->
        result(@reason_timeout, retryable: true)

      server_disconnect?(error_msg) ->
        result(@reason_timeout, retryable: true)

      true ->
        nil
    end
  end

  # ── Pattern predicates ──────────────────────────────────────────────────

  defp matches_any?(text, patterns) when is_binary(text) do
    Enum.any?(patterns, &String.contains?(text, &1))
  end

  defp matches_any?(_text, _patterns), do: false

  defp billing?(text), do: matches_any?(text, @billing_patterns)
  defp rate_limit?(text), do: matches_any?(text, @rate_limit_patterns)
  defp usage_limit?(text), do: matches_any?(text, @usage_limit_patterns)

  defp usage_limit_transient?(text) do
    usage_limit?(text) and matches_any?(text, @usage_limit_transient_signals)
  end

  defp payload_too_large?(text), do: matches_any?(text, @payload_too_large_patterns)
  defp image_too_large?(text), do: matches_any?(text, @image_too_large_patterns)
  defp context_overflow?(text), do: matches_any?(text, @context_overflow_patterns)
  defp model_not_found?(text), do: matches_any?(text, @model_not_found_patterns)
  defp policy_blocked?(text), do: matches_any?(text, @provider_policy_blocked_patterns)
  defp auth?(text), do: matches_any?(text, @auth_patterns)
  defp content_policy_blocked?(text), do: matches_any?(text, @content_policy_blocked_patterns)
  defp timeout?(text), do: matches_any?(text, @timeout_message_patterns)
  defp server_disconnect?(text), do: matches_any?(text, @server_disconnect_patterns)
  defp ssl_transient?(text), do: matches_any?(text, @ssl_transient_patterns)
  defp request_validation?(text), do: matches_any?(text, @request_validation_patterns)

  defp long_context_tier?(text) do
    is_binary(text) and
      String.contains?(text, "extra usage") and
      String.contains?(text, "long context")
  end

  defp long_context_beta_forbidden?(text) do
    is_binary(text) and
      String.contains?(text, "long context beta") and
      String.contains?(text, "not yet available")
  end

  defp thinking_signature?(text) do
    is_binary(text) and
      String.contains?(text, "thinking") and
      matches_any?(text, @thinking_signature_patterns)
  end

  defp generic_context_overflow?(error_msg, body) when is_binary(error_msg) do
    body_msg = body_message(body)
    is_generic_body?(body_msg) and context_overflow?(error_msg)
  end

  defp generic_context_overflow?(_error_msg, _body), do: false

  defp body_message(nil), do: ""

  defp body_message(body) when is_map(body) do
    get_in(body, ["error", "message"]) ||
      body["message"] ||
      ""
  end

  defp body_message(_), do: ""

  defp is_generic_body?(text) when is_binary(text) do
    trimmed = String.trim(text)
    trimmed == "" or trimmed == "error" or String.length(trimmed) < 30
  end

  defp is_generic_body?(_), do: false

  # ── Result builders ───────────────────────────────────────────────────────

  defp result(reason, opts) do
    %{
      reason: reason,
      retryable: Keyword.get(opts, :retryable, true),
      should_compress: Keyword.get(opts, :should_compress, false),
      message: Keyword.get(opts, :message, nil)
    }
  end

  defp unknown_result(message) do
    result(@reason_unknown, retryable: true, message: message)
  end
end
