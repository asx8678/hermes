defmodule HermesWeb.AnalyticsLive do
  @moduledoc """
  LiveView dashboard for session usage analytics.
  """

  use HermesWeb, :live_view

  require Logger

  @default_limit 1000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:limit, @default_limit)
      |> assign(:sessions, [])
      |> assign(:totals, %{
        total_sessions: 0,
        total_messages: 0,
        total_tokens: 0,
        total_cost: 0.0
      })
      |> assign(:by_provider, [])
      |> assign(:by_model, [])
      |> assign(:missing_fields, [])
      |> refresh_analytics()

    {:ok, socket}
  end

  @impl true
  def handle_event("set_limit", %{"limit" => limit}, socket) do
    limit =
      case Integer.parse(limit) do
        {n, _} when n > 0 -> min(n, 10_000)
        _ -> @default_limit
      end

    socket =
      socket
      |> assign(:limit, limit)
      |> refresh_analytics()

    {:noreply, socket}
  end

  def handle_event("set_limit", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_analytics(socket)}
  end

  @impl true
  def handle_info({:analytics_refresh}, socket) do
    {:noreply, refresh_analytics(socket)}
  end

  defp refresh_analytics(socket) do
    limit = socket.assigns.limit

    sessions =
      case Hermes.Sessions.Store.list_sessions(limit) do
        {:error, reason} ->
          Logger.warning("AnalyticsLive failed to list sessions: #{reason}")
          []

        sessions ->
          sessions
      end

    missing_fields = detect_missing_fields(sessions)

    totals = %{
      total_sessions: length(sessions),
      total_messages: Enum.sum(Enum.map(sessions, &to_number(&1.message_count, 0))),
      total_tokens: Enum.sum(Enum.map(sessions, &to_number(Map.get(&1, :token_count, 0), 0))),
      total_cost:
        Enum.sum(Enum.map(sessions, &to_float(Map.get(&1, :estimated_cost_usd, 0.0), 0.0)))
    }

    by_provider =
      group_by_key(
        sessions,
        :provider,
        totals.total_messages,
        totals.total_tokens,
        totals.total_cost
      )

    by_model =
      group_by_key(
        sessions,
        :model,
        totals.total_messages,
        totals.total_tokens,
        totals.total_cost
      )

    socket
    |> assign(:sessions, sessions)
    |> assign(:totals, totals)
    |> assign(:by_provider, by_provider)
    |> assign(:by_model, by_model)
    |> assign(:missing_fields, missing_fields)
  end

  defp detect_missing_fields(sessions) do
    [] = []

    has_token = Enum.any?(sessions, &Map.has_key?(&1, :token_count))
    has_cost = Enum.any?(sessions, &Map.has_key?(&1, :estimated_cost_usd))

    missing = []
    missing = if has_token, do: missing, else: [:token_count | missing]
    missing = if has_cost, do: missing, else: [:estimated_cost_usd | missing]
    missing
  end

  defp group_by_key(sessions, key, total_messages, total_tokens, total_cost) do
    sessions
    |> Enum.group_by(&Map.get(&1, key, "unknown"))
    |> Enum.map(fn {name, items} ->
      messages = Enum.sum(Enum.map(items, &to_number(&1.message_count, 0)))
      tokens = Enum.sum(Enum.map(items, &to_number(Map.get(&1, :token_count, 0), 0)))
      cost = Enum.sum(Enum.map(items, &to_float(Map.get(&1, :estimated_cost_usd, 0.0), 0.0)))

      %{
        name: to_string(name),
        sessions: length(items),
        messages: messages,
        tokens: tokens,
        cost: cost,
        message_pct: percent(messages, total_messages),
        token_pct: percent(tokens, total_tokens),
        cost_pct: percent(cost, total_cost)
      }
    end)
    |> Enum.sort_by(& &1.messages, :desc)
  end

  defp to_number(nil, default), do: default
  defp to_number(value, _default) when is_integer(value), do: value
  defp to_number(value, _default) when is_float(value), do: round(value)

  defp to_number(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_number(_, default), do: default

  defp to_float(nil, default), do: default
  defp to_float(value, _) when is_float(value), do: value
  defp to_float(value, _) when is_integer(value), do: value / 1

  defp to_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> default
    end
  end

  defp to_float(_, default), do: default

  defp percent(_part, 0), do: 0.0
  defp percent(part, total), do: Float.round(part / total * 100, 2)
end
