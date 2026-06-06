defmodule Mix.Tasks.Docs.Nav do
  @moduledoc """
  Injects navigation headers and footers into documentation files.

  Reads the doc ordering and grouping from mix.exs ExDoc configuration,
  then injects/replaces navigation links in each markdown file between
  sentinel markers.

  ## Usage

      mix docs.nav          # inject nav into all docs
      mix docs.nav --check  # check if nav is up to date (exits 1 if not)
      mix docs.nav --strip  # remove all nav markers

  ## Navigation format

  Each doc gets a header (after the `# Title` line) and footer with:

  - Back link to previous doc in sequence
  - Up link to the group's first doc (or index)
  - Index link to README
  - Forward link to next doc in sequence

  The doc order and grouping are read from `mix.exs` `:docs` config.

  ## Sentinel markers

  Nav blocks are wrapped in HTML comments so they can be found and
  replaced idempotently:

      <!-- nav:header:start -->
      ...nav links...
      <!-- nav:header:end -->

  """

  use Mix.Task

  @shortdoc "Inject navigation into documentation files"

  @header_start "<!-- nav:header:start -->"
  @header_end "<!-- nav:header:end -->"
  @footer_start "<!-- nav:footer:start -->"
  @footer_end "<!-- nav:footer:end -->"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean, strip: :boolean])

    {extras, groups} = read_doc_config()
    titles = extract_titles(extras)

    if opts[:strip] do
      strip_all(extras)
    else
      nav_blocks = build_nav_blocks(extras, groups, titles)

      if opts[:check] do
        check_all(extras, nav_blocks)
      else
        inject_all(extras, nav_blocks)
      end
    end
  end

  # --- Config reading ---

  defp read_doc_config do
    config = Mix.Project.config()
    docs = Keyword.get(config, :docs, [])
    extras = Keyword.get(docs, :extras, [])
    groups = Keyword.get(docs, :groups_for_extras, [])
    {extras, groups}
  end

  # --- Title extraction ---

  defp extract_titles(extras) do
    Map.new(extras, fn path ->
      title =
        path
        |> File.read!()
        |> String.split("\n", parts: 3)
        |> Enum.find_value(fn line ->
          case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
            [_, title] -> title
            _ -> nil
          end
        end)

      {path, title || Path.basename(path, ".md")}
    end)
  end

  # --- Nav block building ---

  defp build_nav_blocks(extras, groups, titles) do
    # Build a map from path -> group name
    group_map = build_group_map(groups)

    # Build a map from group name -> first doc path in that group
    group_first = build_group_first(groups)

    # Index is always the first extra (README)
    index_path = List.first(extras)

    extras
    |> Enum.with_index()
    |> Map.new(fn {path, idx} ->
      prev = if idx > 0, do: Enum.at(extras, idx - 1)
      next = if idx < length(extras) - 1, do: Enum.at(extras, idx + 1)

      group_name = Map.get(group_map, path)
      up_path = Map.get(group_first, group_name)

      # Don't link "up" to yourself
      up_path = if up_path == path, do: nil, else: up_path

      nav = build_nav_line(path, prev, next, up_path, index_path, titles, group_name)
      {path, nav}
    end)
  end

  defp build_group_map(groups) do
    Enum.flat_map(groups, fn {group_name, paths} ->
      Enum.map(paths, fn path -> {path, to_string(group_name)} end)
    end)
    |> Map.new()
  end

  defp build_group_first(groups) do
    Map.new(groups, fn {group_name, paths} ->
      {to_string(group_name), List.first(paths)}
    end)
  end

  defp build_nav_line(current_path, prev, next, up_path, index_path, titles, group_name) do
    parts = []

    # Back
    parts =
      if prev do
        rel = relative_path(current_path, prev)
        parts ++ ["[< #{Map.get(titles, prev, "Previous")}](#{rel})"]
      else
        parts
      end

    # Up (to group first, if different from current)
    parts =
      if up_path do
        rel = relative_path(current_path, up_path)
        label = if group_name, do: "Up: #{group_name}", else: "Up"
        parts ++ ["[#{label}](#{rel})"]
      else
        parts
      end

    # Index (always, unless we ARE the index)
    parts =
      if current_path != index_path do
        rel = relative_path(current_path, index_path)
        parts ++ ["[Index](#{rel})"]
      else
        parts
      end

    # Forward
    parts =
      if next do
        rel = relative_path(current_path, next)
        parts ++ ["[#{Map.get(titles, next, "Next")} >](#{rel})"]
      else
        parts
      end

    Enum.join(parts, " | ")
  end

  defp relative_path(from, to) do
    from_dir = Path.dirname(from)
    Path.relative_to(to, from_dir)
  end

  # --- Injection ---

  defp inject_all(extras, nav_blocks) do
    changed =
      Enum.count(extras, fn path ->
        nav = Map.fetch!(nav_blocks, path)
        inject_file(path, nav)
      end)

    Mix.shell().info("Updated navigation in #{changed}/#{length(extras)} files")
  end

  defp inject_file(path, nav) do
    content = File.read!(path)
    header_block = "#{@header_start}\n#{nav}\n#{@header_end}"
    footer_block = "#{@footer_start}\n\n---\n\n#{nav}\n#{@footer_end}"

    new_content =
      content
      |> strip_existing_nav()
      |> inject_header(header_block)
      |> inject_footer(footer_block)

    if new_content != content do
      File.write!(path, new_content)
      true
    else
      false
    end
  end

  defp strip_existing_nav(content) do
    content
    |> remove_block(@header_start, @header_end)
    |> remove_block(@footer_start, @footer_end)
  end

  defp remove_block(content, start_marker, end_marker) do
    # Remove the block including surrounding blank lines
    regex =
      ~r/\n*#{Regex.escape(start_marker)}.*?#{Regex.escape(end_marker)}\n*/s

    Regex.replace(regex, content, "\n")
  end

  defp inject_header(content, header_block) do
    # Insert after the first # Title line
    case Regex.run(~r/^(#[^\n]+\n)(.*)$/s, content) do
      [_, title_line, rest] ->
        title_line <> "\n" <> header_block <> "\n\n" <> String.trim_leading(rest, "\n")

      _ ->
        # No title found, prepend
        header_block <> "\n\n" <> content
    end
  end

  defp inject_footer(content, footer_block) do
    String.trim_trailing(content) <> "\n\n" <> footer_block <> "\n"
  end

  # --- Check mode ---

  defp check_all(extras, nav_blocks) do
    outdated =
      Enum.filter(extras, fn path ->
        nav = Map.fetch!(nav_blocks, path)
        content = File.read!(path)
        expected = inject_expected(content, nav)
        content != expected
      end)

    if outdated == [] do
      Mix.shell().info("All navigation is up to date")
    else
      Mix.shell().error("Navigation is outdated in #{length(outdated)} files:")

      Enum.each(outdated, fn path ->
        Mix.shell().error("  #{path}")
      end)

      Mix.raise("Run `mix docs.nav` to update")
    end
  end

  defp inject_expected(content, nav) do
    header_block = "#{@header_start}\n#{nav}\n#{@header_end}"
    footer_block = "#{@footer_start}\n\n---\n\n#{nav}\n#{@footer_end}"

    content
    |> strip_existing_nav()
    |> inject_header(header_block)
    |> inject_footer(footer_block)
  end

  # --- Strip mode ---

  defp strip_all(extras) do
    changed =
      Enum.count(extras, fn path ->
        content = File.read!(path)
        new_content = strip_existing_nav(content)

        if new_content != content do
          File.write!(path, new_content)
          true
        else
          false
        end
      end)

    Mix.shell().info("Stripped navigation from #{changed}/#{length(extras)} files")
  end
end
