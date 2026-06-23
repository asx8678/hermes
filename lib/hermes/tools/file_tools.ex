defmodule Hermes.Tools.FileTools do
  @moduledoc """
  Filesystem tools: read_file, write_file, patch, search_files.

  Minimal port of `tools/file_tools.py:1735-1737`. Paths are expanded and
  checked for `..` traversal before any I/O occurs.
  """

  @max_read_lines 2000
  @default_read_lines 500

  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "read_file",
        toolset: "file",
        schema: read_file_schema(),
        handler: fn args, _ctx -> invoke("read_file", args) end,
        check_fn: &always_available/0
      },
      %{
        name: "write_file",
        toolset: "file",
        schema: write_file_schema(),
        handler: fn args, _ctx -> invoke("write_file", args) end,
        check_fn: &always_available/0
      },
      %{
        name: "patch",
        toolset: "file",
        schema: patch_schema(),
        handler: fn args, _ctx -> invoke("patch", args) end,
        check_fn: &always_available/0
      },
      %{
        name: "search_files",
        toolset: "file",
        schema: search_files_schema(),
        handler: fn args, _ctx -> invoke("search_files", args) end,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a file tool invocation and returns a JSON-encodable result.
  """
  @spec invoke(String.t(), map()) :: map()
  def invoke("read_file", args) do
    path = Map.get(args, "path")

    if is_nil(path) or not is_binary(path) or String.trim(path) == "" do
      %{"success" => false, "error" => "path is required"}
    else
      with :ok <- validate_path(path),
           expanded = Path.expand(path),
           {:ok, content} <- File.read(expanded) do
        lines = String.split(content, "\n")
        total_lines = length(lines)
        offset = max(1, int_or(Map.get(args, "offset"), 1))
        limit = max(1, min(int_or(Map.get(args, "limit"), @default_read_lines), @max_read_lines))
        end_index = offset + limit - 1
        sliced = Enum.slice(lines, offset - 1, limit)

        numbered =
          sliced
          |> Enum.with_index(offset)
          |> Enum.map_join("\n", fn {line, idx} -> "#{idx}|#{line}" end)

        result = %{
          "content" => numbered,
          "total_lines" => total_lines,
          "file_size" => byte_size(content),
          "truncated" => total_lines > end_index
        }

        if total_lines > end_index do
          Map.put(result, "hint", "Use offset=#{end_index + 1} to continue")
        else
          result
        end
      else
        {:error, reason} ->
          %{"success" => false, "error" => "read failed: #{inspect(reason)}"}

        error ->
          %{"success" => false, "error" => "read failed: #{inspect(error)}"}
      end
    end
  end

  def invoke("write_file", args) do
    path = Map.get(args, "path")
    content = Map.get(args, "content")

    cond do
      is_nil(path) or not is_binary(path) or String.trim(path) == "" ->
        %{"success" => false, "error" => "path is required"}

      is_nil(content) ->
        %{"success" => false, "error" => "content is required"}

      not is_binary(content) ->
        %{"success" => false, "error" => "content must be a string"}

      true ->
        with :ok <- validate_path(path),
             expanded = Path.expand(path),
             :ok <- File.mkdir_p(Path.dirname(expanded)),
             :ok <- File.write(expanded, content) do
          %{
            "success" => true,
            "message" => "File written.",
            "path" => expanded,
            "files_modified" => [expanded]
          }
        else
          {:error, reason} ->
            %{"success" => false, "error" => "write failed: #{inspect(reason)}"}

          error ->
            %{"success" => false, "error" => "write failed: #{inspect(error)}"}
        end
    end
  end

  def invoke("patch", args) do
    path = Map.get(args, "path")
    old_string = Map.get(args, "old_string")
    new_string = Map.get(args, "new_string")
    replace_all = Map.get(args, "replace_all", false)

    cond do
      is_nil(path) or not is_binary(path) or String.trim(path) == "" ->
        %{"success" => false, "error" => "path is required"}

      is_nil(old_string) or is_nil(new_string) ->
        %{"success" => false, "error" => "old_string and new_string are required"}

      true ->
        with :ok <- validate_path(path),
             expanded = Path.expand(path),
             {:ok, content} <- File.read(expanded) do
          occurrences = if replace_all, do: :all, else: 1

          case replace_string(content, old_string, new_string, occurrences) do
            {:ok, new_content, count} ->
              File.write!(expanded, new_content)

              %{
                "success" => true,
                "message" => "Patched #{path} (#{count} replacement(s))",
                "path" => expanded,
                "files_modified" => [expanded]
              }

            :not_found ->
              %{
                "success" => false,
                "error" => "old_string not found in #{path}",
                "_hint" => "Use read_file to verify current content."
              }
          end
        else
          {:error, reason} ->
            %{"success" => false, "error" => "patch failed: #{inspect(reason)}"}

          error ->
            %{"success" => false, "error" => "patch failed: #{inspect(error)}"}
        end
    end
  end

  def invoke("search_files", args) do
    path = Map.get(args, "path", ".")
    pattern = Map.get(args, "pattern", "")
    target = Map.get(args, "target", "content")
    limit = max(1, int_or(Map.get(args, "limit"), 50))

    cond do
      not is_binary(pattern) ->
        %{"success" => false, "error" => "pattern is required"}

      true ->
        with :ok <- validate_path(path),
             expanded = Path.expand(path) do
          if target == "files" do
            matches = find_files(expanded, pattern, limit)

            %{
              "success" => true,
              "matches" => matches,
              "total_count" => length(matches),
              "truncated" => false
            }
          else
            matches = grep_files(expanded, pattern, limit)

            %{
              "success" => true,
              "matches" => matches,
              "total_count" => length(matches),
              "truncated" => false
            }
          end
        else
          error ->
            %{"success" => false, "error" => "search failed: #{inspect(error)}"}
        end
    end
  end

  def invoke(name, _args) do
    %{"success" => false, "error" => "unknown file tool: #{name}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp validate_path(path) when is_binary(path) do
    if String.contains?(path, "..") or String.contains?(path, "//") do
      {:error, "path contains unsafe traversal components"}
    else
      workspace_root = Application.get_env(:hermes, :workspace_root, File.cwd!())
      expanded = Path.expand(path, workspace_root)

      if String.starts_with?(expanded, workspace_root) do
        :ok
      else
        {:error, "path must be within the workspace root"}
      end
    end
  end

  defp validate_path(_), do: {:error, "path must be a string"}

  defp int_or(nil, default), do: default
  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp int_or(_, default), do: default

  defp replace_string(content, old, new, :all) do
    if String.contains?(content, old) do
      new_content = String.replace(content, old, new, global: true)
      count = length(String.split(content, old)) - 1
      {:ok, new_content, count}
    else
      :not_found
    end
  end

  defp replace_string(content, old, new, 1) do
    if String.contains?(content, old) do
      new_content = String.replace(content, old, new, global: false)
      {:ok, new_content, 1}
    else
      :not_found
    end
  end

  defp find_files(root, pattern, limit) do
    with :ok <- validate_path(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Stream.filter(&File.regular?/1)
      |> Stream.filter(fn path -> String.contains?(Path.basename(path), pattern) end)
      |> Enum.take(limit)
      |> Enum.map(&Path.expand/1)
    else
      _ -> []
    end
  end

  defp grep_files(root, pattern, limit) do
    with :ok <- validate_path(root) do
      paths =
        if File.dir?(root) do
          root |> Path.join("**/*") |> Path.wildcard() |> Stream.filter(&File.regular?/1)
        else
          [root]
        end

      paths
      |> Enum.reduce_while([], fn path, acc ->
        case File.read(path) do
          {:ok, content} ->
            lines = String.split(content, "\n")

            matches =
              lines
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
              |> Enum.map(fn {line, idx} ->
                %{
                  "path" => Path.expand(path),
                  "line" => idx,
                  "content" => line
                }
              end)

            new_acc = acc ++ matches

            if length(new_acc) >= limit do
              {:halt, Enum.take(new_acc, limit)}
            else
              {:cont, new_acc}
            end

          _error ->
            {:cont, acc}
        end
      end)
    else
      _ -> []
    end
  end

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp read_file_schema do
    %{
      name: "read_file",
      description: "Read a text file with line numbers and pagination.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to read."},
          offset: %{
            type: "integer",
            description: "Line number to start reading from (1-indexed).",
            default: 1,
            minimum: 1
          },
          limit: %{
            type: "integer",
            description: "Maximum number of lines to read.",
            default: @default_read_lines,
            maximum: @max_read_lines
          }
        },
        required: ["path"]
      }
    }
  end

  defp write_file_schema do
    %{
      name: "write_file",
      description: "Write content to a file, replacing existing content.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to the file to write."},
          content: %{type: "string", description: "Complete content to write."}
        },
        required: ["path", "content"]
      }
    }
  end

  defp patch_schema do
    %{
      name: "patch",
      description: "Targeted find-and-replace edits in files.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path to edit."},
          old_string: %{type: "string", description: "Exact text to find and replace."},
          new_string: %{type: "string", description: "Replacement text."},
          replace_all: %{
            type: "boolean",
            description: "Replace all occurrences instead of requiring a unique match.",
            default: false
          }
        },
        required: ["path", "old_string", "new_string"]
      }
    }
  end

  defp search_files_schema do
    %{
      name: "search_files",
      description: "Search file contents or find files by name.",
      parameters: %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Substring match against file basename."},
          target: %{
            type: "string",
            enum: ["content", "files"],
            description: "'content' searches inside files; 'files' searches file names.",
            default: "content"
          },
          path: %{type: "string", description: "Directory or file to search in.", default: "."},
          limit: %{type: "integer", description: "Maximum number of results.", default: 50}
        },
        required: ["pattern"]
      }
    }
  end
end
