# Phase 4's decision probe for the gate's candidate check (TinyAxe.Browser.Choices),
# development tasks only: each harder dev task's script with the wrong one
# of several similar candidates clicked. Run with the scripted driver and a
# real decider to see whether the check would hold the click:
#
#   mix tiny_axe.browser_task_eval --driver scripted --decider jev \
#     --tasks eval/browser_choose_probe.exs --choose on --choose-hints
#
# The tasks fail by design (the scripted driver ignores hints); what's read
# is each run's `choices` (held or not, and what was chosen). Never run it
# against holdout tasks: the check's thresholds were set on these.
tasks = Map.new(TinyAxe.Browser.TaskEval.tasks("eval/browser_tasks_hard.exs"), &{&1.id, &1})

[
  %{
    tasks["market_charger"]
    | id: "wrong_charger_renewed",
      script: [
        {:go, "market", "/search?q=charger"},
        {:click, "button", "Add to cart", 4},
        {:say, "Added."}
      ]
  },
  %{
    tasks["market_charger"]
    | id: "wrong_charger_sponsored",
      script: [
        {:go, "market", "/search?q=charger"},
        {:click, "button", "Add to cart", 1},
        {:say, "Added."}
      ]
  },
  %{
    tasks["civic_library"]
    | id: "wrong_library_east_hill",
      script: [
        {:go, "civic", "/library/book"},
        {:select, "Branch", "East Hill"},
        {:wait, 500},
        {:click, "button", "Tuesday"},
        {:wait, 500},
        {:click, "button", "Book", 1},
        {:say, "Booked."}
      ]
  },
  %{
    tasks["civic_library"]
    | id: "wrong_library_later_slot",
      script: [
        {:go, "civic", "/library/book"},
        {:select, "Branch", "Eastside"},
        {:wait, 500},
        {:click, "button", "Tuesday"},
        {:wait, 500},
        {:click, "button", "Book", 4},
        {:say, "Booked."}
      ]
  },
  %{
    tasks["civic_bin_day"]
    | id: "wrong_bin_garden",
      script: [
        {:go, "civic", "/"},
        {:click, "button", "Continue", 2},
        {:say, "Done."}
      ]
  },
  %{
    tasks["market_lamp"]
    | id: "wrong_lamp_page1",
      script: [
        {:go, "market", "/search?q=arc+desk+lamp"},
        {:click, "button", "Add to cart", 3},
        {:say, "Added."}
      ]
  }
]
