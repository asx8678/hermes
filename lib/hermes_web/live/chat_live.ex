defmodule HermesWeb.ChatLive do
  @moduledoc """
  Full-page chat interface using Phoenix PubSub for real-time session updates.

  Lists all sessions, lets the user create or select one, and renders the
  conversation history with streaming assistant responses.
  """

  use HermesWeb, :live_view

  alias Hermes.Sessions
  alias Hermes.Sessions.Store

  require Logger

  @pubsub_sessions_topic "sessions"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, @pubsub_sessions_topic)
    end

    sessions = list_sessions()
    first_session = List.first(sessions)

    socket =
      socket
      |> assign(:sessions, sessions)
      |> assign(:selected_session, first_session)
      |> assign(:messages, load_messages(first_session))
      |> assign(:streaming, nil)
      |> assign(:prompt, "")
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_session", %{"id" => session_id}, socket) do
    session = Enum.find(socket.assigns.sessions, &(&1.id == session_id))

    socket =
      socket
      |> assign(:selected_session, session)
      |> assign(:messages, load_messages(session))
      |> assign(:streaming, nil)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket) do
    opts = [provider: default_provider(), model: default_model()]

    case Sessions.start_session(opts) do
      {:ok, _pid, session_id} ->
        session = %{
          id: session_id,
          model: default_model(),
          provider: default_provider(),
          status: :idle,
          message_count: 0
        }

        socket =
          socket
          |> assign(:sessions, [session | socket.assigns.sessions])
          |> assign(:selected_session, session)
          |> assign(:messages, [])
          |> assign(:streaming, nil)
          |> assign(:prompt, "")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to start session: #{inspect(reason)}")
         |> assign(:error, inspect(reason))}
    end
  end

  def handle_event("send_prompt", params, socket) do
    text = prompt_text(params)

    if text == "" do
      {:noreply, socket}
    else
      session = socket.assigns.selected_session

      if session == nil do
        {:noreply,
         socket
         |> put_flash(:error, "No session selected")
         |> assign(:error, "no session selected")}
      else
        case Sessions.run_turn_async(session.id, text) do
          :ok ->
            user_msg = %{
              role: "user",
              content: text,
              timestamp: System.system_time(:millisecond) / 1000.0
            }

            messages = socket.assigns.messages ++ [user_msg]

            {:noreply,
             socket
             |> assign(:messages, messages)
             |> assign(:streaming, "")
             |> assign(:prompt, "")
             |> assign(:error, nil)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Session is not running")
             |> assign(:error, "session not found")}
        end
      end
    end
  end

  def handle_event("prompt_change", %{"prompt" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :prompt, text)}
  end

  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  @impl true
  def handle_info({:session_started, session}, socket) do
    sessions = merge_session(socket.assigns.sessions, session)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info({:session_stopped, session_id}, socket) do
    sessions = Enum.reject(socket.assigns.sessions, &(&1.id == session_id))

    socket =
      if socket.assigns.selected_session && socket.assigns.selected_session.id == session_id do
        first = List.first(sessions)

        socket
        |> assign(:selected_session, first)
        |> assign(:messages, load_messages(first))
        |> assign(:streaming, nil)
      else
        assign(socket, :sessions, sessions)
      end

    {:noreply, socket}
  end

  def handle_info({:session_status, session_id, status}, socket) do
    sessions =
      Enum.map(socket.assigns.sessions, fn s ->
        if s.id == session_id do
          %{s | status: status}
        else
          s
        end
      end)

    socket = assign(socket, :sessions, sessions)

    socket =
      if socket.assigns.selected_session && socket.assigns.selected_session.id == session_id do
        assign(socket, :selected_session, %{socket.assigns.selected_session | status: status})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:stream_delta, text}, socket) do
    {:noreply, assign(socket, :streaming, (socket.assigns.streaming || "") <> text)}
  end

  def handle_info({:turn_complete, %{session_id: session_id} = payload}, socket) do
    messages = load_messages(session_id)

    socket =
      socket
      |> assign(:streaming, nil)
      |> assign(:messages, messages)
      |> refresh_session_in_list(session_id, payload)

    {:noreply, socket}
  end

  def handle_info({:turn_error, %{session_id: session_id} = payload}, socket) do
    error = Map.get(payload, :error) || Map.get(payload, "error") || "turn failed"

    socket =
      socket
      |> assign(:streaming, nil)
      |> assign(:error, error)
      |> refresh_session_in_list(session_id, payload)

    {:noreply, socket}
  end

  def handle_info(
        {:session_config, %{session_id: session_id, model: model, provider: provider}},
        socket
      ) do
    sessions =
      Enum.map(socket.assigns.sessions, fn s ->
        if s.id == session_id do
          %{s | model: model, provider: provider}
        else
          s
        end
      end)

    socket = assign(socket, :sessions, sessions)

    socket =
      if socket.assigns.selected_session && socket.assigns.selected_session.id == session_id do
        assign(socket, :selected_session, %{
          socket.assigns.selected_session
          | model: model,
            provider: provider
        })
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp list_sessions do
    Sessions.list_all()
    |> Enum.map(fn s ->
      %{
        id: s.id,
        model: s.model,
        provider: s.provider,
        status: Map.get(s, :status, :idle),
        message_count: Map.get(s, :message_count, 0)
      }
    end)
    |> Enum.sort_by(& &1.message_count, :desc)
  end

  defp load_messages(%{id: session_id}) when is_binary(session_id) do
    load_messages(session_id)
  end

  defp load_messages(nil), do: []

  defp load_messages(session_id) when is_binary(session_id) do
    case Store.list_messages(session_id) do
      {:error, reason} ->
        Logger.warning("ChatLive failed to list messages for #{session_id}: #{reason}")
        []

      messages ->
        messages
    end
  end

  defp prompt_text(%{"prompt" => %{"text" => text}}) when is_binary(text), do: String.trim(text)
  defp prompt_text(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp prompt_text(_), do: ""

  defp merge_session(sessions, session) do
    existing = Enum.find_index(sessions, &(&1.id == session.id))

    entry = %{
      id: session.id,
      model: Map.get(session, :model, default_model()),
      provider: Map.get(session, :provider, default_provider()),
      status: Map.get(session, :status, :idle),
      message_count: Map.get(session, :message_count, 0)
    }

    if existing do
      List.replace_at(sessions, existing, entry)
    else
      [entry | sessions]
    end
  end

  defp refresh_session_in_list(socket, session_id, payload) do
    sessions = socket.assigns.sessions

    case Enum.find_index(sessions, &(&1.id == session_id)) do
      nil ->
        socket

      idx ->
        session = Enum.at(sessions, idx)

        message_count =
          Map.get(payload, :message_count, session.message_count) || session.message_count

        updated = %{session | message_count: message_count}
        assign(socket, :sessions, List.replace_at(sessions, idx, updated))
    end
  end

  defp default_provider do
    Application.get_env(:hermes, :default_provider, "anthropic")
  end

  defp default_model do
    Application.get_env(:hermes, :default_model, "claude-sonnet-4-20250514")
  end
end
