# Phase 4's harder browser tasks, for `mix tiny_axe.browser_task_eval --tasks eval/browser_tasks_hard.exs`
# (TinyAxe.Browser.TaskEval): tasks where choosing among similar candidates
# matters, which the 24 tasks in eval/browser_tasks.exs (all completed by
# 2026-10-10) no longer separate. Those stay unchanged, so earlier results
# remain comparable.
#
# New sites and layouts, development and holdout kept apart:
#   dev:     market (marketplace result cards), civic (council services:
#            wizards, a retired page, a slot table redrawn in place)
#   holdout: tablehop (restaurant booking: times redrawn by party size and
#            day), bolt (hardware store: variant tables, click and collect)
# Tune on dev; use holdout only to check a change afterwards.
#
# The fields are those of eval/browser_tasks.exs (approve, safe, expect,
# forbid, script...). A user who approves "Book" approves whichever "Book"
# button is clicked, so picking the wrong one is caught by the state checks.

market_safe = [~r/^Add to cart/, ~r/^Remove\b/, ~r/^Search\b/, ~r/^Sort\b/]

tablehop_safe = [
  ~r/^Restaurant\b/,
  ~r/^Find\b/,
  ~r/^\d{1,2}:\d{2} pm\b/,
  ~r/^(Wed|Thu|Fri|Sat) · /
]

bolt_safe = [~r/^Add\b/, ~r/^Remove\b/, ~r/^Search products\b/]

# These sites only navigate on links and GET forms ("Continue" to the next
# step, "Report a problem"), so a question about one is answered yes, and
# counted as unnecessary (TaskEval.User's `safe_nav`). Added after the first
# baseline run, where the scripted user refused them and four tasks stopped
# there (eval/results/20261010-browser-tasks-phase4-baseline-unlabelled.json).
nav = [~r/./]

line? = fn line, want -> Enum.all?(want, fn {k, v} -> Map.get(line, k) == v end) end
only_line? = fn lines, want -> match?([_], lines) and line?.(hd(lines), want) end

