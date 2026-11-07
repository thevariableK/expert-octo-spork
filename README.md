# Zone Quest Tracker

A World of Warcraft addon for **WoW Forever** that keeps the objective tracker focused on where you are:

- **Only current-zone quests** are shown in the tracker.
- **Sorted by quest level**: lowest level at the top, highest at the bottom (same level is sorted by name).

When you move to a new zone, the tracker updates automatically.

## Installation

1. Download this repository (green **Code** button → **Download ZIP**) and extract it.
2. Copy the `ZoneQuestTracker` folder into your Forever AddOns folder:
   ```
   World of Warcraft\_forever_\Interface\AddOns\ZoneQuestTracker\
   ```
   The folder must contain `ZoneQuestTracker.toc` directly (not a nested folder).
3. Restart the game (or `/reload` if the addon list already shows it) and make sure **Zone Quest Tracker** is enabled on the character select AddOns screen.

## Usage

The addon is on by default. Commands:

| Command | What it does |
|---|---|
| `/zqt` | Toggle the addon on/off |
| `/zqt on` | Turn on |
| `/zqt off` | Turn off. If you turned it on this session, your previous tracked quests are restored; otherwise the tracker is left as is |
| `/zqt unpin` | Clear all pinned and hidden quests |
| `/zqt debug` | List tracked quests in order with level and why each is shown (zone / pinned / other) |

### Pinning and hiding quests

The addon respects what you do by hand:

- **Track a quest from another zone** (e.g. shift-click it in the quest log) and it is **pinned**: it stays in the tracker, below your zone quests, in every zone until you untrack it.
- **Untrack a quest in your current zone** and it stays **hidden** until you leave the zone. Track it again to bring it back.

Newly accepted quests for other zones are not pinned; they appear once you get there.

### Things to know

- The tracker holds at most 25 quests. Pinned quests get their slots first; if your zone has more quests than fit, the lowest-level ones are shown and you get a one-time chat message.
- Changes are paused during combat and applied when combat ends.
- A quest counts as "in the zone" if it is listed under the current zone's header in your quest log, or the game shows it on your current map.

## How it works

Forever uses the modern objective tracker, which displays quests in the order of your tracked-quest (watch) list. Instead of modifying Blizzard's tracker code, which can cause "action blocked" errors with quest item buttons, the addon edits the watch list itself using the standard quest API: it untracks quests outside the zone and re-tracks zone quests in level order.

## Compatibility

- Built for the WoW Forever client (interface `16001`).
- Other addons that also manage tracked quests (for example ones that auto-track by distance) will conflict with it. Use one or the other.

## Status

Early release. It has not been tested on a live client yet, so please open an issue if something misbehaves, especially if the tracker order doesn't stick or zone quests aren't picked up.
