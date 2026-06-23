defmodule Hermes.Tools.TTSTool do
  @moduledoc """
  Text-to-speech tool.

  Port of `tools/tts_tool.py:2816`. Uses OpenAI's TTS endpoint via Finch.
  """

  @default_timeout 60_000

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "text_to_speech",
        toolset: "tts",
        schema: tts_schema(),
        handler: &invoke/2,
        check_fn: &check_available/0
      }
    ]
  end

  @doc """
  Converts text to speech and saves the audio file.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    text = Map.get(args, "text")

    if not is_binary(text) or String.trim(text) == "" do
      %{"success" => false, "error" => "text is required"}
    else
      api_key = resolve_api_key()
      base_url = Application.get_env(:hermes, :openai_base_url, "https://api.openai.com/v1")
      model = Application.get_env(:hermes, :tts_model, "tts-1")
      voice = Application.get_env(:hermes, :tts_voice, "alloy")

      if is_nil(api_key) or api_key == "" do
        %{"success" => false, "error" => "OPENAI_API_KEY not configured"}
      else
        output_path = output_path(args["output_path"])

        payload = %{
          model: model,
          input: String.slice(text, 0, 4096),
          voice: voice,
          response_format: "mp3"
        }

        request =
          Finch.build(
            :post,
            "#{base_url}/audio/speech",
            [
              {"Authorization", "Bearer #{api_key}"},
              {"Content-Type", "application/json"}
            ],
            Jason.encode!(payload)
          )

        case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            File.write!(output_path, body)

            %{
              "success" => true,
              "file_path" => output_path,
              "media_tag" => "MEDIA:#{output_path}",
              "provider" => "openai",
              "voice" => voice
            }

          {:ok, %{status: status, body: body}} ->
            %{"success" => false, "error" => "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            %{"success" => false, "error" => "request failed: #{format_error(reason)}"}
        end
      end
    end
  end

  defp output_path(nil) do
    dir = Path.join(System.user_home() || System.tmp_dir!(), "voice-memos")
    File.mkdir_p!(dir)
    Path.join(dir, "tts-#{System.unique_integer([:positive])}.mp3")
  end

  defp output_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    File.mkdir_p!(Path.dirname(expanded))
    expanded
  end

  defp resolve_api_key do
    System.get_env("OPENAI_API_KEY") ||
      System.get_env("VOICE_TOOLS_OPENAI_KEY") ||
      Application.get_env(:hermes, :openai_api_key)
  end

  defp check_available do
    key = resolve_api_key()
    is_binary(key) and key != ""
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  defp tts_schema do
    %{
      name: "text_to_speech",
      description: "Convert text to speech audio using OpenAI TTS.",
      parameters: %{
        type: "object",
        properties: %{
          text: %{
            type: "string",
            description: "Text to convert to speech."
          },
          output_path: %{
            type: "string",
            description: "Optional custom file path. Defaults to ~/voice-memos/."
          }
        },
        required: ["text"]
      }
    }
  end
end
