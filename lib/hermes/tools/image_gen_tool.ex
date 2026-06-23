defmodule Hermes.Tools.ImageGenTool do
  @moduledoc """
  Image generation tool.

  Port of `tools/image_generation_tool.py:1173`. Uses OpenAI's DALL-E
  image generation endpoint via Finch.
  """

  @default_timeout 120_000

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "image_generate",
        toolset: "image_gen",
        schema: image_gen_schema(),
        handler: &invoke/2,
        check_fn: &check_available/0
      }
    ]
  end

  @doc """
  Generates an image from a text prompt.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    prompt = Map.get(args, "prompt")

    if not is_binary(prompt) or String.trim(prompt) == "" do
      %{"success" => false, "error" => "prompt is required"}
    else
      aspect_ratio = Map.get(args, "aspect_ratio", "square")
      size = size_from_aspect_ratio(aspect_ratio)

      api_key = resolve_api_key()
      base_url = Application.get_env(:hermes, :openai_base_url, "https://api.openai.com/v1")
      model = Application.get_env(:hermes, :image_model, "dall-e-3")

      if is_nil(api_key) or api_key == "" do
        %{"success" => false, "error" => "OPENAI_API_KEY not configured"}
      else
        payload = %{
          model: model,
          prompt: prompt,
          n: 1,
          size: size,
          response_format: "b64_json"
        }

        request =
          Finch.build(
            :post,
            "#{base_url}/images/generations",
            [
              {"Authorization", "Bearer #{api_key}"},
              {"Content-Type", "application/json"}
            ],
            Jason.encode!(payload)
          )

        case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            case Jason.decode(body) do
              {:ok, %{"data" => [%{"b64_json" => b64} | _]}} ->
                path = save_image(b64)

                %{
                  "success" => true,
                  "image" => path,
                  "modality" => "image",
                  "prompt" => prompt
                }

              {:ok, %{"data" => [%{"url" => url} | _]}} ->
                %{
                  "success" => true,
                  "image" => url,
                  "modality" => "image",
                  "prompt" => prompt
                }

              _ ->
                %{"success" => false, "error" => "unexpected image generation response"}
            end

          {:ok, %{status: status, body: body}} ->
            %{"success" => false, "error" => "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            %{"success" => false, "error" => "request failed: #{format_error(reason)}"}
        end
      end
    end
  end

  defp size_from_aspect_ratio("landscape"), do: "1792x1024"
  defp size_from_aspect_ratio("portrait"), do: "1024x1792"
  defp size_from_aspect_ratio("square"), do: "1024x1024"
  defp size_from_aspect_ratio(_), do: "1024x1024"

  defp save_image(b64) do
    dir = Path.join(System.tmp_dir!(), "hermes-images")
    File.mkdir_p!(dir)
    path = Path.join(dir, "generated-#{System.unique_integer([:positive])}.png")
    binary = Base.decode64!(b64)
    File.write!(path, binary)
    path
  end

  defp resolve_api_key do
    System.get_env("OPENAI_API_KEY") ||
      Application.get_env(:hermes, :openai_api_key)
  end

  defp check_available do
    key = resolve_api_key()
    is_binary(key) and key != ""
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  defp image_gen_schema do
    %{
      name: "image_generate",
      description: "Generate an image from a text prompt using DALL-E.",
      parameters: %{
        type: "object",
        properties: %{
          prompt: %{
            type: "string",
            description: "Detailed text prompt describing the desired image."
          },
          aspect_ratio: %{
            type: "string",
            enum: ["landscape", "portrait", "square"],
            description: "Aspect ratio of the generated image.",
            default: "square"
          }
        },
        required: ["prompt"]
      }
    }
  end
end
