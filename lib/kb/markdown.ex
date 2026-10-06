defmodule KB.Markdown do
  @moduledoc """
  Reads a markdown page into the parts the KB stores and searches.

  A page is optional YAML frontmatter followed by a body. The frontmatter
  becomes filterable metadata and stays out of search chunks, since it is
  mostly slugs and dates. The body is chunked at its headings, and every chunk
  starts with a breadcrumb of the headings above it, so a hit reads in context
  and the heading words count toward the match.
  """

  alias Arcana.Chunker

  # Arcana's default chunker sizes chunks at 450 tokens, which it converts to
  # characters at 4 per token. A page or section that fits in one of its
  # chunks stays whole.
  @max_chars 1800

  @frontmatter ~r/\A---[ \t]*\r?\n(?:(.*?)\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|\z)/s
  @heading ~r/^ {0,3}(\#{1,6})[ \t]+(.*?)(?:[ \t]+\#+)?[ \t]*$/
  @fence ~r/^ {0,3}(`{3,}|~{3,})/
  @wikilink_full ~r/(!?)\[\[([^\[\]\n]+?)\]\]/u

  @type parsed :: %{
          frontmatter: map(),
          body: String.t(),
          title: String.t() | nil,
          warnings: [String.t()]
        }

  @doc """
  Splits `text` into frontmatter and body, and finds the page title.

  The title is the frontmatter `title` when it is a string, else the text of
  the first level-one heading. Frontmatter that is not valid YAML, or not a
  mapping, is dropped with a warning rather than failing the page: the body
  is still worth indexing.
  """
  @spec parse(String.t()) :: parsed()
  def parse(text) when is_binary(text) do
    {frontmatter, body, warnings} = split_frontmatter(text)

    title =
      case frontmatter["title"] do
        title when is_binary(title) and title != "" -> String.trim(title)
        _ -> first_h1(body)
      end

    %{frontmatter: frontmatter, body: body, title: title, warnings: warnings}
  end

  @doc """
  The tags a page declares in its frontmatter.

  Accepts a YAML list or a comma- or space-separated string.
  """
  @spec tags(map()) :: [String.t()]
  def tags(%{"tags" => tags}) when is_list(tags) do
    tags |> Enum.map(&to_string/1) |> clean_tags()
  end

  def tags(%{"tags" => tags}) when is_binary(tags) do
    tags |> String.split(~r/[\s,]+/) |> clean_tags()
  end

  def tags(_frontmatter), do: []

  @doc """
  Splits a page body into search chunks.

  Link lists are treated as wiki boilerplate rather than content. A
  `## Sources` section is left out of the chunks, since the frontmatter
  already lists its links. A `## Related` or `## See also` section, and any
  other section that is nothing but wikilinks, is folded into the chunk
  before it, so it never becomes a chunk of bare links. All of them stay in
  the stored text.

  A body that then fits in one chunk stays whole. A longer one splits at its
  headings:

    * A heading with no text of its own joins the section it opens, so a
      chunk never ends on a bare heading.
    * Small neighboring sections are packed together, but never across a
      `#` or `##` heading, except that a page's lead can join its first
      section.
    * A section too big for one chunk is split by Arcana's chunker.

  Each chunk's `metadata["heading_path"]` is the part of the heading path
  that every section in it shares, led by the page title. Its text starts
  with that path as a breadcrumb line, unless the chunk opens on the page's
  own title heading.
  """
  @spec chunk(String.t(), String.t() | nil) :: [map()]
  def chunk(body, title) do
    body
    |> groups()
    |> Enum.with_index()
    |> Enum.map(fn {{path, text}, index} -> build_chunk(path, text, title, index) end)
  end

  @doc """
  The text of the section under `heading`, including its subsections.

  Matches the first heading whose text equals `heading`, ignoring case and
  surrounding whitespace. The section runs to the next heading at the same
  level or higher.
  """
  @spec section(String.t(), String.t()) :: {:ok, String.t()} | :error
  def section(text, heading) do
    wanted = normalize_heading(heading)
    sections = text |> parse() |> Map.fetch!(:body) |> sections()

    case Enum.split_while(sections, &(normalize_heading(&1.heading || "") != wanted)) do
      {_before, []} ->
        :error

      {_before, [found | rest]} ->
        below = Enum.take_while(rest, &(&1.level > found.level))
        {:ok, Enum.map_join([found | below], & &1.text)}
    end
  end

  @doc """
  The wikilinks in `text`, in order: `[[target]]`, `[[target|alias]]`,
  `[[target#heading]]`, and embeds `![[target]]`. A block reference
  (`[[target#^block]]` or `[[target^block]]`) counts as a link to its page.

  Links inside fenced code are skipped, and so is a link to a heading on the
  same page (`[[#heading]]`), which has no target. Frontmatter is searched
  like the body, since Obsidian treats links there as links too.

  Each link's `slug` is how it resolves, by the same rule as `slug/1`, so
  `[[concepts/Scrum]]` and `[[scrum]]` both point at `concepts/scrum.md`.
  """
  @spec links(String.t()) :: [map()]
  def links(text) do
    @wikilink_full
    |> Regex.scan(outside_fences(text), capture: :all_but_first)
    |> Enum.flat_map(fn [bang, inner] -> link(inner, bang == "!") end)
    |> Enum.with_index()
    |> Enum.map(fn {link, position} -> Map.put(link, :position, position) end)
  end

  defp link(inner, embed?) do
    {target_part, link_alias} = split_once(inner, "|")
    {target, heading} = split_once(target_part, "#")
    target = target |> String.replace(~r/\^.*$/u, "") |> String.trim()

    if target == "" do
      []
    else
      [
        %{
          target: target,
          slug: slug(target),
          heading: blank_to_nil(heading),
          alias: blank_to_nil(link_alias),
          embed: embed?
        }
      ]
    end
  end

  defp split_once(text, separator) do
    case String.split(text, separator, parts: 2) do
      [before, rest] -> {before, rest}
      [whole] -> {whole, nil}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # The text with every fenced code block, fences included, blanked out.
  defp outside_fences(text) do
    {lines, _fence} =
      text
      |> String.split(~r/(?<=\n)/)
      |> Enum.map_reduce(nil, fn line, fence ->
        case classify(line, fence) do
          {:fence, next} -> {"\n", next}
          _other when fence != nil -> {"\n", fence}
          _other -> {line, fence}
        end
      end)

    Enum.join(lines)
  end

  @doc """
  The slug a wikilink uses for the page at `key`: its file name without the
  `.md` extension, lowercased.
  """
  @spec slug(String.t()) :: String.t()
  def slug(key) do
    key |> Path.basename() |> String.replace_suffix(".md", "") |> String.downcase()
  end

  defp split_frontmatter(text) do
    case Regex.run(@frontmatter, text, return: :index) do
      [{0, length} | captures] ->
        yaml =
          case captures do
            [{start, len}] when start >= 0 -> binary_part(text, start, len)
            _ -> ""
          end

        body = binary_part(text, length, byte_size(text) - length)
        {frontmatter, warnings} = read_yaml(yaml)
        {frontmatter, body, warnings}

      nil ->
        {%{}, text, []}
    end
  end

  defp read_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {json_safe(map), []}
      {:ok, nil} -> {%{}, []}
      {:ok, _other} -> {%{}, ["frontmatter is not a mapping"]}
      {:error, error} -> {%{}, ["invalid frontmatter: #{Exception.message(error)}"]}
    end
  end

  # Frontmatter is stored as JSON, so every key becomes a string and anything
  # YAML can express that JSON can't is stored as its printed form.
  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value), do: inspect(value)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_number(key) or is_boolean(key), do: to_string(key)
  defp json_key(key), do: inspect(key)

  defp clean_tags(tags) do
    tags |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp first_h1(body) do
    Enum.find_value(sections(body), fn
      %{level: 1, heading: heading} when heading != "" -> heading
      _ -> nil
    end)
  end

  # A section is a heading line and the text up to the next heading, with the
  # path of headings above and including it. Text before the first heading is
  # a section with no heading. Headings inside fenced code are text.
  defp sections(body) do
    {sections, current, _stack, _fence} =
      body
      |> String.split(~r/(?<=\n)/)
      |> Enum.reduce({[], new_section([], 0, nil), [], nil}, fn line,
                                                                {done, current, stack, fence} ->
        case classify(line, fence) do
          {:fence, fence} ->
            {done, append(current, line), stack, fence}

          {:heading, level, heading} ->
            stack = [{level, heading} | Enum.drop_while(stack, fn {l, _} -> l >= level end)]
            path = stack |> Enum.reverse() |> Enum.map(&elem(&1, 1))
            {[current | done], append(new_section(path, level, heading), line), stack, fence}

          :text ->
            {done, append(current, line), stack, fence}
        end
      end)

    [current | sections]
    |> Enum.reverse()
    |> Enum.reject(&(&1.heading == nil and String.trim(&1.text) == ""))
  end

  defp new_section(path, level, heading),
    do: %{path: path, level: level, heading: heading, text: "", tail: ""}

  defp append(section, line), do: %{section | text: section.text <> line}

  # Tracks fenced code blocks: a fence closes only on the character that
  # opened it, repeated at least as many times.
  defp classify(line, nil) do
    cond do
      match = Regex.run(@fence, line, capture: :all_but_first) ->
        [marker] = match
        {:fence, {String.first(marker), String.length(marker)}}

      match =
          Regex.run(@heading, String.trim_trailing(line, "\n") |> String.trim_trailing("\r"),
            capture: :all_but_first
          ) ->
        [hashes, heading] = match
        {:heading, String.length(hashes), String.trim(heading)}

      true ->
        :text
    end
  end

  defp classify(line, {char, length} = fence) do
    case Regex.run(@fence, line, capture: :all_but_first) do
      [marker] ->
        if String.first(marker) == char and String.length(marker) >= length,
          do: {:fence, nil},
          else: {:fence, fence}

      nil ->
        {:fence, fence}
    end
  end

  # Level-two sections that are link lists, not content. Sources are
  # dropped from chunks; related-page lists fold into the chunk before them.
  @dropped_sections ~w(sources)
  @folded_sections ["related", "see also"]

  @wikilink ~r/!?\[\[[^\]]*\]\]/
  @line_label ~r/^\s*(?:[-*+]|\d+\.)?\s*(?:\p{L}[\p{L}\p{N} ]{0,30}:)?/mu

  # Packs sections into chunk-sized groups of `{heading_path, text}`.
  defp groups(body) do
    sections =
      body
      |> sections()
      |> drop_sources()
      |> join_bare_headings()
      |> fold_link_lists()

    indexed = Enum.map_join(sections, &full_text/1)

    cond do
      String.trim(indexed) == "" ->
        []

      String.length(indexed) <= @max_chars ->
        [{[], indexed}]

      true ->
        sections
        |> blocks()
        |> Enum.flat_map(&pack/1)
        |> join_lead()
        |> Enum.map(fn group -> {group.path, group.text} end)
    end
  end

  defp full_text(section), do: section.text <> section.tail

  # Removes `## Sources` sections and their subsections.
  defp drop_sources(sections) do
    {kept, _dropping} =
      Enum.flat_map_reduce(sections, false, fn section, dropping ->
        dropping =
          if section.level in [1, 2], do: named?(section, @dropped_sections), else: dropping

        {if(dropping, do: [], else: [section]), dropping}
      end)

    kept
  end

  # A section that is only a heading merges into the section after it. The
  # merged section takes the later, deeper path, which is where its content
  # lives, but the bare heading's level, so a bare `##` still starts a block.
  defp join_bare_headings([bare, next | rest]) do
    if bare?(bare) do
      merged = %{next | text: bare.text <> next.text, level: min(bare.level, next.level)}
      join_bare_headings([merged | rest])
    else
      [bare | join_bare_headings([next | rest])]
    end
  end

  defp join_bare_headings(sections), do: sections

  defp bare?(%{heading: nil}), do: false
  defp bare?(section), do: String.trim(section_body(section)) == ""

  # A `## Related` or `## See also` section (with its subsections), and any
  # section that is nothing but wikilinks, rides along as the tail of the
  # section before it. A tail is kept out of size decisions and ends up in
  # the last chunk of that section, so it can never be a chunk of its own.
  defp fold_link_lists(sections) do
    {kept, _folding} =
      Enum.reduce(sections, {[], false}, fn section, {kept, folding} ->
        folding = if section.level in [1, 2], do: named?(section, @folded_sections), else: folding

        case kept do
          [previous | rest] when folding or section.heading != nil ->
            if folding or link_list?(section),
              do: {[%{previous | tail: previous.tail <> section.text} | rest], folding},
              else: {[section | kept], folding}

          _ ->
            {[section | kept], folding}
        end
      end)

    Enum.reverse(kept)
  end

  defp named?(%{level: 2, heading: heading}, names), do: normalize_heading(heading) in names
  defp named?(_section, _names), do: false

  # Links make up nearly all of the section's text once list markers,
  # line labels such as "Entities:", and punctuation are set aside.
  defp link_list?(section) do
    body = section_body(section)
    links = @wikilink |> Regex.scan(body) |> List.flatten()

    rest =
      @wikilink
      |> Regex.replace(body, "")
      |> String.replace(@line_label, "")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "")

    link_chars = links |> Enum.map(&String.length/1) |> Enum.sum()

    links != [] and String.length(rest) * 5 <= link_chars
  end

  defp section_body(section), do: section.text |> split_head() |> elem(1)

  # A section's head is its heading line, plus any bare headings merged in
  # ahead of it: every heading and blank line before the first line of text.
  defp split_head(text) do
    {head, body} =
      text
      |> String.split(~r/(?<=\n)/)
      |> Enum.split_while(&(String.trim(&1) == "" or match?({:heading, _, _}, classify(&1, nil))))

    {Enum.join(head), Enum.join(body)}
  end

  # A block starts at every `#` or `##` heading. Packing never crosses one.
  defp blocks(sections) do
    Enum.chunk_while(
      sections,
      [],
      fn section, acc ->
        if section.level in [1, 2] and acc != [],
          do: {:cont, Enum.reverse(acc), [section]},
          else: {:cont, [section | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp pack(sections) do
    {groups, current} =
      Enum.reduce(sections, {[], nil}, fn section, {groups, current} ->
        size = String.length(section.text)

        cond do
          size > @max_chars ->
            {Enum.reverse(split_section(section), flush(groups, current)), nil}

          current == nil ->
            {groups, group([section.path], full_text(section), size)}

          current.size + size > @max_chars ->
            {flush(groups, current), group([section.path], full_text(section), size)}

          true ->
            paths = [section.path | current.paths]
            {groups, group(paths, current.text <> full_text(section), current.size + size)}
        end
      end)

    groups |> flush(current) |> Enum.reverse()
  end

  defp group(paths, text, size),
    do: %{paths: paths, path: common_prefix(paths), text: text, size: size}

  defp flush(groups, nil), do: groups
  defp flush(groups, group), do: [group | groups]

  # Splits the section's body, not its head, so the chunker can't cut a
  # heading off on its own. The head goes back on the first piece and the
  # tail on the last.
  defp split_section(section) do
    {head, body} = split_head(section.text)

    Chunker.chunk(Arcana.Config.chunker(), body, format: :markdown)
    |> Enum.map(& &1.text)
    |> List.update_at(0, &(head <> &1))
    |> List.update_at(-1, &(&1 <> section.tail))
    |> Enum.map(&group([section.path], &1, String.length(&1)))
  end

  # A page's lead (text above its first `##`) is often a sentence or two.
  # It joins the first section when both fit in one chunk.
  defp join_lead([lead, next | rest]) do
    if length(lead.path) <= 1 and lead.size + next.size <= @max_chars,
      do: [group(lead.paths ++ next.paths, lead.text <> next.text, lead.size + next.size) | rest],
      else: [lead, next | rest]
  end

  defp join_lead(groups), do: groups

  defp common_prefix([path]), do: path

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn path, prefix ->
      prefix
      |> Enum.zip(path)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))
    end)
  end

  defp build_chunk(path, text, title, index) do
    heading_path = heading_path(path, title)
    text = String.trim(text)

    text =
      if heading_path == [] or opens_on_title?(heading_path, text),
        do: text,
        else: Enum.join(heading_path, " > ") <> "\n\n" <> text

    %{
      text: text,
      chunk_index: index,
      token_count: div(String.length(text), 4),
      metadata: %{"heading_path" => heading_path}
    }
  end

  # The path always leads with the page title. A page whose first heading is
  # its title already has it; one without gets it prepended.
  defp heading_path(path, nil), do: path
  defp heading_path([title | _] = path, title), do: path
  defp heading_path(path, title), do: [title | path]

  defp opens_on_title?(heading_path, text) do
    match?([_], heading_path) and match?({:heading, 1, _}, classify(first_line(text), nil))
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp normalize_heading(heading), do: heading |> String.trim() |> String.downcase()
end