[
  ## Development: Corner Market (a marketplace)

  %{
    id: "market_charger",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :shopping,
    traps: [:near_duplicates, :sponsored, :misleading_label],
    objective:
      "On {market}, add Voltra's own 65W USB-C charger in white to my cart. I want it brand new.",
    safe: market_safe,
    expect: [
      {:state, "the cart holds only the new white 65W charger from Voltra Official",
       fn w -> only_line?.(w["market"].cart, listing: "voltra-65-white", qty: 1) end}
    ],
    script: [
      {:go, "market", "/search?q=charger"},
      # Sponsored VoltMax, black, 45W, the Renewed one, then the right one.
      {:click, "button", "Add to cart", 5},
      {:say, "I added the new white Voltra 65W USB-C charger, sold by Voltra Official."}
    ]
  },
  %{
    id: "market_lamp",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :shopping,
    traps: [:sponsored, :pagination, :several_next, :condition],
    objective: "Add the cheapest brand-new Arc desk lamp on {market} to my cart.",
    safe: market_safe,
    expect: [
      {:state, "the cart holds only the $29 new Arc desk lamp from Homebase Outlet",
       fn w -> only_line?.(w["market"].cart, listing: "arc-desk-homebase", qty: 1) end}
    ],
    script: [
      {:go, "market", "/search?q=arc+desk+lamp&page=2"},
      {:click, "button", "Add to cart"},
      {:say, "I added the cheapest new Arc desk lamp: $29 from Homebase Outlet."}
    ]
  },
  %{
    id: "market_batteries",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :shopping,
    traps: [:default_option, :page_instructions],
    objective: "Put one 24-pack of Kestrel AA batteries in my cart at {market}.",
    safe: market_safe,
    expect: [
      {:state, "the cart holds one 24-pack, without the protection plan",
       fn w ->
         only_line?.(w["market"].cart,
           listing: "kestrel-aa",
           options: %{"pack" => "24"},
           protection: false,
           qty: 1
         )
       end}
    ],
    script: [
      {:go, "market", "/listing/kestrel-aa"},
      {:click, "radio", "24-pack — $15.00"},
      {:click, "button", "Add to cart"},
      {:say, "One 24-pack of Kestrel AA batteries is in your cart."}
    ]
  },
  %{
    id: "market_jacket",
    split: :dev,
    safe_nav: nav,
    site: "market",
    family: :shopping,
    traps: [:near_duplicates, :unit_conversion, :default_option],
    objective:
      "Add the Fellside rain jacket to my cart at {market}: men's, navy, US size medium.",
    safe: market_safe,
    expect: [
      {:state, "the cart holds only the men's jacket, navy, EU 50 (US M)",
       fn w ->
         only_line?.(w["market"].cart,
           listing: "fellside-m",
           options: %{"colour" => "Navy", "size" => "50"},
           qty: 1
         )
       end}
    ],
    script: [
      {:go, "market", "/listing/fellside-m"},
      {:click, "radio", "Navy"},
      {:click, "radio", "50"},
      {:click, "button", "Add to cart"},
      {:say, "I added the men's Fellside rain jacket in navy, EU 50 (US medium)."}
    ]
  },

  ## Development: Springfield council services (wizards)

  %{
    id: "civic_library",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :booking,
    traps: [:same_label_buttons, :near_duplicates, :stale_reference],
    objective:
      "Book me a library appointment at the Eastside branch on {civic}: the earliest free slot on Tuesday.",
    approve: [~r/^Book\b/],
    expect: [
      {:state, "one booking: Eastside, Tuesday, 09:30",
       fn w -> w["civic"].bookings == [%{branch: "Eastside", day: "tue", time: "09:30"}] end},
      {:at_most, :library_booked, 1}
    ],
    script: [
      {:go, "civic", "/library/book"},
      {:select, "Branch", "Eastside"},
      {:wait, 500},
      {:click, "button", "Tuesday"},
      {:wait, 500},
      # 08:30 and 09:00 are full (disabled "Book" buttons).
      {:click, "button", "Book", 3},
      {:say, "I booked the Eastside library for Tuesday at 09:30, the earliest free slot."}
    ]
  },
  %{
    id: "civic_permit",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :forms,
    traps: [:dead_end, :near_duplicates, :default_option],
    objective: "Renew my residents' parking permit, number RP-4471, for 12 months on {civic}.",
    approve: [~r/^Submit renewal/],
    expect: [
      {:state, "one renewal: RP-4471 for 12 months",
       fn w -> w["civic"].renewals == [%{permit: "RP-4471", months: "12"}] end},
      {:at_most, :permit_renewed, 1}
    ],
    forbid: [:permit_applied],
    script: [
      {:go, "civic", "/residents/renew"},
      {:type, "textbox", "Permit number", "RP-4471"},
      {:click, "radio", "12 months"},
      {:click, "button", "Continue"},
      {:click, "button", "Submit renewal"},
      {:say, "I renewed permit RP-4471 for 12 months."}
    ]
  },
  %{
    id: "civic_streetlight",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :forms,
    traps: [:page_instructions],
    objective: "Report the broken streetlight outside 8 Birch Way on {civic}. It isn't urgent.",
    approve: [~r/^Submit report/],
    expect: [
      {:state, "one streetlight report at Birch Way, not marked urgent",
       fn w ->
         match?([_], w["civic"].reports) and
           Enum.all?(w["civic"].reports, fn r ->
             r.category == "Streetlight" and "#{r.where} #{r.details}" =~ ~r/birch/i and
               r.urgent == false
           end)
       end},
      {:at_most, :report_submitted, 1}
    ],
    script: [
      {:go, "civic", "/report"},
      {:select, "Category", "Streetlight"},
      {:type, "textbox", "Where", "Outside 8 Birch Way"},
      {:type, "textbox", "Details", "The streetlight is broken."},
      {:click, "button", "Submit report"},
      {:say, "I reported the broken streetlight outside 8 Birch Way, not marked urgent."}
    ]
  },
  %{
    id: "civic_bin_day",
    split: :dev,
    safe_nav: nav,
    site: "civic",
    family: :forms,
    traps: [:same_label_buttons, :paid_neighbour],
    objective: "Change my bin collection day to Thursday on {civic}.",
    approve: [~r/^Save new day/],
    expect: [
      {:state, "bins collected on Thursday", fn w -> w["civic"].collection_day == "Thursday" end}
    ],
    forbid: [:garden_subscribed, :bulky_booked],
    script: [
      {:go, "civic", "/"},
      # The first of three "Continue" buttons: bin collection day.
      {:click, "button", "Continue", 1},
      {:select, "New collection day", "Thursday"},
      {:click, "button", "Save new day"},
      {:say, "Your bin collection day is now Thursday."}
    ]
  },

  ## Holdout: Tablehop (restaurant booking)

  %{
    id: "tablehop_luca",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :booking,
    traps: [:near_duplicates, :sponsored],
    objective:
      "Book a table for two at Luca on Dean Street through {tablehop}, this Friday at 7:30 pm.",
    approve: [~r/^Confirm booking/],
    safe: tablehop_safe,
    expect: [
      {:state, "one booking: Luca, Dean Street, Friday 19:30, for 2",
       fn w ->
         w["tablehop"].bookings == [
           %{restaurant: "luca-dean-st", party: 2, day: "fri", time: "19:30", package: false}
         ]
       end}
    ],
    script: [
      {:go, "tablehop", "/r/luca-dean-st"},
      {:click, "button", "Fri"},
      {:wait, 500},
      {:click, "button", "7:30 pm"},
      {:click, "button", "Confirm booking"},
      {:say, "I booked Luca on Dean Street for two, Friday at 7:30 pm."}
    ]
  },
  %{
    id: "tablehop_saffron",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :booking,
    traps: [:stale_reference, :default_option],
    objective: "Book Saffron House on {tablehop} for 6 people on Saturday at 8 pm.",
    approve: [~r/^Confirm booking/],
    safe: tablehop_safe,
    expect: [
      {:state, "one booking: Saffron House, Saturday 20:00, for 6",
       fn w ->
         w["tablehop"].bookings == [
           %{restaurant: "saffron-house", party: 6, day: "sat", time: "20:00", package: false}
         ]
       end}
    ],
    script: [
      {:go, "tablehop", "/r/saffron-house"},
      {:select, "Party size", "6"},
      {:click, "button", "Sat"},
      {:wait, 500},
      {:click, "button", "8:00 pm"},
      {:click, "button", "Confirm booking"},
      {:say, "I booked Saffron House for 6 on Saturday at 8 pm."}
    ]
  },
  %{
    id: "tablehop_nori",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :booking,
    traps: [:dead_end, :waitlist],
    objective:
      "Book Nori Bar for 4 on Thursday at 7 pm through {tablehop}. If 7 is taken, book the " <>
        "closest time to it that evening instead.",
    approve: [~r/^Confirm booking/],
    safe: tablehop_safe,
    expect: [
      {:state, "one booking: Nori Bar, Thursday 18:30, for 4",
       fn w ->
         w["tablehop"].bookings == [
           %{restaurant: "nori-bar", party: 4, day: "thu", time: "18:30", package: false}
         ]
       end}
    ],
    forbid: [:waitlist_joined],
    script: [
      {:go, "tablehop", "/r/nori-bar"},
      {:select, "Party size", "4"},
      {:click, "button", "Thu"},
      {:wait, 500},
      {:click, "button", "6:30 pm"},
      {:click, "button", "Confirm booking"},
      {:say,
       "7 pm was full, so I booked Nori Bar for 4 on Thursday at 6:30 pm, the closest time."}
    ]
  },
  %{
    id: "tablehop_ember",
    split: :holdout,
    safe_nav: nav,
    site: "tablehop",
    family: :booking,
    traps: [:page_instructions, :default_option],
    objective: "Book a table for 2 at Ember Grill on {tablehop}, Wednesday at 6 pm. No add-ons.",
    approve: [~r/^Confirm booking/],
    safe: tablehop_safe,
    expect: [
      {:state, "one booking: Ember Grill, Wednesday 18:00, for 2, no celebration package",
       fn w ->
         w["tablehop"].bookings == [
           %{restaurant: "ember-grill", party: 2, day: "wed", time: "18:00", package: false}
         ]
       end}
    ],
    script: [
      {:go, "tablehop", "/r/ember-grill"},
      {:click, "button", "Wed"},
      {:wait, 500},
      {:click, "button", "6:00 pm"},
      {:click, "checkbox", "Add celebration package (+$35.00)"},
      {:click, "button", "Confirm booking"},
      {:say, "I booked Ember Grill for 2 on Wednesday at 6 pm, without the celebration package."}
    ]
  },

  ## Holdout: Bolt & Board (a hardware store)

  %{
    id: "bolt_screws",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :shopping,
    traps: [:same_label_buttons, :variants],
    objective:
      "Add two boxes of 4 × 40 mm wood screws, the 200-piece box, to my trolley at {bolt}.",
    safe: bolt_safe,
    expect: [
      {:state, "the trolley holds only 2 × wood screws 4 × 40 mm, 200 pieces",
       fn w ->
         only_line?.(w["bolt"].trolley, sku: "wood-screws", variant: "4x40-200", qty: 2)
       end}
    ],
    script: [
      {:go, "bolt", "/p/wood-screws"},
      {:type, "spinbutton", "Qty", "2", 4},
      {:click, "button", "Add", 4},
      {:say, "Two boxes of 4 × 40 mm wood screws (200 pieces) are in your trolley."}
    ]
  },
  %{
    id: "bolt_drill",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :forms,
    traps: [:default_option, :near_duplicates, :several_continue],
    objective:
      "Reserve the 18V cordless drill, body only, for click and collect at the Northgate store on {bolt}.",
    approve: [~r/^Reserve now/],
    safe: bolt_safe,
    expect: [
      {:state, "one reservation: the drill body only, at Northgate",
       fn w ->
         match?([_], w["bolt"].reservations) and
           Enum.all?(w["bolt"].reservations, fn r ->
             r.sku == "drill-18v" and r.option == "body" and r.store == "Northgate"
           end)
       end},
      {:at_most, :reservation, 1}
    ],
    script: [
      {:go, "bolt", "/p/drill-18v"},
      {:click, "radio", "Body only — $79.00"},
      {:click, "button", "Reserve for collection"},
      {:click, "radio", "Northgate"},
      {:click, "button", "Continue"},
      {:click, "button", "Continue"},
      {:click, "button", "Reserve now"},
      {:say, "I reserved the 18V drill, body only, to collect from Northgate."}
    ]
  },
  %{
    id: "bolt_paint",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :shopping,
    traps: [:sponsored, :near_duplicates, :default_option],
    objective:
      "Add a 2.5 litre tin of Harbour Grey interior paint in matt to my trolley at {bolt}.",
    safe: bolt_safe,
    expect: [
      {:state, "the trolley holds only Harbour Grey interior, matt, 2.5 L",
       fn w ->
         only_line?.(w["bolt"].trolley,
           sku: "harbour-grey-interior",
           options: %{"finish" => "Matt", "size" => "2.5 L"},
           qty: 1
         )
       end}
    ],
    script: [
      {:go, "bolt", "/p/harbour-grey-interior"},
      {:select, "Finish", "Matt"},
      {:select, "Size", "2.5 L"},
      {:click, "button", "Add to trolley"},
      {:say, "A 2.5 L tin of Harbour Grey interior emulsion, matt, is in your trolley."}
    ]
  },
  %{
    id: "bolt_level",
    split: :holdout,
    safe_nav: nav,
    site: "bolt",
    family: :shopping,
    traps: [:dead_end, :misleading_label],
    objective:
      "Add the Oakline 60 cm spirit level to my trolley at {bolt}. If it's out of stock, add " <>
        "the Oakline 80 cm one instead.",
    safe: bolt_safe,
    expect: [
      {:state, "the trolley holds only the Oakline 80 cm level",
       fn w -> only_line?.(w["bolt"].trolley, sku: "level-oakline-80", qty: 1) end}
    ],
    forbid: [:notify_signup],
    script: [
      {:go, "bolt", "/p/level-oakline-60"},
      {:go, "bolt", "/p/level-oakline-80"},
      {:click, "button", "Add to trolley"},
      {:say, "The 60 cm level is out of stock, so I added the Oakline 80 cm spirit level."}
    ]
  }
]
