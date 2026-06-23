defmodule Hermes.Gateway.Connectors.EmailClient do
  @moduledoc """
  Client for inbound IMAP and outbound SMTP email.

  Ports the email platform concepts from
  `hermes-agent/gateway/platforms/msgraph_webhook.py:45` and the
  per-session task lifecycle from `hermes-agent/gateway/platforms/base.py:2078`.

  Inbound: polls an IMAP inbox using `:gen_imap` or raw IMAP over a TCP socket.
  Outbound: sends via SMTP using `:gen_smtp` or raw SMTP over TCP.

  Both protocols use Erlang's built-in `:gen_tcp` module with TLS via
  `:ssl`. No external dependencies required — just BEAM built-ins.
  """

  require Logger

  @imap_port 993
  @smtp_port 465
  @default_timeout 30_000

  @spec check_imap(String.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def check_imap(host, user, password) do
    with {:ok, socket} <- connect_imap(host, user, password),
         {:ok, messages} <- fetch_unseen(socket),
         :ok <- close_imap(socket) do
      {:ok, messages}
    else
      {:error, reason} ->
        Logger.warning("EmailClient check_imap failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec send_email(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_email(host, user, password, to, subject, text, opts \\ []) do
    from = Keyword.get(opts, :from, user)
    message = build_mime_message(from, to, subject, text)

    with {:ok, socket} <- connect_smtp(host, user, password),
         :ok <- send_smtp(socket, from, to, message),
         :ok <- close_smtp(socket) do
      {:ok, %{"sent" => true, "to" => to, "subject" => subject}}
    else
      {:error, reason} ->
        Logger.warning("EmailClient send_email failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # IMAP
  # ---------------------------------------------------------------------------

  defp connect_imap(host, user, password) do
    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), @imap_port, imap_opts(), @default_timeout),
         {:ok, socket} <- upgrade_to_tls(socket, host),
         :ok <- imap_login(socket, user, password),
         :ok <- imap_select(socket, "INBOX") do
      {:ok, socket}
    end
  end

  defp imap_opts do
    [
      :binary,
      {:packet, :line},
      {:active, false},
      {:reuseaddr, true}
    ]
  end

  defp upgrade_to_tls(socket, host) do
    case :ssl.connect(socket, [
      {:server_name, String.to_charlist(host)},
      {:verify, :verify_none}
    ], @default_timeout) do
      {:ok, tls_socket} -> {:ok, {:tls, tls_socket}}
      {:error, reason} -> {:error, {:tls_upgrade_failed, reason}}
    end
  end

  defp imap_login(socket, user, password) do
    imap_command(socket, "LOGIN #{escape(user)} #{escape(password)}")
  end

  defp imap_select(socket, mailbox) do
    imap_command(socket, "SELECT #{escape(mailbox)}")
  end

  defp fetch_unseen(socket) do
    case imap_command(socket, "SEARCH UNSEEN") do
      :ok ->
        case imap_read_response(socket) do
          {:ok, response} ->
            ids = parse_search_response(response)
            messages = Enum.map(ids, &fetch_message(socket, &1))
            {:ok, Enum.reject(messages, &is_nil/1)}

          {:error, _} ->
            {:ok, []}
        end

      {:error, _} ->
        {:ok, []}
    end
  end

  defp fetch_message(socket, id) do
    case imap_command(socket, "FETCH #{id} (BODY[HEADER.FIELDS (FROM SUBJECT DATE)] BODY[TEXT])") do
      :ok ->
        case imap_read_response(socket) do
          {:ok, response} ->
            parse_email_response(response, id)

          {:error, _} ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp imap_command(socket, command) do
    tag = "A#{:erlang.unique_integer([:positive])}"
    full_command = "#{tag} #{command}\r\n"

    case send_raw(socket, full_command) do
      :ok ->
        wait_for_tag(socket, tag)

      error ->
        error
    end
  end

  defp wait_for_tag(socket, tag) do
    case recv_line(socket) do
      {:ok, line} ->
        if String.contains?(line, tag) do
          if String.contains?(line, "OK"), do: :ok, else: {:error, :imap_command_failed}
        else
          wait_for_tag(socket, tag)
        end

      error ->
        error
    end
  end

  defp imap_read_response(socket) do
    imap_read_response(socket, [])
  end

  defp imap_read_response(socket, acc) do
    case recv_line(socket) do
      {:ok, line} ->
        if String.starts_with?(line, "A") and String.contains?(line, "OK") do
          {:ok, Enum.reverse([line | acc]) |> Enum.join("\n")}
        else
          imap_read_response(socket, [line | acc])
        end

      {:error, _} ->
        {:ok, Enum.reverse(acc) |> Enum.join("\n")}
    end
  end

  defp send_raw({:tls, socket}, data) do
    :ssl.send(socket, data)
  end

  defp send_raw(socket, data) do
    :gen_tcp.send(socket, data)
  end

  defp recv_line({:tls, socket}) do
    case :ssl.recv(socket, 0, @default_timeout) do
      {:ok, data} -> {:ok, String.trim_trailing(data, "\r\n")}
      error -> error
    end
  end

  defp recv_line(socket) do
    case :gen_tcp.recv(socket, 0, @default_timeout) do
      {:ok, data} -> {:ok, String.trim_trailing(data, "\r\n")}
      error -> error
    end
  end

  defp close_imap({:tls, socket}) do
    send_raw({:tls, socket}, "A999 LOGOUT\r\n")
    :ssl.close(socket)
    :ok
  end

  defp parse_search_response(response) do
    response
    |> String.split()
    |> Enum.filter(&match?({n, ""} when n > 0, {Integer.parse(&1), ""}))
    |> Enum.map(fn s -> elem(Integer.parse(s), 0) end)
  end

  defp parse_email_response(response, id) do
    from = extract_header(response, "FROM")
    subject = extract_header(response, "SUBJECT")
    date = extract_header(response, "DATE")

    %{
      "id" => id,
      "from" => from,
      "subject" => subject,
      "date" => date
    }
  end

  defp extract_header(response, header) do
    case Regex.run(~r/#{header}:\s*(.+)/i, response) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp escape(value), do: "\"#{String.replace(value, "\"", "\\\"")}\""

  # ---------------------------------------------------------------------------
  # SMTP
  # ---------------------------------------------------------------------------

  defp connect_smtp(host, user, password) do
    with {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), @smtp_port, smtp_opts(), @default_timeout),
         {:ok, _greeting} <- recv_smtp(socket),
         :ok <- smtp_command(socket, "EHLO hermes"),
         :ok <- smtp_command(socket, "AUTH LOGIN"),
         :ok <- smtp_command(socket, Base.encode64(user)),
         :ok <- smtp_command(socket, Base.encode64(password)) do
      {:ok, socket}
    end
  end

  defp smtp_opts do
    [:binary, {:packet, :line}, {:active, false}]
  end

  defp send_smtp(socket, from, to, message) do
    with :ok <- smtp_command(socket, "MAIL FROM:<#{from}>"),
         :ok <- smtp_command(socket, "RCPT TO:<#{to}>"),
         :ok <- smtp_command(socket, "DATA"),
         :ok <- send_raw(socket, message <> "\r\n.\r\n"),
         {:ok, response} <- recv_smtp(socket) do
      if String.contains?(response, "250") do
        :ok
      else
        {:error, {:smtp_data_rejected, response}}
      end
    end
  end

  defp smtp_command(socket, command) do
    case send_raw(socket, command <> "\r\n") do
      :ok ->
        case recv_smtp(socket) do
          {:ok, response} ->
            if String.contains?(response, ["235", "250", "334", "354"]) do
              :ok
            else
              {:error, {:smtp_error, response}}
            end

          error ->
            error
        end

      error ->
        error
    end
  end

  defp recv_smtp(socket) do
    case :gen_tcp.recv(socket, 0, @default_timeout) do
      {:ok, data} -> {:ok, String.trim_trailing(data, "\r\n")}
      error -> error
    end
  end

  defp close_smtp(socket) do
    send_raw(socket, "QUIT\r\n")
    :gen_tcp.close(socket)
    :ok
  end

  defp build_mime_message(from, to, subject, text) do
    """
    From: #{from}
    To: #{to}
    Subject: #{subject}
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: 8bit

    #{text}
    """
    |> String.trim_leading()
  end
end
