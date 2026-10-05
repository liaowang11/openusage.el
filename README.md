# openusage.el

Live [OpenUsage](https://github.com/robinebers/openusage) limits in Emacs: how much of each AI
coding plan is left, and whether you are on pace to run out before it resets.

```
Claude · Team 5x
  Session                   ~78% left at reset
  ███████████████████████████┊████████████▌░░░
  92% left                    Resets in 3h 10m
  Extra Usage                  ! Limit reached
  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  $0.00 left                         $20 limit

Z.ai · GLM Coding Lite
  Session                    ! Limit in 3h 15m
  ███████████████████████████████████▋░┊░░░░░░
  81% left                    Resets in 4h 15m
```

That is the terminal rendering; a graphical frame draws each bar as a thin SVG rail instead.

- `M-x openusage` opens the overview: a card per limit laid out like the app's, with the pace
  verdict, the bar, then the amount left and when it resets. Hovering the reset time shows it
  in the other format, countdown or exact.
- `M-x openusage-provider` opens one provider in detail: when each limit resets, raw counts,
  how far into the window you are, burn rate, the projection at reset, every balance and the
  cache age. `RET` on a provider or limit in the overview opens it too.

Both buffers poll OpenUsage's shared five-minute cache while visible. They follow
`default-directory`, so from a buffer visiting a TRAMP remote they show that host's usage.

The bar is an SVG rail in a graphical frame. On a terminal the same text shows as an
eighth-block glyph bar, so one buffer reads well in both.

The pace rules, colours and wording port the OpenUsage app's meter logic:

| State | When | Shows |
|---|---|---|
| Spent | nothing left at display precision | red, `! Limit reached` |
| Running out | projected past the limit before the reset | red, `! Limit in 3h 15m` |
| Cutting it close | projected inside the last 10% | amber, `~3% spare` |
| On track | projected to finish with 10% or more to spare | the normal face; with `openusage-always-show-pacing`, `~78% left at reset` |

With no reset window, a limit turns amber at 80% used and red at 90%. The tick on the bar
marks where even use would put you right now.

## Requirements

- Emacs 30.1 or newer.
- The `openusage` command on `PATH` (on the remote host too, for TRAMP). Install it from the
  OpenUsage app: **Settings → Command Line → Install…**.

## Installation

Doom Emacs:

```elisp
;; packages.el
(package! openusage :recipe (:host github :repo "liaowang11/openusage.el"))
```

Emacs 30's built-in `package-vc`:

```elisp
(use-package openusage
  :vc (:url "https://github.com/liaowang11/openusage.el" :rev :newest))
```

## Keys

| Key | Command | Does |
|---|---|---|
| `TAB` | `openusage-toggle` | Fold or unfold the provider at point |
| `S-TAB` | `openusage-cycle` | Fold every provider, or open them all, like `org-shifttab` |
| `RET` | `openusage-visit` | Open the provider at point in detail; refresh with nothing at point |
| `n` | `openusage-next-provider` | Move to the next provider; stops at the last |
| `p` | `openusage-previous-provider` | Move to the previous provider; stops at the first |
| `g` | `revert-buffer` | Force a fresh pull (`openusage --force`) |
| `q` | `quit-window` | Quit |

With a prefix argument, `openusage` and `openusage-provider` ask for the host directory. `imenu` lists the providers.

## Customization

`M-x customize-group RET openusage`. These mirror the app's own settings:

| Option | Default | App setting |
|---|---|---|
| `openusage-usage-display` | `left` | Show Usage As: `left` or `used` |
| `openusage-reset-display` | `countdown` | Reset Times: `countdown` or `exact` |
| `openusage-always-show-pacing` | `nil` | Always Show Pacing |
| `openusage-time-format` | `"%H:%M"` | Time Format |

### What each buffer shows

The label and the amount left or used always show. Everything else is a field you can
put in either buffer:

| Field | Shows | Default buffer |
|---|---|---|
| `verdict` | the pace text beside the label, such as `! Limit in 3h 15m` | both |
| `bar` | the progress bar | both |
| `resets` | when the limit resets, right of the amount; with no reset time, the window length, the dollar limit or the unit | both |
| `used` | raw used / limit, for limits not counted in percent | detail |
| `window` | how far into the reset window you are | detail |
| `pace` | pace against even use, and the burn rate | detail |
| `projection` | where the current pace lands at the reset | detail |
| `expiries` | each balance expiry date | detail |
| `zero-balances` | balances at zero | detail |
| `cache` | when the data was fetched and when the cache expires | detail |

```elisp
;; Pacing detail in the overview too, and a detail buffer without the bar:
(setq openusage-overview-fields '(verdict bar resets pace projection)
      openusage-detail-fields '(verdict resets used window pace projection expiries cache))
```

The others:
- `openusage-program`: the command to run.
- `openusage-poll-interval`: seconds between polls.
- `openusage-expand-by-default`: whether a provider starts expanded.
- `openusage-bar-width`: card width in columns.
- `openusage-labels`: resource display names.
- `openusage-resource-order`: the order resources are listed in.

Faces: `openusage-normal`, `openusage-warning`, `openusage-critical`, `openusage-provider`,
`openusage-label`, `openusage-detail`.

## Development

```sh
make deps     # package-lint into .deps/
make check    # byte-compile, checkdoc + package-lint, ERT
```

## License

GPL-3.0-or-later.
