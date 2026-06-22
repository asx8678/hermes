defmodule Hermes.Providers.Types do
  @moduledoc """
  Shared structs for normalized provider responses.

  Ported from Python `agent/transports/types.py:18-144`.
  The shared surface is intentionally minimal — only fields that every
  downstream consumer reads are top-level. Protocol-specific state goes in
  `provider_data` so that protocol-aware code paths can access it without
  polluting the shared type.
  """

  defmodule ToolCall do
    @moduledoc """
    A normalized tool call from any provider.

    Ported from `agent/transports/types.py:18-77`.
    """

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: String.t(),
            arguments: String.t(),
            provider_data: map() | nil
          }

    defstruct [:id, :name, :arguments, :provider_data]

    @spec new(keyword()) :: t()
    def new(opts \\ []) do
      arguments =
        case Keyword.get(opts, :arguments) do
          args when is_map(args) -> Jason.encode!(args)
          args when is_binary(args) -> args
          nil -> "{}"
        end

      struct!(__MODULE__, Keyword.put(opts, :arguments, arguments))
    end
  end

  defmodule Usage do
    @moduledoc """
    Token usage from an API response.

    Ported from `agent/transports/types.py:79-87`.
    """

    @type t :: %__MODULE__{
            input_tokens: integer(),
            output_tokens: integer(),
            cached_tokens: integer()
          }

    defstruct input_tokens: 0, output_tokens: 0, cached_tokens: 0
  end

  defmodule NormalizedResponse do
    @moduledoc """
    Normalized API response from any provider.

    Ported from `agent/transports/types.py:89-144`.
    """

    @type t :: %__MODULE__{
            content: String.t() | nil,
            tool_calls: [ToolCall.t()] | nil,
            finish_reason: String.t(),
            reasoning: String.t() | nil,
            usage: Usage.t() | nil,
            provider_data: map() | nil
          }

    defstruct [
      :content,
      :tool_calls,
      :finish_reason,
      :reasoning,
      :usage,
      :provider_data
    ]
  end
end
