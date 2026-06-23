defmodule Hermes.Tools.ComputerUseTool do
  @moduledoc """
  macOS desktop automation tool.

  Port of `tools/computer_use_tool.py` and `tools/computer_use/schema.py`.
  Uses `osascript` via the terminal sidecar for screenshot, click, type,
  key, and scroll actions.
  """

  alias Hermes.Tools.TerminalSidecar

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "computer_use",
        toolset: "computer_use",
        schema: computer_use_schema(),
        handler: &invoke/2,
        check_fn: &check_available/0
      }
    ]
  end

  @doc """
  Dispatches a computer_use action.
  """
  @spec invoke(map(), map()) :: map()
  def invoke(args, _context) do
    action = Map.get(args, "action")

    case action do
      "screenshot" -> handle_screenshot(args)
      "click" -> handle_click(args)
      "type" -> handle_type(args)
      "key" -> handle_key(args)
      "scroll" -> handle_scroll(args)
      "move" -> handle_move(args)
      _ -> %{"success" => false, "error" => "unknown computer_use action: #{action}"}
    end
  end

  defp handle_screenshot(_args) do
    path = temp_path("png")

    script = """
    set filePath to "#{path}"
    tell application "System Events"
      tell application process "Finder"
        set frontmost to true
      end tell
    end tell
    do shell script "screencapture -x " & quoted form of filePath
    return filePath
    """

    case run_applescript(script) do
      {:ok, output} ->
        %{
          "success" => true,
          "action" => "screenshot",
          "screenshot_path" => String.trim(output),
          "media_tag" => "MEDIA:#{String.trim(output)}"
        }

      {:error, reason} ->
        %{"success" => false, "error" => reason}
    end
  end

  defp handle_click(args) do
    {x, y} = coordinates(args)

    script = """
    tell application "System Events"
      click at {#{x}, #{y}}
    end tell
    return "clicked"
    """

    case run_applescript(script) do
      {:ok, _} -> %{"success" => true, "action" => "click", "x" => x, "y" => y}
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  defp handle_type(args) do
    text = Map.get(args, "text", "")

    if text == "" do
      %{"success" => false, "error" => "text is required"}
    else
      escaped = escape_applescript(text)

      script = """
      tell application "System Events"
        keystroke "#{escaped}"
      end tell
      return "typed"
      """

      case run_applescript(script) do
        {:ok, _} -> %{"success" => true, "action" => "type", "text" => text}
        {:error, reason} -> %{"success" => false, "error" => reason}
      end
    end
  end

  defp handle_key(args) do
    key = Map.get(args, "key", "")

    if key == "" do
      %{"success" => false, "error" => "key is required"}
    else
      keystroke = key_to_applescript(key)

      script = """
      tell application "System Events"
        #{keystroke}
      end tell
      return "key"
      """

      case run_applescript(script) do
        {:ok, _} -> %{"success" => true, "action" => "key", "key" => key}
        {:error, reason} -> %{"success" => false, "error" => reason}
      end
    end
  end

  defp handle_scroll(args) do
    {x, y} = coordinates(args)
    direction = Map.get(args, "direction", "down")
    amount = Map.get(args, "amount", 3)
    delta = if direction == "up", do: amount, else: -amount

    script = """
    tell application "System Events"
      tell application "System Events" to tell process "Finder"
        set frontmost to true
      end tell
      scroll #{delta} at {#{x}, #{y}}
    end tell
    return "scrolled"
    """

    case run_applescript(script) do
      {:ok, _} ->
        %{"success" => true, "action" => "scroll", "direction" => direction, "x" => x, "y" => y}

      {:error, reason} ->
        %{"success" => false, "error" => reason}
    end
  end

  defp handle_move(args) do
    {x, y} = coordinates(args)

    script = """
    tell application "System Events"
      set mouseLocation to {#{x}, #{y}}
    end tell
    return "moved"
    """

    case run_applescript(script) do
      {:ok, _} -> %{"success" => true, "action" => "move", "x" => x, "y" => y}
      {:error, reason} -> %{"success" => false, "error" => reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_applescript(script) do
    escaped = escape_shell(script)
    command = "osascript -e #{escaped}"

    case TerminalSidecar.execute(command, timeout: 20) do
      %{"success" => true, "output" => output} -> {:ok, output}
      %{"success" => false, "error" => error} -> {:error, error}
      other -> {:error, "unexpected sidecar response: #{inspect(other)}"}
    end
  end

  defp coordinates(args) do
    x = parse_int(args["x"], 0)
    y = parse_int(args["y"], 0)
    {x, y}
  end

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n), do: n
  defp parse_int(_, default), do: default

  defp key_to_applescript("enter"), do: "key code 36"
  defp key_to_applescript("return"), do: "key code 36"
  defp key_to_applescript("escape"), do: "key code 53"
  defp key_to_applescript("tab"), do: "key code 48"
  defp key_to_applescript("space"), do: "key code 49"
  defp key_to_applescript("up"), do: "key code 126"
  defp key_to_applescript("down"), do: "key code 125"
  defp key_to_applescript("left"), do: "key code 123"
  defp key_to_applescript("right"), do: "key code 124"
  defp key_to_applescript(key), do: "keystroke \"#{key}\""

  defp escape_applescript(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_shell(script) do
    escaped =
      script
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("`", "\\`")
      |> String.replace("$", "\\$")

    "\"#{escaped}\""
  end

  defp temp_path(ext) do
    dir = Path.join(System.tmp_dir!(), "hermes-computer-use")
    File.mkdir_p!(dir)
    Path.join(dir, "capture-#{System.unique_integer([:positive])}.#{ext}")
  end

  defp check_available do
    case :os.type() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp computer_use_schema do
    %{
      name: "computer_use",
      description:
        "Drive the macOS desktop via AppleScript: screenshot, click, type, " <>
          "key, scroll, move. macOS only.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["screenshot", "click", "type", "key", "scroll", "move"],
            description: "Action to perform."
          },
          x: %{type: "integer", description: "X coordinate for click/scroll/move."},
          y: %{type: "integer", description: "Y coordinate for click/scroll/move."},
          text: %{type: "string", description: "Text to type for action=type."},
          key: %{
            type: "string",
            description:
              "Key name for action=key (enter, escape, tab, space, up, down, left, right, or a character)."
          },
          direction: %{type: "string", enum: ["up", "down"], description: "Scroll direction."},
          amount: %{type: "integer", description: "Scroll amount."}
        },
        required: ["action"]
      }
    }
  end
end
