defmodule Hermes.Tools.HATool do
  @moduledoc """
  Home Assistant tools.

  Port of `tools/homeassistant_tool.py`. Interacts with a Home Assistant
  instance via its REST API.
  """

  @default_timeout 15_000
  @entity_id_re ~r/^[a-z_][a-z0-9_]*\.[a-z0-9_]+$/
  @name_re ~r/^[a-z][a-z0-9_]*$/
  @blocked_domains ~w(shell_command command_line python_script pyscript hassio rest_command)

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      entry("ha_list_entities", &handle_list_entities/2, list_entities_schema()),
      entry("ha_get_state", &handle_get_state/2, get_state_schema()),
      entry("ha_list_services", &handle_list_services/2, list_services_schema()),
      entry("ha_call_service", &handle_call_service/2, call_service_schema())
    ]
  end

  # ---------------------------------------------------------------------------
  # Handlers
  # ---------------------------------------------------------------------------

  def handle_list_entities(args, _context) do
    domain = Map.get(args, "domain")
    area = Map.get(args, "area")

    with {:ok, states} <- get("/api/states") do
      filtered = filter_states(states, domain, area)

      %{
        "success" => true,
        "count" => length(filtered),
        "entities" =>
          Enum.map(filtered, fn state ->
            %{
              "entity_id" => state["entity_id"],
              "state" => state["state"],
              "friendly_name" => get_in(state, ["attributes", "friendly_name"])
            }
          end)
      }
    else
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  def handle_get_state(args, _context) do
    entity_id = Map.get(args, "entity_id")

    cond do
      not is_binary(entity_id) or entity_id == "" ->
        %{"success" => false, "error" => "entity_id is required"}

      not Regex.match?(@entity_id_re, entity_id) ->
        %{"success" => false, "error" => "invalid entity_id format"}

      true ->
        case get("/api/states/#{entity_id}") do
          {:ok, state} ->
            %{
              "success" => true,
              "entity_id" => state["entity_id"],
              "state" => state["state"],
              "attributes" => state["attributes"],
              "last_changed" => state["last_changed"],
              "last_updated" => state["last_updated"]
            }

          {:error, reason} ->
            %{"success" => false, "error" => reason}
        end
    end
  end

  def handle_list_services(args, _context) do
    domain = Map.get(args, "domain")

    with {:ok, services} <- get("/api/services") do
      domains =
        services
        |> Enum.filter(fn svc -> is_nil(domain) or svc["domain"] == domain end)
        |> Enum.map(fn svc ->
          %{
            "domain" => svc["domain"],
            "services" =>
              Enum.into(svc["services"] || %{}, %{}, fn {name, info} ->
                {name, %{"description" => info["description"]}}
              end)
          }
        end)

      %{
        "success" => true,
        "count" => length(domains),
        "domains" => domains
      }
    else
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  def handle_call_service(args, _context) do
    domain = Map.get(args, "domain")
    service = Map.get(args, "service")
    entity_id = Map.get(args, "entity_id")
    data = Map.get(args, "data", %{})

    cond do
      not is_binary(domain) or domain == "" ->
        %{"success" => false, "error" => "domain is required"}

      not is_binary(service) or service == "" ->
        %{"success" => false, "error" => "service is required"}

      domain in @blocked_domains ->
        %{"success" => false, "error" => "domain #{domain} is blocked"}

      not Regex.match?(@name_re, domain) ->
        %{"success" => false, "error" => "invalid domain"}

      not Regex.match?(@name_re, service) ->
        %{"success" => false, "error" => "invalid service"}

      true ->
        payload = build_service_payload(entity_id, data)

        case post("/api/services/#{domain}/#{service}", payload) do
          {:ok, result} ->
            affected =
              Enum.map(result, fn state ->
                %{
                  "entity_id" => state["entity_id"],
                  "state" => state["state"]
                }
              end)

            %{
              "success" => true,
              "service" => "#{domain}.#{service}",
              "affected_entities" => affected
            }

          {:error, reason} ->
            %{"success" => false, "error" => reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp get(path) do
    with {:ok, base_url, headers} <- config() do
      request = Finch.build(:get, base_url <> path, headers)

      case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:error, "invalid JSON response"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

        {:error, reason} ->
          {:error, "request failed: #{format_error(reason)}"}
      end
    end
  end

  defp post(path, payload) do
    with {:ok, base_url, headers} <- config() do
      request = Finch.build(:post, base_url <> path, headers, Jason.encode!(payload))

      case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:ok, []}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

        {:error, reason} ->
          {:error, "request failed: #{format_error(reason)}"}
      end
    end
  end

  defp config do
    base_url = System.get_env("HASS_URL") || Application.get_env(:hermes, :hass_url)
    token = System.get_env("HASS_TOKEN") || Application.get_env(:hermes, :hass_token)

    cond do
      is_nil(base_url) or base_url == "" ->
        {:error, "HASS_URL not configured"}

      is_nil(token) or token == "" ->
        {:error, "HASS_TOKEN not configured"}

      true ->
        base_url = String.trim_trailing(base_url, "/")

        headers = [
          {"Authorization", "Bearer #{token}"},
          {"Content-Type", "application/json"}
        ]

        {:ok, base_url, headers}
    end
  end

  defp filter_states(states, domain, area) do
    states
    |> Enum.filter(fn state ->
      is_nil(domain) or String.starts_with?(state["entity_id"], domain <> ".")
    end)
    |> Enum.filter(fn state ->
      is_nil(area) or String.contains?(state["entity_id"] <> " ", area) or
        String.contains?(get_in(state, ["attributes", "friendly_name"]) || "", area)
    end)
  end

  defp build_service_payload(nil, data) when is_map(data), do: data

  defp build_service_payload(entity_id, data) when is_map(data) do
    Map.put(data, "entity_id", entity_id)
  end

  defp build_service_payload(entity_id, _) do
    if is_nil(entity_id), do: %{}, else: %{"entity_id" => entity_id}
  end

  # ---------------------------------------------------------------------------
  # Registration helpers
  # ---------------------------------------------------------------------------

  defp entry(name, handler, schema) do
    %{
      name: name,
      toolset: "homeassistant",
      schema: schema,
      handler: handler,
      check_fn: &check_available/0
    }
  end

  defp check_available do
    case config() do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp list_entities_schema do
    %{
      name: "ha_list_entities",
      description: "List Home Assistant entities, optionally filtered by domain or area.",
      parameters: %{
        type: "object",
        properties: %{
          domain: %{type: "string"},
          area: %{type: "string"}
        },
        required: []
      }
    }
  end

  defp get_state_schema do
    %{
      name: "ha_get_state",
      description: "Get the current state of a Home Assistant entity.",
      parameters: %{
        type: "object",
        properties: %{
          entity_id: %{type: "string"}
        },
        required: ["entity_id"]
      }
    }
  end

  defp list_services_schema do
    %{
      name: "ha_list_services",
      description: "List Home Assistant services, optionally filtered by domain.",
      parameters: %{
        type: "object",
        properties: %{
          domain: %{type: "string"}
        },
        required: []
      }
    }
  end

  defp call_service_schema do
    %{
      name: "ha_call_service",
      description: "Call a Home Assistant service.",
      parameters: %{
        type: "object",
        properties: %{
          domain: %{type: "string"},
          service: %{type: "string"},
          entity_id: %{type: "string"},
          data: %{type: "object"}
        },
        required: ["domain", "service"]
      }
    }
  end
end
