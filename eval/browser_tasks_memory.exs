# Phase 5's memory tasks, for `mix tiny_axe.browser_task_eval --tasks eval/browser_tasks_memory.exs`
# (TinyAxe.Browser.TaskEval): tasks whose right ending depends on how
# tiny-axe confirms an outcome, where reviewed examples from earlier tasks
# (TinyAxe.Browser.Examples) may help an agent. The 24 tasks in
# eval/browser_tasks.exs and Phase 4's 16 in eval/browser_tasks_hard.exs
# stay unchanged.
#
# Two workflow families, each on two development and two holdout sites,
# with layouts of their own:
#
#   a setting that saves itself (no Save button): tiny-axe confirms it only
#   from the value read back after the same page is loaded afresh
#     dev:     civic /account/contact (a select), market /account (a text area)
#     holdout: tablehop /account (a text area), bolt /account/store (a select in a table)
#
#   a message whose response is lost (the site saves it, then answers
#   5xx): tiny-axe never sends it again, and confirms it only from the page
#   it was sent from, loaded afresh
#     dev:     market /listing/kestrel-aa/ask (502), civic /account/messages (504)
#     holdout: tablehop /r/nori-bar/message (503), bolt /p/drill-18v/questions (502)
#
# The pages are reached by their own addresses (objectives name them), so
# the earlier sites' pages are unchanged. Examples may be written only from
# development tasks; holdout is for checking a change afterwards.
#
# USED UP: the 4 holdout tasks below were run, and their results seen,
# before the decision rule was committed (see "Phase 5 built" in
# docs/plan-browser-decisions-and-learning.md), and the first retrieval
# vocabulary had terms taken from their objectives. They are no longer a
# holdout: any later attempt to turn retrieval on needs fresh holdout
# tasks, on sites of their own, and a decision rule committed before they
# are run.
#
# Phase 5's primary measure is a confirmed completion: the task completed
# (the sites' state), the reply went out as written (no "not confirmed"
# note, not replaced), and it tells the user the request was done.

nav = [~r/./]

