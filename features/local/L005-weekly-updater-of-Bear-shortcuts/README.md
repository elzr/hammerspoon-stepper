# L005: Weekly Updater of Bear Shortcuts

Auto-updates the week number and date-range variables in `data/bear-notes.jsonc` every Monday, so Bear note hotkeys (Hyper+D/W/T) always open the correct weekly note.

## How It Works

1. `week-data.json` — cached lookup of all 53 ISO weeks → date-range strings (from the [year-weeks spreadsheet](https://docs.google.com/spreadsheets/d/1nIMtN2w4JZs1K7h1_Y2qrT6RuQXKtgBvBBu3iIIdrDg/edit?gid=385652933))
2. `update-bear-weeks.py` — computes current ISO week, looks up current/prev/next date ranges, updates the 6 vars in `bear-notes.jsonc`, reloads Hammerspoon
3. `~/Library/LaunchAgents/com.stepper.update-bear-weeks.plist` — runs the script every Monday at 7:00 AM

## Files

| File | Purpose |
|------|---------|
| `fetch-week-data.sh` | One-time: fetches week data from Google Sheets via `gws` → `week-data.json` |
| `update-bear-weeks.py` | Weekly: computes week, updates JSONC vars, reloads Hammerspoon |
| `week-data.json` | Cached week lookup (53 entries) |
| [`~/Library/LaunchAgents/com.stepper.update-bear-weeks.plist`](~/Library/LaunchAgents/com.stepper.update-bear-weeks.plist) | Monday 7am launchd schedule |
| [`../../data/bear-notes.jsonc`](../../data/bear-notes.jsonc) | The file being updated (vars block) |

## Manual Run

```bash
python3 update-bear-weeks.py
```

## Year Boundary

At the start of each new year, re-run `fetch-week-data.sh` against the new year's tab in the spreadsheet to refresh `week-data.json`.
