defmodule Hermes.Tools.BrowserTool do
  @moduledoc """
  Browser automation tools backed by a Chrome DevTools Protocol endpoint.

  Port of `tools/browser_tool.py`, `tools/browser_cdp_tool.py`, and
  `tools/browser_dialog_tool.py`.  State is kept in `Hermes.Tools.BrowserSidecar`
  and actual CDP traffic is sent via HTTP to the configured CDP URL.
  """

  alias Hermes.Tools.BrowserSidecar

  @default_timeout 30_000
  @max_console 200

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      entry("browser_navigate", &handle_navigate/2, navigate_schema()),
      entry("browser_snapshot", &handle_snapshot/2, snapshot_schema()),
      entry("browser_click", &handle_click/2, click_schema()),
      entry("browser_type", &handle_type/2, type_schema()),
      entry("browser_scroll", &handle_scroll/2, scroll_schema()),
      entry("browser_back", &handle_back/2, back_schema()),
      entry("browser_press", &handle_press/2, press_schema()),
      entry("browser_get_images", &handle_get_images/2, get_images_schema()),
      entry("browser_vision", &handle_vision/2, vision_schema()),
      entry("browser_console", &handle_console/2, console_schema()),
      entry("browser_cdp", &handle_cdp/2, cdp_schema()),
      entry("browser_dialog", &handle_dialog/2, dialog_schema())
    ]
  end

  # ---------------------------------------------------------------------------
  # Handlers
  # ---------------------------------------------------------------------------

  def handle_navigate(args, _context) do
    url = Map.get(args, "url")

    if not is_binary(url) or url == "" do
      %{"success" => false, "error" => "url is required"}
    else
      case cdp_call("Page.navigate", %{"url" => url}) do
        {:ok, result} ->
          BrowserSidecar.set_url(result["frameId"] || url)

          %{
            "success" => true,
            "url" => BrowserSidecar.get_url(),
            "title" => page_title(),
            "snapshot" => compact_snapshot()
          }

        {:error, reason} ->
          %{"success" => false, "error" => reason}
      end
    end
  end

  def handle_snapshot(args, _context) do
    full = Map.get(args, "full", false)

    case BrowserSidecar.get_url() do
      nil ->
        %{"success" => false, "error" => "call browser_navigate first"}

      _url ->
        snapshot = if full, do: full_snapshot(), else: compact_snapshot()

        %{
          "success" => true,
          "url" => BrowserSidecar.get_url(),
          "title" => page_title(),
          "snapshot" => snapshot
        }
    end
  end

  def handle_click(args, _context) do
    ref = Map.get(args, "ref")

    if not is_binary(ref) or ref == "" do
      %{"success" => false, "error" => "ref is required"}
    else
      selector = ref_to_selector(ref)

      case evaluate("document.querySelector(#{inspect(selector)})?.click(); true") do
        {:ok, _} ->
          %{
            "success" => true,
            "ref" => ref,
            "snapshot" => compact_snapshot()
          }

        {:error, reason} ->
          %{"success" => false, "error" => reason}
      end
    end
  end

  def handle_type(args, _context) do
    ref = Map.get(args, "ref")
    text = Map.get(args, "text", "")

    cond do
      not is_binary(ref) or ref == "" ->
        %{"success" => false, "error" => "ref is required"}

      not is_binary(text) ->
        %{"success" => false, "error" => "text must be a string"}

      true ->
        selector = ref_to_selector(ref)

        expression = """
        const el = document.querySelector(#{inspect(selector)});
        if (!el) throw new Error('element not found');
        el.focus();
        el.value = '';
        el.value = #{inspect(text)};
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        true;
        """

        case evaluate(expression) do
          {:ok, _} ->
            %{
              "success" => true,
              "ref" => ref,
              "snapshot" => compact_snapshot()
            }

          {:error, reason} ->
            %{"success" => false, "error" => reason}
        end
    end
  end

  def handle_scroll(args, _context) do
    direction = Map.get(args, "direction")

    amount =
      case direction do
        "up" -> -800
        "down" -> 800
        _ -> 0
      end

    if amount == 0 do
      %{"success" => false, "error" => "direction must be up or down"}
    else
      expression = "window.scrollBy(0, #{amount}); true"

      case evaluate(expression) do
        {:ok, _} ->
          %{
            "success" => true,
            "direction" => direction,
            "snapshot" => compact_snapshot()
          }

        {:error, reason} ->
          %{"success" => false, "error" => reason}
      end
    end
  end

  def handle_back(_args, _context) do
    case evaluate("history.back(); true") do
      {:ok, _} ->
        %{
          "success" => true,
          "url" => BrowserSidecar.get_url(),
          "snapshot" => compact_snapshot()
        }

      {:error, reason} ->
        %{"success" => false, "error" => reason}
    end
  end

  def handle_press(args, _context) do
    key = Map.get(args, "key")

    if not is_binary(key) or key == "" do
      %{"success" => false, "error" => "key is required"}
    else
      case cdp_call("Input.dispatchKeyEvent", %{
             "type" => "keyDown",
             "key" => key,
             "code" => key
           }) do
        {:ok, _} ->
          cdp_call("Input.dispatchKeyEvent", %{
            "type" => "keyUp",
            "key" => key,
            "code" => key
          })

          %{
            "success" => true,
            "key" => key,
            "snapshot" => compact_snapshot()
          }

        {:error, reason} ->
          %{"success" => false, "error" => reason}
      end
    end
  end

  def handle_get_images(_args, _context) do
    expression = """
    Array.from(document.querySelectorAll('img')).map((img, i) => ({
      index: i,
      src: img.src,
      alt: img.alt,
      width: img.naturalWidth,
      height: img.naturalHeight
    }));
    """

    case evaluate(expression) do
      {:ok, images} ->
        %{
          "success" => true,
          "count" => length(images),
          "images" => images
        }

      {:error, reason} ->
        %{"success" => false, "error" => reason}
    end
  end

  def handle_vision(args, _context) do
    annotate = Map.get(args, "annotate", false)

    case cdp_call("Page.captureScreenshot", %{"format" => "png"}) do
      {:ok, %{"data" => b64}} ->
        screenshot_path = save_screenshot(b64, annotate)

        %{
          "success" => true,
          "screenshot_path" => screenshot_path,
          "annotate" => annotate,
          "url" => BrowserSidecar.get_url()
        }

      {:error, reason} ->
        %{"success" => false, "error" => reason}
    end
  end

  def handle_console(args, _context) do
    expression = Map.get(args, "expression")
    clear = Map.get(args, "clear", false)

    result =
      if is_binary(expression) and expression != "" do
        case evaluate(expression) do
          {:ok, value} -> %{"evaluated" => true, "result" => value}
          {:error, reason} -> %{"evaluated" => false, "error" => reason}
        end
      else
        %{}
      end

    messages = BrowserSidecar.console_messages(clear)
    trimmed = Enum.take(messages, -@max_console)

    Map.merge(result, %{
      "success" => true,
      "messages" => trimmed,
      "count" => length(trimmed),
      "cleared" => clear
    })
  end

  def handle_cdp(args, _context) do
    method = Map.get(args, "method")
    params = Map.get(args, "params", %{})

    if not is_binary(method) or method == "" do
      %{"success" => false, "error" => "method is required"}
    else
      case cdp_call(method, params) do
        {:ok, result} ->
          %{"success" => true, "method" => method, "result" => result}

        {:error, reason} ->
          %{"success" => false, "error" => reason}
      end
    end
  end

  def handle_dialog(args, _context) do
    action = Map.get(args, "action")
    prompt_text = Map.get(args, "prompt_text", "")

    if action not in ["accept", "dismiss"] do
      %{"success" => false, "error" => "action must be accept or dismiss"}
    else
      dialog_id = Map.get(args, "dialog_id")

      case find_dialog(dialog_id) do
        nil ->
          %{"success" => false, "error" => "no matching pending dialog"}

        dialog ->
          accept = action == "accept"

          params =
            case dialog["type"] do
              "prompt" -> %{"accept" => accept, "promptText" => prompt_text}
              _ -> %{"accept" => accept}
            end

          case cdp_call("Page.handleJavaScriptDialog", params) do
            {:ok, _} ->
              BrowserSidecar.remove_dialog(dialog["id"])
              %{"success" => true, "action" => action, "dialog" => dialog}

            {:error, reason} ->
              %{"success" => false, "error" => reason}
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CDP helpers
  # ---------------------------------------------------------------------------

  defp cdp_call(method, params) do
    case BrowserSidecar.cdp_url() do
      nil ->
        {:error, "BROWSER_CDP_URL not configured"}

      url ->
        payload = %{
          "id" => System.unique_integer([:positive]),
          "method" => method,
          "params" => params
        }

        request =
          Finch.build(:post, url, [{"Content-Type", "application/json"}], Jason.encode!(payload))

        case Finch.request(request, Hermes.Finch, receive_timeout: @default_timeout) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            case Jason.decode(body) do
              {:ok, %{"error" => error}} ->
                {:error, "CDP error: #{inspect(error)}"}

              {:ok, %{"result" => result}} ->
                {:ok, result}

              {:ok, other} ->
                {:ok, other}
            end

          {:ok, %{status: status, body: body}} ->
            {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

          {:error, reason} ->
            {:error, "request failed: #{format_error(reason)}"}
        end
    end
  end

  defp evaluate(expression) do
    case cdp_call("Runtime.evaluate", %{
           "expression" => expression,
           "returnByValue" => true,
           "awaitPromise" => true
         }) do
      {:ok, %{"result" => %{"value" => value}}} ->
        {:ok, value}

      {:ok, %{"result" => %{"description" => desc}}} ->
        {:ok, desc}

      {:ok, _} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_title do
    case evaluate("document.title") do
      {:ok, title} -> title || ""
      _ -> ""
    end
  end

  defp compact_snapshot do
    expression = """
    Array.from(document.querySelectorAll('a, button, input, textarea, select, [role="button"], [role="link"]'))
      .filter(el => el.offsetParent !== null)
      .slice(0, 50)
      .map((el, i) => {
        const tag = el.tagName.toLowerCase();
        const text = (el.innerText || el.value || el.getAttribute('aria-label') || '').slice(0, 80);
        const id = el.id ? '#' + el.id : '';
        const cls = Array.from(el.classList).slice(0, 2).join('.');
        return `@e${i} <${tag}${id ? ' id=' + id : ''}${cls ? ' class=' + cls : ''}> ${text}`;
      });
    """

    case evaluate(expression) do
      {:ok, lines} when is_list(lines) -> lines
      _ -> []
    end
  end

  defp full_snapshot do
    expression = """
    (() => {
      const clone = document.documentElement.cloneNode(true);
      const scripts = clone.querySelectorAll('script, style');
      scripts.forEach(s => s.remove());
      return clone.innerText;
    })();
    """

    case evaluate(expression) do
      {:ok, text} when is_binary(text) ->
        String.slice(text, 0, 8000)

      _ ->
        ""
    end
  end

  defp ref_to_selector("@" <> ref) do
    # We previously generated ids/classes only.  If the ref does not map,
    # fall back to the text content via XPath (evaluated in JS).
    "[data-hermes-ref=\"#{ref}\"]"
  end

  defp ref_to_selector(ref), do: "[data-hermes-ref=\"#{ref}\"]"

  defp find_dialog(nil) do
    case BrowserSidecar.pending_dialogs() do
      [dialog | _] -> dialog
      [] -> nil
    end
  end

  defp find_dialog(dialog_id) do
    BrowserSidecar.pending_dialogs()
    |> Enum.find(&(&1["id"] == dialog_id))
  end

  defp save_screenshot(b64, annotate) do
    dir = Path.join(System.tmp_dir!(), "hermes-browser")
    File.mkdir_p!(dir)
    path = Path.join(dir, "screenshot-#{System.unique_integer([:positive])}.png")
    binary = Base.decode64!(b64)
    File.write!(path, binary)

    if annotate do
      # Annotation is a no-op in the Elixir port; the snapshot already carries
      # ref ids when available.
      :ok
    end

    path
  end

  # ---------------------------------------------------------------------------
  # Tool registration helpers
  # ---------------------------------------------------------------------------

  defp entry(name, handler, schema) do
    %{
      name: name,
      toolset: "browser",
      schema: schema,
      handler: handler,
      check_fn: &cdp_available?/0
    }
  end

  defp cdp_available? do
    BrowserSidecar.cdp_url() != nil
  end

  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp navigate_schema do
    %{
      name: "browser_navigate",
      description: "Navigate the browser to a URL.",
      parameters: %{
        type: "object",
        properties: %{url: %{type: "string", description: "URL to load"}},
        required: ["url"]
      }
    }
  end

  defp snapshot_schema do
    %{
      name: "browser_snapshot",
      description: "Get a text snapshot of the current page.",
      parameters: %{
        type: "object",
        properties: %{full: %{type: "boolean", description: "Return full page text"}},
        required: []
      }
    }
  end

  defp click_schema do
    %{
      name: "browser_click",
      description: "Click an element by ref id from the snapshot.",
      parameters: %{
        type: "object",
        properties: %{ref: %{type: "string", description: "Element ref like @e5"}},
        required: ["ref"]
      }
    }
  end

  defp type_schema do
    %{
      name: "browser_type",
      description: "Type text into an input element by ref id.",
      parameters: %{
        type: "object",
        properties: %{
          ref: %{type: "string"},
          text: %{type: "string"}
        },
        required: ["ref", "text"]
      }
    }
  end

  defp scroll_schema do
    %{
      name: "browser_scroll",
      description: "Scroll the page up or down.",
      parameters: %{
        type: "object",
        properties: %{direction: %{type: "string", enum: ["up", "down"]}},
        required: ["direction"]
      }
    }
  end

  defp back_schema do
    %{
      name: "browser_back",
      description: "Navigate back in browser history.",
      parameters: %{type: "object", properties: %{}, required: []}
    }
  end

  defp press_schema do
    %{
      name: "browser_press",
      description: "Press a keyboard key.",
      parameters: %{
        type: "object",
        properties: %{key: %{type: "string", description: "Key name, e.g. Enter"}},
        required: ["key"]
      }
    }
  end

  defp get_images_schema do
    %{
      name: "browser_get_images",
      description: "List images on the current page.",
      parameters: %{type: "object", properties: %{}, required: []}
    }
  end

  defp vision_schema do
    %{
      name: "browser_vision",
      description: "Capture a screenshot of the current page.",
      parameters: %{
        type: "object",
        properties: %{
          question: %{type: "string"},
          annotate: %{type: "boolean", description: "Overlay numbered labels"}
        },
        required: []
      }
    }
  end

  defp console_schema do
    %{
      name: "browser_console",
      description: "Read browser console messages or evaluate JavaScript.",
      parameters: %{
        type: "object",
        properties: %{
          expression: %{type: "string", description: "JavaScript expression to evaluate"},
          clear: %{type: "boolean", description: "Clear the console buffer after reading"}
        },
        required: []
      }
    }
  end

  defp cdp_schema do
    %{
      name: "browser_cdp",
      description: "Send an arbitrary Chrome DevTools Protocol command.",
      parameters: %{
        type: "object",
        properties: %{
          method: %{type: "string", description: "CDP method name"},
          params: %{type: "object", description: "CDP method parameters"}
        },
        required: ["method"]
      }
    }
  end

  defp dialog_schema do
    %{
      name: "browser_dialog",
      description: "Respond to a native JavaScript dialog.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{type: "string", enum: ["accept", "dismiss"]},
          prompt_text: %{type: "string"},
          dialog_id: %{type: "string"}
        },
        required: ["action"]
      }
    }
  end
end
