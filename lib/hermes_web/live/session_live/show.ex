defmodule HermesWeb.SessionLive.Show do
  @moduledoc """
  Session detail view: message history, prompt input, and model/provider switching.
  """

  use HermesWeb, :live_view

  alias Hermes.Catalog
  alias Hermes.Sessions
  alias Hermes.Sessions.SessionServer
  alias Hermes.Sessions.Store

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermes.PubSub, "session:#{session_id}")
    end

    session = load_session(session_id)
    messages = Store.list_messages(session_id)
    providers = Catalog.list_providers()
    models = Catalog.list_models(to_string(session.provider))

    {:ok,
     assign(socket,
       session_id: session_id,
       session: session,
       messages: messages,
       streaming: nil,
       providers: providers,
       models: models,
       prompt: ""
     )}
  end

  @impl true
  def handle_event("send_prompt", params, socket) do
    text = prompt_text(params)

    if text == "" do
      {:noreply, socket}
    else
      session_id = socket.assigns.session_id

      case Sessions.run_turn_async(session_id, text) do
        :ok ->
          user_msg = %{role: "user", content: text, timestamp: System.system_time(:millisecond) / 1000.0}

          {:noreply,
           assign(socket,
             messages: socket.assigns.messages ++ [user_msg],
             streaming: "",
             prompt: ""
           )}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Session is not running")}
      end
    end
  end

  def handle_event("prompt_change", %{"prompt" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :prompt, text)}
  end

  def handle_event("provider_changed", %{"config" => %{"provider" => provider}}, socket) do
    models = Catalog.list_models(provider)
    model = List.first(models)[:model_id] || socket.assigns.session.model

    {:noreply,
     assign(socket,
       models: models,
       session: %{socket.assigns.session | provider: provider, model: model}
     )}
  end

  def handle_event("set_config", %{"config" => %{"provider" => provider, "model" => model}}, socket) do
    session_id = socket.assigns.session_id

    case SessionServer.set_config(session_id, %{"provider" => provider, "model" => model}) do
      {:ok, %{model: new_model, provider: new_provider}} ->
        session = %{socket.assigns.session | model: new_model, provider: new_provider}
        {:noreply, assign(socket, session: session)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Session is not running")}
    end
  end

  @impl true
  def handle_info({:stream_delta, text}, socket) do
    streaming = (socket.assigns.streaming || "") <> text
    {:noreply, assign(socket, :streaming, streaming)}
  end

  def handle_info({:turn_complete, _payload}, socket) do
    session_id = socket.assigns.session_id

    {:noreply,
     assign(socket,
       messages: Store.list_messages(session_id),
       streaming: nil,
       session: load_session(session_id)
     )}
  end

  def handle_info({:turn_error, %{error: error}}, socket) do
    error_msg = %{role: "error", content: to_string(error), timestamp: System.system_time(:millisecond) / 1000.0}

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [error_msg],
       streaming: nil,
       session: %{socket.assigns.session | status: :idle}
     )}
  end

  def handle_info({:session_config, %{model: model, provider: provider}}, socket) do
    session = %{socket.assigns.session | model: model, provider: provider}
    {:noreply, assign(socket, session: session, models: Catalog.list_models(to_string(provider)))}
  end

  def handle_info({:session_status, session_id, status}, socket) when session_id == socket.assigns.session_id do
    {:noreply, assign(socket, :session, %{socket.assigns.session | status: status})}
  end

  defp load_session(session_id) do
    case SessionServer.whereis(session_id) do
      nil ->
        persisted = List.first(Store.list_sessions() |> Enum.filter(&(&1.id == session_id)))

        case persisted do
          nil ->
            %{id: session_id, model: nil, provider: nil, status: :stopped, message_count: 0}

          s ->
            %{
              id: s.id,
              model: s.model,
              provider: Catalog.default_provider(),
              status: :stopped,
              message_count: s.message_count
            }
        end

      pid ->
        state = SessionServer.get_state(pid)

        %{
          id: state.session_id,
          model: state.model,
          provider: state.provider,
          status: state.status,
          message_count: length(state.messages)
        }
    end
  end

  defp prompt_text(%{"prompt" => %{"text" => text}}) when is_binary(text), do: String.trim(text)
  defp prompt_text(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp prompt_text(_), do: ""
end
