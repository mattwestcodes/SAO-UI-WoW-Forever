# SAO Frames (WoW Forever)

SAO-style unit frames: angled health bar that turns green → yellow → red, name on the left,
`HP / MaxHP   HP%   LV: xx` underneath, a class-colored badge with your class icon, a power bar
(mana / rage / energy / focus / runic power, colored by type), and debuff icons.

- **Player, target, party** – full-size frames. Debuffs show under the player and target frames
  and to the right of party frames. Party frames hide automatically in a raid.
- **Raid** – compact frames, one row per group (5 across, up to 8 rows): name, HP %, class-colored
  badge, up to 4 debuffs, out-of-range fading, and a power bar for healers.
- **Debuffs** – border colored by type (blue magic, purple curse, brown disease, green poison,
  red other), duration swipe, stack count, hover for the tooltip. On an enemy target only
  your own debuffs are shown by default.

## Install
Copy the `SAOFrames` folder into `World of Warcraft\_forever_\Interface\AddOns\`
(Battle.net → WoW Forever → gear icon → Show in Explorer/Finder). The folder must contain `SAOFrames.toc` directly.

## Options window
Type `/sao` (or click SAO Frames in the minimap addon menu, or Esc > Options > AddOns) to open a
clickable options window with every setting: lock/unlock, grid and snapping, sizes, feature
toggles, threat role, reset and debug. Escape closes it.

While unlocked, a grid is drawn on screen (red center lines). With snapping on, a frame you drop
lands on the nearest grid point.

## Commands
- `/sao unlock` – shows blue "drag to move" handles on every frame (plus a raid placeholder); drag them
- `/sao lock` – lock them again
- `/sao scale 1.2` – player/target/party size (0.5–2)
- `/sao raidscale 0.7` – raid frame size (0.4–2)
- `/sao smooth` – animate bar changes (off by default so bars always show exact health)
- `/sao threat` – toggle threat glow on bar edges
- `/sao tank` – threat role: auto (default) → tank → dps
- `/sao bg` – toggle a dark panel behind player/target/party (off by default)
- `/sao raidpower` – raid power bars for healers only (default) or everyone
- `/sao targetdebuffs` – enemy target: only your debuffs (default) or all
- `/sao blizz` – toggle hiding Blizzard's own unit and raid frames (reloads the UI).
- `/sao raidtools` – show/hide Blizzard's raid tools tab on the left edge (markers, ready check);
  hidden by default (reloads the UI)

Frames lock themselves automatically when combat starts.
- `/sao grid` / `/sao snap` / `/sao gridsize 32` – grid while unlocked, snapping, grid spacing
- `/sao errors` – list Lua errors this addon has caused (`/sao clearerrors` resets the log)
- `/sao reset` – reset positions and scale
- `/sao debug` – report what the debuff scan sees (works in combat)

Left-click a frame to target, right-click for the unit menu.

## Badge
- You and group members: class icon cut into a slanted chip with a class-colored outline (red outline while you're in combat).
- Target: red hostile / yellow neutral / green friendly, with the class icon if it's a player.

## Health
Health refreshes 10 times a second and the % is rounded down (19% means under 20%).

## Nameplates
Mob nameplates use the SAO look: bold name with health % above an angled bar colored by reaction
(red = hostile, will attack if you get close; yellow = neutral; green = friendly; grey = tapped), a level badge
(colored by reaction), your debuffs with timers above the name, and threat glow + aggro arrows on
enemies only. Your current target's plate is slightly larger. Under the bar is an SAO cast bar with spell
icon and name: gold = interruptible, grey = can't be interrupted, red flash = interrupted.
Blizzard's own plate art is hidden. `/sao plates` turns them off (reloads). Turn off other nameplate addons such
as Threat Plates so they don't draw on top.

## Friendly nameplates
Friendly plates show the unit's debuffs and then its buffs in two rows under the bar.
The game hides friendly nameplates by default (friendly units only get name labels), so SAO Frames
turns friendly player health bars on (`/sao friendly`); friendly NPC bars are optional
(`/sao friendlynpcs`, off by default). In dungeons and raids the game locks friendly plates to
Blizzard's own style, so they won't be SAO-styled there.

## Focus
A focus frame (set focus as usual) styled like the target frame, a bit smaller, with its own
debuffs/buffs, threat glow and aggro arrows. Drag it in `/sao unlock`.

## Target of target
A compact frame under the right side of the target frame shows who your target is targeting
(name, health %, class/reaction badge, aggro glow). Click it to target that unit; it moves with the
target frame.

## Roles
Party members show a tank / healer / DPS icon next to their name (from the role they picked);
raid frames show a small one too.

## Names
Players show their first name and surname (stacked on two lines on the big frames), in bold.

## Buffs and debuffs
On clients with the game's aura containers (12.1+), buff/debuff rows are drawn by the game itself
(the only way to show enemy debuffs in combat there); rows sit in fixed positions; debuff borders are coloured by dispel type by the game
(magic, curse, disease, poison...), plain red for debuffs without a type such as stuns. Older clients use the addon's own rows. `/sao debug` says which mode is active.

- Your frame: your buffs, then your debuffs, in rows under the frame.
- Target: your debuffs on it, then its buffs (up to 7 each, leaving room for target of target).
- Party: debuffs to the right. Raid: up to 4 small debuffs.

## Threat glow and aggro arrows
Enemies only (target frame and nameplates). Arrows and edge glow share one color:
- DPS/healer, by your threat % on the mob: green < 50%, yellow 50-79%, orange 80-99%,
  red = you have aggro (pulsing).
- Tank: green = solidly yours, yellow = slipping, orange = about to lose it, red = lost
  (orange/red pulse).
While you're on an enemy's threat list its health bars (nameplate, target, focus) take the same
threat color; out of combat nameplates show reaction color and frames show health color.
`/sao threatbars` turns this off.
Role is detected automatically: Defensive Stance, Bear/Dire Bear Form or Righteous Fury = tank;
otherwise your spec, then your group role. Your own, party and raid frames glow when that
person has aggro.

## Damage / heal meter (1.3.0)
An SAO-styled meter window built on the game's own C_DamageMeter data (addons can't read
the combat log). Click the title to cycle modes (damage, DPS, healing, HPS, absorbs,
interrupts, dispels, damage taken, deaths...), use the header buttons to switch
current/overall fight and to reset. Unlock with `/sao unlock` to drag it (grid snap applies).
- `/sao meter` show/hide, `/sao meterreset` reset all fights, `/sao meterdebug` diagnostics
- Blizzard's built-in meter is faded out while this one is shown (never hidden, so its data keeps flowing).
- In combat the numbers are secret values: they display fine, but there are no percentages or totals row.
- Needs the game's damage meter setting turned on; `/sao meterdebug` tells you if it's unavailable.

## SAO font
Drop a font named `SAOUI.ttf` into `Fonts\` (see `Fonts\README.txt`) and `/reload`.
Suggested: "SAO UI" by DarkBlackSwords (fan font of the anime UI) or Rajdhani (Google Fonts, OFL).
Toggle with `/sao font` or in the options window. Missing/broken file = normal fonts.

## Elite / rare borders and level colors
- Enemy elite = gold outline, rare = silver, rare elite = gold + silver, boss = red + gold (`/sao elite`).
- Enemy levels are colored by difficulty: gray (no XP), green, white (within 2 of you), orange (+3/+4), red (+5 or more).
  Mobs too high for the client to reveal ("??") show a red "your level + 10" with a "+", e.g. 30+ (`/sao levels`).
- `/sao debug` lists, per nameplate, whether the aggro arrows are shown and why not.

## 1.4.0: chat, social menu, loot rolls
- **Chat** (`/sao chat`): dark SAO glass panels, flat uppercase tabs (orange = selected), cyan input bar, SAO font.
- **Social menu** (`/sao social`, or click the round button; drag it while unlocked): Party / Friend / Guild / Raid / Whisper
  lists with sub-actions. Macro keybind: `/click SAOFrames_SocialButton`. `/sao socialtoggle` hides the button.
- **Loot rolls** (`/sao loot`): SAO message boxes with round NEED / GREED / DISENCHANT / PASS buttons and a countdown.
  `/sao loottest` shows a preview. If an SAO roll window ever fails, that roll falls back to Blizzard's window.
- Dungeons/raids: friendly plates are locked by the game; they switch to class-coloured names (SAO font if installed).
