defmodule Floki do
  @moduledoc """
  A HTML parser and seeker.

  This is a simple HTML parser that enables searching using CSS like selectors.

  You can search elements by class, tag name and id.

  ## Example

  Assuming that you have the following HTML:

      <!doctype html>
      <html>
      <body>
        <section id="content">
          <p class="headline">Floki</p>
          <a href="http://github.com/philss/floki">Github page</a>
        </section>
      </body>
      </html>

  You can perform the following queries:

    * Floki.find(html, "#content") : returns the section with all children;
    * Floki.find(html, ".headline") : returns a list with the `p` element;
    * Floki.find(html, "a") : returns a list with the `a` element;
    * Floki.find(html, "#content a") # returns all links inside content section;
    * Floki.find(html, ".headline, a") # returns the .headline elements and links.

  Each HTML node is represented by a tuple like:

      {tag_name, attributes, children_nodes}

  Example of node:

      {"p", [{"class", "headline"}], ["Floki"]}

  So even if the only child node is the element text, it is represented
  inside a list.

  You can write a simple HTML crawler (with support of [HTTPoison](https://github.com/edgurgel/httpoison)) with a few lines of code:

      html
      |> Floki.find(".pages")
      |> Floki.find("a")
      |> Floki.attribute("href")
      |> Enum.map(fn(url) -> HTTPoison.get!(url) end)

  It is simple as that!
  """

  @type html_tree :: tuple | list

  @doc """
  Parses a HTML string.

  ## Examples

      iex> Floki.parse("<div class=js-action>hello world</div>")
      {"div", [{"class", "js-action"}], ["hello world"]}

  """

  @spec parse(binary) :: html_tree

  def parse(html) do
    :mochiweb_html.parse(html)
  end


  @doc """
  Finds elements inside a HTML tree or string.
  You can search by class, tag name or id.

  It is possible to compose searches:

      Floki.find(html_string, ".class")
      |> Floki.find(".another-class-inside-small-scope")

  ## Examples

      iex> Floki.find("<p><span class=hint>hello</span></p>", ".hint")
      [{"span", [{"class", "hint"}], ["hello"]}]

      iex> "<body><div id=important><div>Content</div></div></body>" |> Floki.find("#important")
      {"div", [{"id", "important"}], [{"div", [], ["Content"]}]}

      iex> Floki.find("<p><a href='https://google.com'>Google</a></p>", "a")
      [{"a", [{"href", "https://google.com"}], ["Google"]}]

  """

  @spec find(binary | html_tree, binary) :: html_tree

  def find(html, selector) when is_binary(html) do
    html_tree = parse(html)

    find(html_tree, selector)
  end

  def find(html_tree, selector) do
    cond do
      String.contains?(selector, ",") ->
        selectors = String.split(selector, ",")

        Enum.reduce selectors, [], fn(selector, acc) ->
          selector = String.strip(selector)

          nodes = find(html_tree, selector)

          unless is_list(nodes), do: nodes = [nodes]

          Enum.concat(acc, nodes)
        end
      String.contains?(selector, "\s") ->
        descendent_selector = String.split(selector)

        Enum.reduce descendent_selector, html_tree, fn(selector, tree) ->
          find(tree, selector)
        end
      String.starts_with?(selector, ".") ->
        "." <> class = selector
        {:ok, nodes} = find_by_selector(class, html_tree, &class_matcher/3, {:ok, []})

        Enum.reverse(nodes)
      String.starts_with?(selector, "#") ->
        "#" <> id = selector
        {_status, nodes} = find_by_selector(id, html_tree, &id_matcher/3, {:ok, []})

        List.first(nodes)
      true ->
        {:ok, nodes} = find_by_selector(selector, html_tree, &tag_matcher/3, {:ok, []})

        Enum.reverse(nodes)
    end
  end

  @doc """
  Returns a list with attribute values for a given selector.

  ## Examples

      iex> Floki.attribute("<a href='https://google.com'>Google</a>", "a", "href")
      ["https://google.com"]

  """

  @spec attribute(binary | html_tree, binary, binary) :: list

  def attribute(html, selector, attribute_name) do
    html
    |> find(selector)
    |> attribute_values(attribute_name)
  end

  @doc """
  Returns a list with attribute values from elements.

  ## Examples

      iex> Floki.attribute("<a href='https://google.com'>Google</a>", "href")
      ["https://google.com"]

  """

  @spec attribute(binary | html_tree, binary) :: list

  def attribute(elements, attribute_name) do
    elements
    |> attribute_values(attribute_name)
  end

  @doc """
  Returns the text nodes from a html tree.

  ## Examples

      iex> Floki.text("<div><span>something else</span>hello world</div>")
      "hello world"

  """

  @spec text(html_tree | binary) :: binary

  def text(html) when is_binary(html), do: parse(html) |> text
  def text(element) when is_tuple(element), do: _text(element, "")
  def text(elements) do
    Enum.reduce elements, "", fn(element, str) ->
      _text(element, str)
    end
  end

  defp _text({_, _, children}, acc) do
    Enum.reduce children, acc, fn(child, istr) ->
      if is_binary(child) do
        (istr <> "\s" <> child) |> String.strip
      else
        istr
      end
    end
  end

  defp attribute_match?(attributes, attribute_name) do
    Enum.find attributes, fn({attr_name, _}) ->
      attr_name == attribute_name
    end
  end

  defp attribute_match?(attributes, attribute_name, selector_value) do
    Enum.find attributes, fn(attribute) ->
      {attr_name, attr_value} = attribute

      attr_name == attribute_name && value_match?(attr_value, selector_value)
    end
  end

  defp find_by_selector(_selector, {}, _, acc), do: acc
  defp find_by_selector(_selector, [], _, acc), do: acc
  defp find_by_selector(_selector, _, _, {:done, nodes}), do: {:done, nodes}
  defp find_by_selector(_selector, tree, _, acc) when is_binary(tree), do: acc
  defp find_by_selector(selector, [h|t], matcher, acc) do
    acc = find_by_selector(selector, h, matcher, acc)
    find_by_selector(selector, t, matcher, acc)
  end
  # Ignores comments
  defp find_by_selector(_selector, {:comment, _comment}, _, acc), do: acc
  defp find_by_selector(selector, node, matcher, acc) do
    {_, _, child_node} = node

    acc = matcher.(selector, node, acc)

    find_by_selector(selector, child_node, matcher, acc)
  end

  defp attribute_values(element, attr_name) when is_tuple(element) do
    attribute_values([element], attr_name)
  end
  defp attribute_values(elements, attr_name) do
    values = Enum.reduce elements, [], fn({_, attributes, _}, acc) ->
      case attribute_match?(attributes, attr_name) do
        {_attr_name, value} ->
          [value|acc]
        _ ->
          acc
      end
    end

    Enum.reverse values
  end

  defp class_matcher(class_name, node, acc) do
    {_, attributes, _} = node
    {:ok, acc_nodes} = acc

    if attribute_match?(attributes, "class", class_name) do
      acc = {:ok, [node|acc_nodes]}
    end

    acc
  end

  defp tag_matcher(tag_name, node, acc) do
    {tag, _, _} = node
    {:ok, acc_nodes} = acc

    if tag == tag_name do
      acc = {:ok, [node|acc_nodes]}
    end

    acc
  end

  defp id_matcher(id, node, acc) do
    {_, attributes, _} = node
    {:ok, acc_nodes} = acc

    if attribute_match?(attributes, "id", id) do
      acc = {:done, [node|acc_nodes]}
    end

    acc
  end

  defp value_match?(attribute_value, selector_value) do
    attribute_value
    |> String.split
    |> Enum.any?(fn(x) -> x == selector_value end)
  end
end
