defmodule Hermes.ServerReleaseTest do
  @moduledoc """
  Smoke test for the headless BEAM release used in server mode.

  The test builds (or reuses) a prod release and starts it with the
  same environment variables the Dockerfile/systemd unit set. It then
  checks that the endpoint is reachable, the SQLite database is created,
  and core supervised processes (Oban, gateway supervisor) are alive.
  """
  use ExUnit.Case, async: false

  @release_dir "_build/prod/rel/hermes"
  @boot_timeout 30_000

  setup do
    port = 40_000 + :rand.uniform(2_000)
    tmp_dir = System.tmp_dir!()
    db_path = Path.join(tmp_dir, "hermes_server_release_#{port}.db")
    release_node = "hermes_server_test_#{port}"

    build_release()

    secret_key_base =
      Base.encode64(:crypto.strong_rand_bytes(64))

    env = [
      {"PHX_SERVER", "true"},
      {"PORT", to_string(port)},
      {"DATABASE_PATH", db_path},
      {"SECRET_KEY_BASE", secret_key_base},
      {"RELEASE_NODE", release_node}
    ]

    on_exit(fn ->
      stop_release(release_node)
      File.rm(db_path)
    end)

    {:ok, port: port, db_path: db_path, env: env, release_node: release_node}
  end

  test "release starts, serves HTTP, creates the database, and starts core services", ctx do
    bin = Path.join(File.cwd!(), @release_dir <> "/bin/hermes")
    assert File.exists?(bin), "release binary missing at #{bin}"

    start_release(bin, ctx.env)

    assert wait_for_port("127.0.0.1", ctx.port, @boot_timeout),
           "server did not accept connections on port #{ctx.port}"

    assert wait_for_db(ctx.db_path, @boot_timeout),
           "database was not created at #{ctx.db_path}"

    status = http_status("http://127.0.0.1:#{ctx.port}/")
    assert status in [200, 404], "unexpected HTTP status from endpoint: #{status}"

    assert service_running?(bin, ctx.release_node, "Hermes.Gateway.Supervisor"),
           "gateway supervisor is not running"

    assert service_running?(bin, ctx.release_node, "Oban"),
           "Oban is not running"
  end

  defp build_release do
    {_, 0} =
      System.cmd("mix", ["release", "--overwrite"],
        env: full_env([{"MIX_ENV", "prod"}]),
        stderr_to_stdout: true
      )

    :ok
  end

  defp start_release(bin, env) do
    spawn(fn ->
      System.cmd(bin, ["start"],
        env: full_env(env),
        stderr_to_stdout: true
      )
    end)

    :ok
  end

  defp stop_release(node) do
    bin = Path.join(File.cwd!(), @release_dir <> "/bin/hermes")

    if File.exists?(bin) do
      System.cmd(bin, ["stop"],
        env: full_env([{"RELEASE_NODE", node}]),
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp wait_for_port(host, port, timeout) do
    host_charlist = String.to_charlist(host)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_port(host_charlist, port, deadline)
  end

  defp do_wait_port(host, port, deadline) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          do_wait_port(host, port, deadline)
        else
          false
        end
    end
  end

  defp wait_for_db(db_path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_db(db_path, deadline)
  end

  defp do_wait_for_db(db_path, deadline) do
    if File.exists?(db_path) do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(100)
        do_wait_for_db(db_path, deadline)
      else
        false
      end
    end
  end

  defp http_status(url) do
    case System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", url],
           stderr_to_stdout: true
         ) do
      {code, 0} -> String.to_integer(String.trim(code))
      _ -> nil
    end
  end

  defp service_running?(bin, node, service_id) do
    expr = """
    IO.inspect(
      #{service_id} in
        (Supervisor.which_children(Hermes.Supervisor)
         |> Enum.map(fn {id, _, _, _} -> id end))
    )
    """

    {out, 0} =
      System.cmd(bin, ["rpc", expr],
        env: full_env([{"RELEASE_NODE", node}]),
        stderr_to_stdout: true
      )

    String.contains?(out, "true")
  end

  defp full_env(overrides) do
    overrides_map = Map.new(overrides)
    System.get_env() |> Map.merge(overrides_map) |> Map.to_list()
  end
end