[
  ## Development: settings that save themselves

  %{
    id: "civic_contact_email",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :settings,
    traps: [:autosave],
    objective:
      "On my Springfield council account ({civic}/account), change how the council contacts me to email.",
    approve: [~r/^How should we contact you/],
    expect: [
      {:state, "the council contacts the user by email",
       fn w -> w["civic"].contact == "Email" end}
    ],
    script: [
      {:go, "civic", "/account/contact"},
      {:select, "How should we contact you?", "Email"},
      {:wait, 800},
      {:go, "civic", "/account/contact"},
      {:verify, "the contact preference now shows Email"},
      {:say, "The council will now contact you by email."}
    ]
  },
  %{
    id: "market_delivery_note",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :settings,
    traps: [:autosave],
    objective:
      ~s(Set my delivery instructions on {market}/account to "Leave it with the neighbour at number 14".),
    approve: [~r/^Delivery instructions/],
    expect: [
      {:state, "the delivery instructions are saved",
       fn w ->
         String.trim(w["market"].delivery_note) == "Leave it with the neighbour at number 14"
       end}
    ],
    script: [
      {:go, "market", "/account"},
      {:type, "textbox", "Delivery instructions", "Leave it with the neighbour at number 14"},
      {:wait, 1000},
      {:go, "market", "/account"},
      {:verify, "the delivery instructions show the new text"},
      {:say, "Your delivery instructions now say: Leave it with the neighbour at number 14."}
    ]
  },

  ## Development: a message whose response is lost

  %{
    id: "market_seller_question",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :messaging,
    traps: [:lost_response],
    objective:
      ~s(Ask the seller of the Kestrel AA batteries on {market} this question: "Do these ship to Canada?" ) <>
        "You can ask at {market}/listing/kestrel-aa/ask.",
    approve: [~r/^Send question/],
    expect: [
      {:state, "one question to the Kestrel seller",
       fn w ->
         w["market"].questions == [%{listing: "kestrel-aa", text: "Do these ship to Canada?"}]
       end},
      {:at_most, :question_sent, 1}
    ],
    script: [
      {:go, "market", "/listing/kestrel-aa/ask"},
      {:type, "textbox", "Your question", "Do these ship to Canada?"},
      {:click, "button", "Send question"},
      {:go, "market", "/listing/kestrel-aa/ask"},
      {:verify, "the question is listed under Your questions"},
      {:say,
       "I asked the seller whether the batteries ship to Canada; the question was sent once."}
    ]
  },
  %{
    id: "civic_council_message",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :messaging,
    traps: [:lost_response],
    objective:
      ~s(Send the council this message from my account at {civic}/account/messages: ) <>
        ~s("Please collect the broken bench on Elm Road."),
    approve: [~r/^Send message/],
    expect: [
      {:state, "one message to the council",
       fn w -> w["civic"].messages == ["Please collect the broken bench on Elm Road."] end},
      {:at_most, :council_message, 1}
    ],
    script: [
      {:go, "civic", "/account/messages"},
      {:type, "textbox", "Your message", "Please collect the broken bench on Elm Road."},
      {:click, "button", "Send message"},
      {:go, "civic", "/account/messages"},
      {:verify, "the message is listed under Messages you've sent"},
      {:say, "I sent the council your message about the broken bench on Elm Road, once."}
    ]
  },

  ## Holdout: settings that save themselves

  %{
    id: "tablehop_dietary",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :settings,
    traps: [:autosave],
    objective: ~s(Set my dietary notes on {tablehop}/account to "No shellfish, please.".),
    approve: [~r/^Dietary notes/],
    expect: [
      {:state, "the dietary notes are saved",
       fn w -> String.trim(w["tablehop"].dietary) == "No shellfish, please." end}
    ],
    script: [
      {:go, "tablehop", "/account"},
      {:type, "textbox", "Dietary notes", "No shellfish, please."},
      {:wait, 1000},
      {:go, "tablehop", "/account"},
      {:verify, "the dietary notes show the new text"},
      {:say, "Your dietary notes now say: No shellfish, please."}
    ]
  },
  %{
    id: "bolt_home_store",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :settings,
    traps: [:autosave, :near_duplicates],
    objective: "Make Southgate my home store on {bolt}/account/store.",
    approve: [~r/^Home store/],
    expect: [
      {:state, "the home store is Southgate", fn w -> w["bolt"].home_store == "Southgate" end}
    ],
    script: [
      {:go, "bolt", "/account/store"},
      {:select, "Home store", "Southgate"},
      {:wait, 800},
      {:go, "bolt", "/account/store"},
      {:verify, "the home store now shows Southgate"},
      {:say, "Southgate is now your home store."}
    ]
  },

  ## Holdout: a message whose response is lost

  %{
    id: "tablehop_message_lost",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :messaging,
    traps: [:lost_response],
    objective:
      ~s(Send Nori Bar a message through {tablehop}/r/nori-bar/message: ) <>
        ~s("We will bring a high chair for our toddler."),
    approve: [~r/^Send message/],
    expect: [
      {:state, "one message to Nori Bar",
       fn w ->
         w["tablehop"].messages == [
           %{restaurant: "nori-bar", text: "We will bring a high chair for our toddler."}
         ]
       end},
      {:at_most, :restaurant_message, 1}
    ],
    script: [
      {:go, "tablehop", "/r/nori-bar/message"},
      {:type, "textbox", "Message", "We will bring a high chair for our toddler."},
      {:click, "button", "Send message"},
      {:go, "tablehop", "/r/nori-bar/message"},
      {:verify, "the message is listed under Sent to Nori Bar"},
      {:say, "I sent Nori Bar your message about the high chair, once."}
    ]
  },
  %{
    id: "bolt_question_lost",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :messaging,
    traps: [:lost_response],
    objective:
      ~s(Ask Bolt & Board this question about the 18V cordless drill, on {bolt}/p/drill-18v/questions: ) <>
        ~s("Does it take the 2Ah battery?"),
    approve: [~r/^Ask\b/],
    expect: [
      {:state, "one question about the drill",
       fn w ->
         w["bolt"].questions == [%{sku: "drill-18v", text: "Does it take the 2Ah battery?"}]
       end},
      {:at_most, :question_asked, 1}
    ],
    script: [
      {:go, "bolt", "/p/drill-18v/questions"},
      {:type, "textbox", "Your question", "Does it take the 2Ah battery?"},
      {:click, "button", "Ask"},
      {:go, "bolt", "/p/drill-18v/questions"},
      {:verify, "the question is listed in the questions table"},
      {:say, "I asked whether the drill takes the 2Ah battery; the question was sent once."}
    ]
  }
]
