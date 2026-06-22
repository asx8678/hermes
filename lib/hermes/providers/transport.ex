defmodule Hermes.Providers.Transport do
  @moduledoc """
  Behaviour for provider transports.

  A transport owns the data path for one `api_mode`:
  `convert_messages` → `convert_tools` → `build_kwargs` → `normalize_response`.

  It does NOT own: client construction, streaming, credential refresh,
  prompt caching, interrupt handling, or retry logic.

  Ported from Python `agent/transports/base.py:16-89`.
  """

  alias Hermes.Providers.Types.NormalizedResponse

  @callback api_mode() :: String.t()

  @callback convert_messages(messages :: [map()], opts :: keyword()) :: any()

  @callback convert_tools(tools :: [map()]) :: any()

  @callback build_kwargs(
              model :: String.t(),
              messages :: [map()],
              tools :: [map()] | nil,
              params :: keyword()
            ) :: map()

  @callback normalize_response(response :: map(), opts :: keyword()) :: NormalizedResponse.t()

  @callback validate_response(response :: map()) :: boolean()

  @callback map_finish_reason(raw_reason :: String.t() | nil) :: String.t()
end
