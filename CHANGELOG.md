# SAO Frames

## v1.6.2
**Fixes**
- Right-click (targeting, looting) no longer randomly stops working until a /reload. Blizzard's hidden damage meter kept adding invisible rows that caught clicks.
- Mobs tagged by another player stay grey on their nameplate when threat colouring kicks in, instead of turning green.
- Threat colours on nameplates you haven't targeted now show the full green / yellow / orange / red range.
- Quest window: Accept / Decline (and turn-in) buttons are centred under the text and no longer cut off.
- Loot roll dialog: proper round item icon and a tighter layout.
- Nameplate settings the addon changes are put back at logout, so disabling SAO Frames leaves your plates as they were.

**Changes**
- Friendly nameplates in dungeons and raids keep the game's health bars instead of switching to names only.
- Friendly nameplates are click-through, so they don't block clicks on mobs behind your group (`/sao clickthrough` to turn off).
- The target frame's health bar is always red on an enemy (`/sao targetred` to turn off). Nameplates keep their threat colours.
- Raid markers on enemy nameplates sit centred above the health bar.
- Nameplate HP % updates faster (about 30 times a second, same as the unit frames).

**New commands**
- `/sao clicks` shows what your last right-clicks landed on; `/sao mouse` shows what is under the cursor. Handy if a click ever doesn't go through.

## v1.6.1
- First public release on CurseForge.
- Guild names under player names (frames and nameplates); pulsing "z Z Z" on the player frame while resting.
- SAO-style quest windows (pickup, progress, turn-in, greeting) and NPC gossip window.
- Softer steel-gray "white box" palette for vendor, trade, loot and roll windows; clean price digits.
- Trade window item dividers; vendor tabs restyled; target-of-target moved above the target.
- Full code review pass (meter, chat, social, loot, frames, nameplates) with all confirmed bugs fixed.

## v1.5.0
- SAO loot window, trade window and vendor window skins.

## v1.4.0
- SAO chat skin, social ring menu, need/greed/pass roll dialogs, raid markers, ready checks.
