defmodule Hermes.Tools.BrowserSidecar do
  @moduledoc """
  CDP-backed browser sidecar state.

  Maintains the current page URL, pending dialogs, and console log.  The actual
  CDP commands are sent as HTTP requests to `browser_cdp_url` by the tool module;
  this GenServer only holds mutable session state so multiple tool invocations in
  the same session see a consistent view.
  """

  use GenServer

  @name __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Returns the configured CDP endpoint or nil.
  """
  @spec cdp_url() :: String.t() | nil
  def cdp_url do
    env = System.get_env("BROWSER_CDP_URL")
    config = Application.get_env(:hermes, :browser_cdp_url)
    (env || config) |> maybe_trim()
  end

  @doc """
  Updates the current page URL stored in the sidecar.
  """
  @spec set_url(String.t()) :: :ok
  def set_url(url) do
    GenServer.call(@name, {:set_url, url})
  end

  @doc """
  Returns the current page URL.
  """
  @spec get_url() :: String.t()
  def get_url do
    GenServer.call(@name, :get_url)
  end

  @doc """
  Adds console messages to the buffer.
  """
  @spec add_console_messages([map()]) :: :ok
  def add_console_messages(messages) do
    GenServer.call(@name, {:add_console, messages})
  end

  @doc """
  Returns and optionally clears buffered console messages.
  """
  @spec console_messages(boolean()) :: [map()]
  def console_messages(clear \\ false) do
    GenServer.call(@name, {:console, clear})
  end

  @doc """
  Records a pending JavaScript dialog.
  """
  @spec add_dialog(map()) :: :ok
  def add_dialog(dialog) do
    GenServer.call(@name, {:add_dialog, dialog})
  end

  @doc """
  Removes a pending dialog by id.
  """
  @spec remove_dialog(String.t()) :: :ok
  def remove_dialog(dialog_id) do
    GenServer.call(@name, {:remove_dialog, dialog_id})
  end

  @doc """
  Returns pending dialogs.
  """
  @spec pending_dialogs() :: [map()]
  def pending_dialogs do
    GenServer.call(@name, :pending_dialogs)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{url: nil, console: [], dialogs: []}}
  end

  @impl true
  def handle_call({:set_url, url}, _from, state) do
    {:reply, :ok, %{state | url: url}}
  end

  @impl true
  def handle_call(:get_url, _from, state) do
    {:reply, state.url, state}
  end

  @impl true
  def handle_call({:add_console, messages}, _from, state) do
    {:reply, :ok, %{state | console: state.console ++ messages}}
  end

  @impl true
  def handle_call({:console, true}, _from, state) do
    {:reply, state.console, %{state | console: []}}
  end

  @impl true
  def handle_call({:console, false}, _from, state) do
    {:reply, state.console, state}
  end

  @impl true
  def handle_call({:add_dialog, dialog}, _from, state) do
    {:reply, :ok, %{state | dialogs: state.dialogs ++ [dialog]}}
  end

  @impl true
  def handle_call({:remove_dialog, dialog_id}, _from, state) do
    {:reply, :ok, %{state | dialogs: Enum.reject(state.dialogs, &(&1["id"] == dialog_id))}}
  end

  @impl true
  def handle_call(:pending_dialogs, _from, state) do
    {:reply, state.dialogs, state}
  end

  defp maybe_trim(nil), do: nil
  defp maybe_trim(url), do: String.trim(url)
end
