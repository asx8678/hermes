defmodule HermesWeb.SessionLiveTest do
  use HermesWeb.ConnCase

  import Phoenix.LiveViewTest

  test "mount renders the dashboard with a session table", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Hermes Sessions"
    assert html =~ "<table"
  end

  test "empty table renders when there are no sessions", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ "Hermes Sessions"
    assert html =~ "<table"
  end

  test "handle_info {:session_started, session} adds the session to the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")

    session = %{id: "sess-1", model: "claude-sonnet", status: :idle, message_count: 0}
    send(view.pid, {:session_started, session})

    html = render(view)
    assert html =~ "sess-1"
    assert html =~ "claude-sonnet"
    assert html =~ "idle"
  end

  test "handle_info {:session_status, _, _} updates the session status", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")

    send(
      view.pid,
      {:session_started, %{id: "sess-1", model: "claude", status: :idle, message_count: 0}}
    )

    send(view.pid, {:session_status, "sess-1", :running})

    html = render(view)
    assert html =~ "running"
  end

  test "handle_info {:session_stopped, _} removes the session", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard")

    send(
      view.pid,
      {:session_started, %{id: "sess-1", model: "claude", status: :idle, message_count: 0}}
    )

    send(view.pid, {:session_stopped, "sess-1"})

    html = render(view)
    refute html =~ "sess-1"
  end

  test "lists active sessions from running SessionServer processes", %{conn: conn} do
    {:ok, pid, session_id} = Hermes.Sessions.start_session(model: "test-model")
    on_exit(fn -> Hermes.Sessions.stop_session(pid) end)

    {:ok, _view, html} = live(conn, "/dashboard")

    assert html =~ session_id
    assert html =~ "test-model"
  end
end
