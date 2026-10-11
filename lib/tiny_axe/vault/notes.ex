defmodule TinyAxe.Vault.Notes do
  @moduledoc """
  The vault's notes, rendered from the state `TinyAxe.Vault.Ingest` keeps:
  frontmatter in each kind's order and the body the format lays down
  (`docs/vault-format.md`, "The kinds").
  """

  alias TinyAxe.Vault.{Format, Ingest}

  @doc "Every note as `{path inside the vault, contents}`."
  @spec render(map()) :: [{String.t(), String.t()}]
  def render(state) do
    for {group, kind} <- [
          {"sites", "site"},
          {"pages", "page"},
          {"controls", "control"},
          {"paths", "path"},
          {"tools", "tool"},
          {"tasks", "task"}
        ],
        {key, note} <- state[group] do
      title = title(state, kind, key)
      {props, sections} = note(state, kind, key, title, reached(note))
      pairs = [{"kind", kind}, {"key", key}, {"title", title}, {"trust", "observed"} | props]

      text =
        Format.frontmatter(pairs) <>
          "\n" <> Enum.join(["# " <> Format.escape(title) | sections], "\n\n") <> "\n"

      {Path.join(Format.folder(kind), name(state, kind, key) <> ".md"), text}
    end
  end

  # A page (or site) only ever reached as where an action led is dated by that.
  defp reached(%{"first_seen" => nil, "reached_first" => first} = n),
    do: %{n | "first_seen" => first, "last_seen" => n["reached_last"]}

  defp reached(n), do: n

  ## Names

  defp title(_state, kind, key) when kind in ~w(site page task), do: key

  defp title(state, "control", key) do
    c = state["controls"][key]
    "#{c["label"]} (#{c["role"]})"
  end

  defp title(_state, "tool", key) do
    case Ingest.split(key) do
      {nil, name} -> name
      {server, name} -> "#{name} (#{server})"
    end
  end

  defp title(state, "path", key) do
    p = state["paths"][key]

    subject =
      case p["subject_kind"] do
        "control" -> ~s(#{p["verb"]} "#{state["controls"][p["subject"]]["label"]}")
        "page" -> "#{p["verb"]} #{p["subject"]}"
        "tool" -> title(state, "tool", p["tool"])
      end

    "#{subject} → #{p["gate"]}"
  end

  defp name(state, kind, key), do: Format.basename(kind, key, title(state, kind, key))

  defp link(state, kind, key), do: Format.link(name(state, kind, key), title(state, kind, key))

  ## Kinds

  defp note(_state, "site", _key, _title, n) do
    {[
       {"seen", n["seen"]},
       {"looked", n["looked"]},
       {"first_seen", n["first_seen"]},
       {"last_seen", n["last_seen"]}
     ], [counts(n)]}
  end

  defp note(state, "page", _key, _title, n) do
    {[
       {"site", n["site"]},
       {"seen", n["seen"]},
       {"looked", n["looked"]},
       {"first_seen", n["first_seen"]},
       {"last_seen", n["last_seen"]}
     ], ["Site: " <> link(state, "site", n["site"]), counts(n)]}
  end

  defp note(state, "control", _key, _title, n) do
    {[
       {"site", n["site"]},
       {"page", n["page"]},
       {"role", n["role"]},
       {"label", n["label"]},
       {"seen", n["seen"]},
       {"first_seen", n["first_seen"]},
       {"last_seen", n["last_seen"]}
     ],
     [
       "Page: " <> link(state, "page", n["page"]),
       plural(n["seen"], "action") <> span(n)
     ]}
  end

  defp note(state, "path", _key, _title, p) do
    drivers =
      p["tasks"]
      |> Enum.map(&(get_in(state, ["tasks", &1, "driver"]) || "unrecorded"))
      |> Enum.uniq()
      |> Enum.sort()

    props = [
      {"site", p["site"]},
      {"subject", p["subject"]},
      {"tool", p["tool"]},
      {"answers", p["answers"]},
      {"class", p["class"]},
      {"gate", p["gate"]},
      {"outcome", p["outcome"]},
      {"reason_codes", p["reason_codes"]},
      {"seen", p["seen"]},
      {"errors", p["errors"]},
      {"drivers", drivers},
      {"models", p["models"]},
      {"versions", p["versions"]},
      {"first_seen", p["first_seen"]},
      {"last_seen", p["last_seen"]},
      {"tasks", p["tasks"]},
      {"decisions", p["decisions"]}
    ]

    acted =
      if p["subject_kind"] != "tool",
        do: ["- Acted on: " <> link(state, p["subject_kind"], p["subject"])],
        else: []

    reasons =
      if p["reason_codes"] == [],
        do: "",
        else: " · Reasons: " <> Enum.join(p["reason_codes"], ", ")

    led_to =
      if p["led_to"] == [],
        do: [],
        else: [
          "## Led to\n\n" <> Enum.map_join(p["led_to"], "\n", &("- " <> link(state, "page", &1)))
        ]

    {props,
     [
       Enum.join(acted ++ ["- Tool: " <> link(state, "tool", p["tool"])], "\n"),
       "Taken " <> plural(p["seen"], "time") <> span(p),
       "## Jev\n\n" <> jev(p["answers"]),
       "## Gate\n\nClass: #{p["class"]} · Gate: #{p["gate"]}" <> reasons
     ] ++ led_to}
  end

  defp note(_state, "tool", key, _title, n) do
    {server, name} = Ingest.split(key)

    {[
       {"server", server},
       {"name", name},
       {"seen", n["seen"]},
       {"first_seen", n["first_seen"]},
       {"last_seen", n["last_seen"]}
     ], ["Used " <> plural(n["seen"], "time") <> span(n)]}
  end

  defp note(state, "task", _key, _title, t) do
    driver = t["driver"] || "unrecorded"

    steps =
      if t["steps"] == [],
        do: [],
        else: [
          "## Steps\n\n" <>
            (t["steps"]
             |> Enum.with_index(1)
             |> Enum.map_join("\n", fn {path, i} -> "#{i}. " <> link(state, "path", path) end))
        ]

    {[
       {"driver", driver},
       {"started", t["started"]},
       {"calls", t["calls"]},
       {"ran", t["ran"]},
       {"approved", t["approved"]},
       {"denied", t["denied"]},
       {"refused", t["refused"]},
       {"sites", t["sites"]},
       {"pruned", t["pruned"]}
     ],
     [
       "- Driver: #{Format.escape(driver)}\n- Started: #{Format.escape(t["started"] || "(not recorded)")}",
       "## Request\n\n" <>
         if(t["objective"], do: Format.escape(t["objective"]), else: "(not recorded)")
     ] ++ steps}
  end

  ## Text

  defp jev("rules"), do: "Not asked: tiny-axe's rules classed this call."
  defp jev("unanswered"), do: "Asked, but no answer came back."

  defp jev(answers) do
    rows =
      answers
      |> String.split(" ")
      |> Enum.map_join("\n", fn pair ->
        [q, a] = String.split(pair, "=", parts: 2)
        "| #{q} | #{a} |"
      end)

    "| Question | Answer |\n|---|---|\n" <> rows
  end

  defp counts(n),
    do: plural(n["seen"], "action") <> " and " <> plural(n["looked"], "look") <> span(n)

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp span(%{"first_seen" => nil}), do: "."
  defp span(%{"first_seen" => same, "last_seen" => same}), do: " on #{same}."
  defp span(%{"first_seen" => first, "last_seen" => last}), do: ", #{first} to #{last}."
end
