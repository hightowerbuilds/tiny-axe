# Evaluation tasks for `mix tiny_axe.eval`. Each runs in its own throwaway home
# folder (`home:` lists its files, `start:` is the folder tiny-axe starts in),
# and is checked independently of the model's own judgment:
#
#   {:route, :answer | :organize | :command}   which way the request went
#   {:contains, [fact]}                         the answer mentions each fact (a fact
#                                               can be a list of accepted phrasings)
#   {:elixir_tests, code}                       the answer's code passes these assertions
#   {:tree, %{path => content | :dir | :absent}} files end up exactly so
#   {:file_mentions, {path, [fact]}}            a written file mentions each fact
#   {:command, ~r//}                            a planned command matches
#   {:command_dir, path}                        commands would run in that folder
#
# `split: :dev` tasks are for tuning; `:holdout` ones for checking a change
# afterwards, without tuning on them. Grow both, keeping them independent.

downloads = %{
  "Downloads/a.pdf" => "pdf a",
  "Downloads/b.pdf" => "pdf b",
  "Downloads/notes.txt" => "notes"
}

npm_history = [
  %{role: "user", content: "How do I install the dependencies for my Vite app?"},
  %{role: "assistant", content: "Run `npm install` in the project folder."}
]

[
  ## Questions

  %{
    id: "q_otp",
    category: :answer,
    split: :dev,
    prompt: "What does OTP stand for in Erlang?",
    expect: [route: :answer, contains: ["Open Telecom Platform"]]
  },
  %{
    id: "q_call_cast",
    category: :answer,
    split: :dev,
    prompt:
      "In Elixir, what's the difference between GenServer.call and GenServer.cast? Keep it short.",
    expect: [
      route: :answer,
      contains: [
        ["synchronous", "blocks", "waits for"],
        ["asynchronous", "does not wait", "doesn't wait", "fire and forget", "fire-and-forget"]
      ]
    ]
  },
  %{
    # About files, but asking how, not asking for it done.
    id: "q_how_to_move",
    category: :answer,
    split: :dev,
    prompt: "How do I move a file to another folder from the Linux terminal?",
    expect: [route: :answer, contains: ["mv "]]
  },
  %{
    id: "q_pipe",
    category: :answer,
    split: :holdout,
    prompt: "What does the |> operator do in Elixir?",
    expect: [route: :answer, contains: ["first argument"]]
  },

  ## Code, checked by the task's own tests

  %{
    id: "code_slugify",
    category: :code,
    split: :dev,
    prompt:
      "Write an Elixir module `Slug` with a function `slugify/1` that lowercases a string, " <>
        "turns every run of characters that aren't letters or digits into a single hyphen, " <>
        "and trims hyphens from both ends.",
    expect: [
      route: :answer,
      elixir_tests: """
      assert Slug.slugify("Hello World!") == "hello-world"
      assert Slug.slugify("  Elixir -- is FUN  ") == "elixir-is-fun"
      assert Slug.slugify("abc123") == "abc123"
      """
    ]
  },
  %{
    id: "code_fizzbuzz",
    category: :code,
    split: :dev,
    prompt:
      "Write an Elixir module `FizzBuzz` with `word/1`: for a positive integer it returns " <>
        "\"FizzBuzz\" if divisible by 15, \"Fizz\" if by 3, \"Buzz\" if by 5, and otherwise the number as a string.",
    expect: [
      route: :answer,
      elixir_tests: """
      assert FizzBuzz.word(15) == "FizzBuzz"
      assert FizzBuzz.word(9) == "Fizz"
      assert FizzBuzz.word(10) == "Buzz"
      assert FizzBuzz.word(7) == "7"
      """
    ]
  },
  %{
    id: "code_word_count",
    category: :code,
    split: :holdout,
    prompt:
      "Write an Elixir module `WordCount` with `count/1`, which takes a sentence and returns a map " <>
        "of each lowercased word to how many times it appears. Words are separated by spaces.",
    expect: [
      route: :answer,
      elixir_tests: """
      assert WordCount.count("the cat the") == %{"the" => 2, "cat" => 1}
      assert WordCount.count("Go go GO") == %{"go" => 3}
      """
    ]
  },

  ## Files, checked by the tree the approved plan leaves

  %{
    id: "files_move_pdfs",
    category: :files,
    split: :dev,
    home: downloads,
    prompt:
      "Move the PDFs in my Downloads folder into a new folder called Papers in my home folder.",
    expect: [
      route: :organize,
      tree: %{
        "Papers/a.pdf" => "pdf a",
        "Papers/b.pdf" => "pdf b",
        "Downloads/a.pdf" => :absent,
        "Downloads/b.pdf" => :absent,
        "Downloads/notes.txt" => "notes"
      }
    ]
  },
  %{
    id: "files_write_md",
    category: :files,
    split: :dev,
    prompt: "Create a markdown file at ~/notes/shopping.md with a list of eggs, milk and bread.",
    expect: [route: :organize, file_mentions: {"notes/shopping.md", ["eggs", "milk", "bread"]}]
  },
  %{
    id: "files_rename",
    category: :files,
    split: :dev,
    home: %{"Documents/draft.txt" => "the draft"},
    prompt: "Rename ~/Documents/draft.txt to final.txt.",
    expect: [
      route: :organize,
      tree: %{"Documents/final.txt" => "the draft", "Documents/draft.txt" => :absent}
    ]
  },
  %{
    id: "files_copy",
    category: :files,
    split: :holdout,
    home: %{"Documents/report.md" => "# Report"},
    prompt: "Copy ~/Documents/report.md into a folder called Backup in my home folder.",
    expect: [
      route: :organize,
      tree: %{"Backup/report.md" => "# Report", "Documents/report.md" => "# Report"}
    ]
  },
  %{
    id: "files_trash",
    category: :files,
    split: :holdout,
    home: %{"Downloads/old.zip" => "zip", "Downloads/keep.txt" => "keep"},
    prompt: "Put old.zip from my Downloads in the trash.",
    expect: [
      route: :organize,
      tree: %{"Downloads/old.zip" => :absent, "Downloads/keep.txt" => "keep"}
    ]
  },

  ## Commands, planned but never run

  %{
    id: "cmd_npm_install",
    category: :command,
    split: :dev,
    home: %{"code/web/package.json" => ~s({"name": "web", "dependencies": {}})},
    start: "code/web",
    prompt: "Install this project's npm dependencies.",
    expect: [route: :command, command: ~r/^npm (install|i|ci)\b/, command_dir: "code/web"]
  },
  %{
    id: "cmd_mix_test",
    category: :command,
    split: :dev,
    home: %{"code/app/mix.exs" => "defmodule App.MixProject do\nend\n"},
    start: "code/app",
    prompt: "Run the test suite for this project.",
    expect: [route: :command, command: ~r/^mix test\b/, command_dir: "code/app"]
  },
  %{
    id: "cmd_git_log",
    category: :command,
    split: :holdout,
    home: %{"code/site/README.md" => "# Site"},
    start: "code/site",
    prompt: "Show me the last five git commits in this project.",
    expect: [route: :command, command: ~r/^git log\b/]
  },

  ## Follow-ups, which only make sense with the conversation

  %{
    id: "follow_run_it",
    category: :followup,
    split: :dev,
    home: %{"code/web/package.json" => ~s({"name": "web", "dependencies": {}})},
    start: "code/web",
    history: npm_history,
    prompt: "ok, now run it",
    expect: [route: :command, command: ~r/^npm (install|i|ci)\b/]
  },
  %{
    id: "follow_move_those",
    category: :followup,
    split: :holdout,
    home: downloads,
    history: [
      %{role: "user", content: "Which PDFs are in my Downloads folder?"},
      %{role: "assistant", content: "There are two: a.pdf and b.pdf."}
    ],
    prompt: "put those in a folder called Papers in my home folder",
    expect: [
      route: :organize,
      tree: %{
        "Papers/a.pdf" => "pdf a",
        "Papers/b.pdf" => "pdf b",
        "Downloads/notes.txt" => "notes"
      }
    ]
  }
]
