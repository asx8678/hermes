defmodule Hermes.Tools.VisionTool do
  @moduledoc """
  Vision analysis tool.

  Port of `tools/vision_tools.py:1168`. Loads an image and returns a textual
  analysis via an OpenAI-compatible vision API.
  """

  @default_timeout 60_000
  @max_image_bytes 5 * 1024 * 1024

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "vision_analyze",
        toolset: "vision",
        schema: vision_schema(),
        handler: &invoke/2,
        check_fn: &check_available/0
      }
    ]
  end

  @doc """
  Analyzes an image and returns a text description.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    image_url = Map.get(args, "image_url")
    question = Map.get(args, "question", "Describe this image.")

    cond do
      not is_binary(image_url) or image_url == "" ->
        %{"success" => false, "error" => "image_url is required"}

      not is_binary(question) ->
        %{"success" => false, "error" => "question must be a string"}

      true ->
        with {:ok, image_bytes, mime} <- load_image(image_url),
             {:ok, description} <- describe_image(image_bytes, mime, question) do
          %{
            "success" => true,
            "image_url" => image_url,
            "question" => question,
            "description" => description
          }
        else
          {:error, reason} ->
            %{"success" => false, "error" => format_error(reason)}
        end
    end
  end

  defp load_image(image_url) do
    cond do
      String.starts_with?(image_url, "data:") ->
        parse_data_url(image_url)

      String.starts_with?(image_url, "http://") or String.starts_with?(image_url, "https://") ->
        case fetch_url(image_url) do
          {:ok, body, final_url} ->
            {:ok, body, mime_from_url(final_url)}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        expanded = Path.expand(image_url)

        case File.read(expanded) do
          {:ok, body} ->
            {:ok, body, mime_from_path(expanded)}

          {:error, reason} ->
            {:error, "failed to read file: #{format_error(reason)}"}
        end
    end
  end

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [header, b64] ->
        mime = if header == "", do: "image/png", else: header
        {:ok, Base.decode64!(b64), mime}

      _ ->
        {:error, "invalid data URL"}
    end
  end

  defp describe_image(image_bytes, mime, question) do
    if byte_size(image_bytes) > @max_image_bytes do
      {:error, "image exceeds #{@max_image_bytes} byte limit"}
    else
      api_key = resolve_api_key()
      base_url = Application.get_env(:hermes, :openai_base_url, "https://api.openai.com/v1")
      model = Application.get_env(:hermes, :vision_model, "gpt-4o")

      if is_nil(api_key) or api_key == "" do
        {:error, "OPENAI_API_KEY not configured"}
      else
        b64 = Base.encode64(image_bytes)
        data_url = "data:#{mime};base64,#{b64}"

        payload = %{
          model: model,
          messages: [
            %{
              role: "user",
              content: [
                %{type: "text", text: question},
                %{type: "image_url", image_url: %{url: data_url}}
              ]
            }
          ],
          max_tokens: 1024
        }

        request =
          Finch.build(
            :post,
            "#{base_url}/chat/completions",
            [
              {"Authorization", "Bearer #{api_key}"},
              {"Content-Type", "application/json"}
            ],
            Jason.encode!(payload)
          )

        case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            case Jason.decode(body) do
              {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]}} ->
                {:ok, text}

              _ ->
                {:error, "unexpected vision response"}
            end

          {:ok, %{status: status, body: body}} ->
            {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            {:error, "request failed: #{format_error(reason)}"}
        end
      end
    end
  end

  defp fetch_url(url) do
    request = Finch.build(:get, url, [{"User-Agent", "HermesBot/1.0"}])

    case Finch.request(request, Hermes.Finch, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body, url}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mime_from_url(url) do
    ext = Path.extname(url) |> String.downcase()
    ext_to_mime(ext)
  end

  defp mime_from_path(path) do
    ext = Path.extname(path) |> String.downcase()
    ext_to_mime(ext)
  end

  defp ext_to_mime(".png"), do: "image/png"
  defp ext_to_mime(".jpg"), do: "image/jpeg"
  defp ext_to_mime(".jpeg"), do: "image/jpeg"
  defp ext_to_mime(".gif"), do: "image/gif"
  defp ext_to_mime(".webp"), do: "image/webp"
  defp ext_to_mime(_), do: "image/png"

  defp resolve_api_key do
    System.get_env("OPENAI_API_KEY") ||
      System.get_env("AUXILIARY_VISION_OPENAI_KEY") ||
      Application.get_env(:hermes, :openai_api_key)
  end

  defp check_available do
    key = resolve_api_key()
    is_binary(key) and key != ""
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  defp vision_schema do
    %{
      name: "vision_analyze",
      description:
        "Analyze an image from a URL, file path, or data URL and return a text description.",
      parameters: %{
        type: "object",
        properties: %{
          image_url: %{
            type: "string",
            description: "Image URL, local file path, or data: URL."
          },
          question: %{
            type: "string",
            description: "Specific question about the image."
          }
        },
        required: ["image_url", "question"]
      }
    }
  end
end
