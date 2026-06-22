defmodule Hermes.Tools.SkillTools do
  @moduledoc """
  Skills tools: skills_list, skill_view, and skill_manage.

  Minimal port of `tools/skills_tool.py` and `tools/skill_manager_tool.py`.
  Skills are markdown files stored under `priv/skills/` (or the directory
  configured by `:hermes, :skills_dir`).
  """


  @doc """
  Returns the tool entries for registration.
  """
  @spec tool_entries() :: [map()]
  def tool_entries do
    [
      %{
        name: "skills_list",
        toolset: "skills",
        schema: skills_list_schema(),
        handler: fn args, _ctx -> invoke("skills_list", args) end,
        check_fn: &always_available/0
      },
      %{
        name: "skill_view",
        toolset: "skills",
        schema: skill_view_schema(),
        handler: fn args, _ctx -> invoke("skill_view", args) end,
        check_fn: &always_available/0
      },
      %{
        name: "skill_manage",
        toolset: "skills",
        schema: skill_manage_schema(),
        handler: fn args, _ctx -> invoke("skill_manage", args) end,
        check_fn: &always_available/0
      }
    ]
  end

  @doc """
  Dispatches a skill tool invocation.
  """
  @spec invoke(String.t(), map()) :: map()
  def invoke("skills_list", args) do
    root = skills_root()

    unless File.dir?(root) do
      File.mkdir_p!(root)
    end

    category = Map.get(args, "category")

    skills =
      root
      |> list_skill_dirs()
      |> maybe_filter_category(category)
      |> Enum.map(&skill_metadata/1)
      |> Enum.sort_by(&{&1["category"] || "", &1["name"]})

    categories =
      skills
      |> Enum.map(& &1["category"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "success" => true,
      "skills" => skills,
      "categories" => categories,
      "count" => length(skills),
      "hint" => "Use skill_view(name) to see full content."
    }
  end

  def invoke("skill_view", args) do
    name = Map.get(args, "name")

    if is_nil(name) or not is_binary(name) or String.trim(name) == "" do
      %{"success" => false, "error" => "name is required"}
    else
      with :ok <- validate_skill_name(name),
           skill_dir = skill_dir_for(name),
           true <- File.dir?(skill_dir) do
        file_path = Map.get(args, "file_path")

        target =
          if is_binary(file_path) and String.trim(file_path) != "" do
            Path.join(skill_dir, file_path)
          else
            Path.join(skill_dir, "SKILL.md")
          end

        if File.regular?(target) do
          content = File.read!(target)

          %{
            "success" => true,
            "name" => name,
            "file" => target,
            "content" => content
          }
        else
          %{"success" => false, "error" => "file not found: #{target}"}
        end
      else
        false -> %{"success" => false, "error" => "skill not found: #{name}"}
        error -> %{"success" => false, "error" => "view failed: #{inspect(error)}"}
      end
    end
  end

  def invoke("skill_manage", args) do
    action = Map.get(args, "action")
    name = Map.get(args, "name")

    cond do
      is_nil(action) or not is_binary(action) ->
        %{"success" => false, "error" => "action is required"}

      is_nil(name) or not is_binary(name) or String.trim(name) == "" ->
        %{"success" => false, "error" => "name is required"}

      true ->
        case validate_skill_name(name) do
          :ok -> run_manage_action(action, name, args)
          error -> error
        end
    end
  end

  def invoke(name, _args) do
    %{"success" => false, "error" => "unknown skill tool: #{name}"}
  end

  # ---------------------------------------------------------------------------
  # skill_manage actions
  # ---------------------------------------------------------------------------

  defp run_manage_action("create", name, args) do
    content = Map.get(args, "content")

    if is_nil(content) or not is_binary(content) or String.trim(content) == "" do
      %{"success" => false, "error" => "content is required for create"}
    else
      skill_dir = skill_dir_for(name)

      if File.dir?(skill_dir) do
        %{"success" => false, "error" => "skill '#{name}' already exists"}
      else
        File.mkdir_p!(skill_dir)
        skill_md = Path.join(skill_dir, "SKILL.md")
        File.write!(skill_md, content)

        %{
          "success" => true,
          "message" => "Skill '#{name}' created.",
          "path" => skill_dir
        }
      end
    end
  end

  defp run_manage_action("edit", name, args) do
    content = Map.get(args, "content")

    if is_nil(content) or not is_binary(content) or String.trim(content) == "" do
      %{"success" => false, "error" => "content is required for edit"}
    else
      skill_dir = skill_dir_for(name)

      if File.dir?(skill_dir) do
        skill_md = Path.join(skill_dir, "SKILL.md")
        File.write!(skill_md, content)

        %{
          "success" => true,
          "message" => "Skill '#{name}' updated.",
          "path" => skill_dir
        }
      else
        %{"success" => false, "error" => "skill not found: #{name}"}
      end
    end
  end

  defp run_manage_action("patch", name, args) do
    old_string = Map.get(args, "old_string")
    new_string = Map.get(args, "new_string")

    cond do
      is_nil(old_string) or is_nil(new_string) ->
        %{"success" => false, "error" => "old_string and new_string are required for patch"}

      true ->
        skill_dir = skill_dir_for(name)

        if File.dir?(skill_dir) do
          file_path = Map.get(args, "file_path")

          target =
            if is_binary(file_path) and String.trim(file_path) != "" do
              Path.join(skill_dir, file_path)
            else
              Path.join(skill_dir, "SKILL.md")
            end

          if File.regular?(target) do
            content = File.read!(target)

            if String.contains?(content, old_string) do
              new_content = String.replace(content, old_string, new_string, global: false)
              File.write!(target, new_content)

              %{
                "success" => true,
                "message" => "Patched skill '#{name}'.",
                "path" => target
              }
            else
              %{"success" => false, "error" => "old_string not found in skill file"}
            end
          else
            %{"success" => false, "error" => "file not found: #{target}"}
          end
        else
          %{"success" => false, "error" => "skill not found: #{name}"}
        end
    end
  end

  defp run_manage_action("delete", name, _args) do
    skill_dir = skill_dir_for(name)

    if File.dir?(skill_dir) do
      File.rm_rf!(skill_dir)
      %{"success" => true, "message" => "Skill '#{name}' deleted."}
    else
      %{"success" => false, "error" => "skill not found: #{name}"}
    end
  end

  defp run_manage_action("write_file", name, args) do
    file_path = Map.get(args, "file_path")
    file_content = Map.get(args, "file_content")

    cond do
      is_nil(file_path) or not is_binary(file_path) or String.trim(file_path) == "" ->
        %{"success" => false, "error" => "file_path is required"}

      is_nil(file_content) ->
        %{"success" => false, "error" => "file_content is required"}

      true ->
        skill_dir = skill_dir_for(name)

        if File.dir?(skill_dir) do
          target = Path.join(skill_dir, file_path)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, file_content)

          %{
            "success" => true,
            "message" => "File '#{file_path}' written to skill '#{name}'.",
            "path" => target
          }
        else
          %{"success" => false, "error" => "skill not found: #{name}"}
        end
    end
  end

  defp run_manage_action("remove_file", name, args) do
    file_path = Map.get(args, "file_path")

    if is_nil(file_path) or not is_binary(file_path) or String.trim(file_path) == "" do
      %{"success" => false, "error" => "file_path is required"}
    else
      skill_dir = skill_dir_for(name)

      if File.dir?(skill_dir) do
        target = Path.join(skill_dir, file_path)

        if File.regular?(target) do
          File.rm!(target)
          %{"success" => true, "message" => "File '#{file_path}' removed from skill '#{name}'."}
        else
          %{"success" => false, "error" => "file not found: #{file_path}"}
        end
      else
        %{"success" => false, "error" => "skill not found: #{name}"}
      end
    end
  end

  defp run_manage_action(action, _name, _args) do
    %{"success" => false, "error" => "unknown skill_manage action: #{action}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp skills_root do
    Application.get_env(:hermes, :skills_dir) || Application.app_dir(:hermes, "priv/skills")
  end

  defp list_skill_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      _error ->
        []
    end
  end

  defp maybe_filter_category(dirs, nil), do: dirs
  defp maybe_filter_category(dirs, ""), do: dirs

  defp maybe_filter_category(dirs, category) do
    category = to_string(category)

    Enum.filter(dirs, fn dir ->
      Path.basename(Path.dirname(dir)) == category or
        skill_metadata(dir)["category"] == category
    end)
  end

  defp skill_metadata(dir) do
    name = Path.basename(dir)
    skill_md = Path.join(dir, "SKILL.md")

    description =
      if File.regular?(skill_md) do
        case File.read(skill_md) do
          {:ok, content} -> first_description(content)
          _error -> nil
        end
      else
        nil
      end

    category = category_for(dir)

    %{
      "name" => name,
      "path" => dir,
      "category" => category,
      "description" => description
    }
  end

  defp category_for(dir) do
    parent = Path.dirname(dir)
    root = skills_root()

    if parent == root do
      nil
    else
      Path.basename(parent)
    end
  end

  defp first_description(content) do
    content
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      trimmed = String.trim(line)

      if String.starts_with?(trimmed, "#") do
        String.replace(trimmed, ~r/^#+\s*/, "")
      else
        nil
      end
    end)
  end

  defp skill_dir_for(name) do
    Path.join(skills_root(), name)
  end

  defp validate_skill_name(name) do
    if String.contains?(name, "..") or String.contains?(name, "/") or
         String.contains?(name, "\\") do
      %{"success" => false, "error" => "invalid skill name: #{name}"}
    else
      :ok
    end
  end

  defp always_available, do: true

  # ---------------------------------------------------------------------------
  # Schemas
  # ---------------------------------------------------------------------------

  defp skills_list_schema do
    %{
      name: "skills_list",
      description: "List available skills (name + description).",
      parameters: %{
        type: "object",
        properties: %{
          category: %{type: "string", description: "Optional category filter."}
        },
        required: []
      }
    }
  end

  defp skill_view_schema do
    %{
      name: "skill_view",
      description: "View the full content of a skill or a file within it.",
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Skill name."},
          file_path: %{
            type: "string",
            description: "Optional relative path to a file inside the skill directory."
          }
        },
        required: ["name"]
      }
    }
  end

  defp skill_manage_schema do
    %{
      name: "skill_manage",
      description: "Manage skills (create, edit, patch, delete, write_file, remove_file).",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["create", "edit", "patch", "delete", "write_file", "remove_file"],
            description: "Action to perform."
          },
          name: %{type: "string", description: "Skill name."},
          content: %{type: "string", description: "Full SKILL.md content (create/edit)."},
          old_string: %{type: "string", description: "Text to find (patch)."},
          new_string: %{type: "string", description: "Replacement text (patch)."},
          file_path: %{type: "string", description: "Supporting file path (write_file/remove_file)."},
          file_content: %{type: "string", description: "Content for supporting file (write_file)."}
        },
        required: ["action", "name"]
      }
    }
  end
end
