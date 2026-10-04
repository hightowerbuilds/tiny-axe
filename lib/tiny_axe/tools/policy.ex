defmodule TinyAxe.Tools.Policy do
  @moduledoc """
  The risk class of a tool call, decided in code, never by the model:

    * `:read` — looks, changes nothing: runs
    * `:local` — changes something on this machine or in a session that can be
      redone (a draft, a form field): runs
    * `:outward` — sends something to someone or somewhere (a message, a post,
      a pull request): asks the user every time, unless they allowed that tool
      for the session
    * `:commit` — spends money: the purchase gate (not built yet, so refused)
    * `:refused` — never runs

  For an MCP tool, the server's `policy` in `mcp.json` names its tools by
  class, with `*` wildcards (`"read": ["get_*"]`, `"deny": ["delete_*"]`). The
  tool's own annotations can only make its class stricter: a server can't talk
  its way into a looser one. A tool the policy doesn't name is `:outward`.
  """

  @type class :: :read | :local | :outward | :commit | :refused

  @order [:read, :local, :outward, :commit, :refused]

  @doc "The class of `tool` (an MCP tool definition) under `policy`."
  @spec classify(map(), map()) :: class()
  def classify(%{"name" => name} = tool, policy) do
    named =
      cond do
        listed?(policy["deny"], name) -> :refused
        listed?(policy["commit"], name) -> :commit
        listed?(policy["outward"], name) -> :outward
        listed?(policy["local"], name) -> :local
        listed?(policy["read"], name) -> :read
        true -> :outward
      end

    stricter(named, from_annotations(tool["annotations"] || %{}))
  end

  # What the annotations claim, as a floor: claims of safety lower nothing.
  defp from_annotations(ann) do
    cond do
      ann["destructiveHint"] == true -> :outward
      ann["openWorldHint"] == true and ann["readOnlyHint"] != true -> :outward
      ann["readOnlyHint"] == false -> :local
      true -> :read
    end
  end

  @doc "The stricter of two classes."
  @spec stricter(class(), class()) :: class()
  def stricter(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  defp rank(class), do: Enum.find_index(@order, &(&1 == class))

  defp listed?(nil, _name), do: false

  defp listed?(patterns, name) do
    Enum.any?(List.wrap(patterns), fn pattern ->
      regex = "\\A" <> (pattern |> Regex.escape() |> String.replace("\\*", ".*")) <> "\\z"
      Regex.match?(Regex.compile!(regex), name)
    end)
  end

  @doc "What a class means, for the user."
  @spec describe(class()) :: String.t()
  def describe(:read), do: "only reads"
  def describe(:local), do: "changes something it can redo"
  def describe(:outward), do: "sends something off this machine"
  def describe(:commit), do: "spends money"
  def describe(:refused), do: "not allowed"
end
