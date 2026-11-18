# Equipment Set Marker

marks every inventory slot whose item is part of a saved **Equipment Manager** set, using **the
icon you picked for that set** in the Equipment Manager. the "Heals" set marks with the Heals
icon, "Feral" with the Feral one. an item that belongs to **several** sets gets several icons —
a row of them inside the slot, one per set, so shared pieces are told apart at a glance instead
of only showing whichever set was saved first. covers the bags, the keyring, the bank tabs and
the character equipment slots, and adds one tooltip line per set the hovered item is in.

built and tested for **World of Warcraft: Forever** (`## Interface: 16001`).

the set icon is taken from the first source the client answers on:

1. the set info call, as a texture path (`interface\icons\...`)
2. the same call as a texture id (a number - modern builds hand back an id, and `SetTexture`
   takes it directly)
3. the per slot api (`GetContainerItemEquipmentSetInfo`), for builds whose set info call carries
   no icon - learned once per set, and dropped whenever a bag changes
4. only if all three come up empty: a small generic sparkle

a slot never draws the same picture twice: two sets that share an icon are one icon, and the
generic sparkle only shows when a slot has nothing else to show — a sparkle next to a real icon
is noise, not information.

## install

clone it into the addon folder, which creates the correctly named folder by itself:

    cd "World of Warcraft/_forever_/Interface/AddOns"
    git clone https://github.com/rsik/EquipmentSetMarker

or download `EquipmentSetMarker-vX.Y.zip` from the [latest
release](https://github.com/rsik/EquipmentSetMarker/releases) and unzip it into `Interface/AddOns`
- the zip contains the `EquipmentSetMarker` folder, so it lands in the right place and can be
picked up by any addon manager that installs from GitHub releases.

a folder that appears while the client is running is often not picked up by `/reload`, so restart
once after installing. a change to a file inside a folder the client already loaded only needs
`/reload`. when it loads it prints one line in chat:

    ESM loaded. C_EquipmentSet true, sets 2, items 16, buttons 110.

no line at all means it is not loading: check it is enabled in the addon list, and that the folder
is named `EquipmentSetMarker` (the client finds an addon by the folder matching its `.toc` name).

## commands

| command | what it does |
| --- | --- |
| `/esm` | the help line |
| `/esm on` / `/esm off` | markers on or off |
| `/esm corner` / `/esm top` | inside the top right of the slot (default), or floating above it |
| `/esm size 0.6` | marker size as a fraction of the slot width (0.1 - 1.5) |
| `/esm max 2` | how many set icons one slot may draw at once (1 - 6, default 3). `1` is the old one-icon behaviour |
| `/esm icon Interface\\Icons\\INV_Misc_Bag_08` | one icon for every set (`/esm icon reset` for the set icons) |
| `/esm tooltip off` | drop the "Equipment set:" tooltip line |
| `/esm equip off` | skip the character equipment slots |
| `/esm verbose off` | stop the status lines at login |
| `/esm reset` | defaults |
| `/esm dump` | everything the addon can see: client build, which container frames and buttons it found, the sets with the icon each source gave and its raw api returns, what the per slot api answers for a filled slot, how much work it has done, and any step that threw |

the icons of a multi-set slot sit in a row that **never gets wider than the slot**: the first set
keeps the corner, the others hang to its left, and they shrink together when the row would not
fit (`/esm dump` prints `icons: limit 3  widest slot 2`, so a slot that came out tiny explains
itself).

settings live in `EquipmentSetMarkerDB` in SavedVariables. it used to be `EquipSetMarkerDB`, and
the old table is adopted once on load - saved variables are only filled where a key is missing,
so a rename without that step silently resets everyone.

## cost

the addon does nothing when it has nothing to do, deliberately: an `OnUpdate` script runs **every
frame the client draws**, so an addon that polls costs a slice of a core even with every bag shut.

- a refresh only looks at slots that are on screen. `IsVisible` is asked of the *container* frame,
  not `IsShown` of the slot - a closed bag leaves its own buttons flagged as shown
- when nothing has changed for a second the updater detaches its `OnUpdate` entirely and a timer
  takes one cheap look around every two seconds. opening a bag or the character pane wakes it
  through the frames own `OnShow`, a bag or equipment change wakes it through its event
- a slot whose marker already shows the right texture, size and anchor is not written again
- `/esm dump` prints the evidence: `work: refreshes N  slot passes M  awake|parked  parked K times`.
  with the bags shut, `refreshes` and `slot passes` should stop climbing

measured in the harness: 300 idle frames used to cost 300 lua callbacks (one per frame, forever)
and now cost 0. a refresh after a bag event used to resolve every learned slot whether visible or
not - a client call per hidden slot - and now makes none.

## if the icons are missing

`/esm dump`, then read it top down:

- `sets 0` - no saved sets on this character, or `C_EquipmentSet` is unreachable
- `items 0` while sets are listed - the sets are found but the item list call has another shape on
  this build; the `raw info` line under each set shows what it really returns
- `buttons 0` - no bag buttons found. open the bags, then dump again
- `step failed: ...` - a client call threw, and the line names it
- `icon nil (nil)` under a set together with `slot api: false` - this client gives the set icon
  through neither call, so the generic sparkle is all there is
- `widest slot 1` while an item is clearly in two sets - the two sets share one icon (so it is
  drawn once), or `/esm max 1` is in effect

open an issue with the dump pasted in and the marker stops being a mystery.

## how it finds the slots on this client

Forever is on the 11.x derived engine, where the classic container globals are gone, so nothing
here relies on any single one of them:

- frames: `ContainerFrameContainer.ContainerFrames`, `ContainerFrameCombinedBags`, the legacy
  `ContainerFrame<N>`, and `ItemFrame.Containers` tables (that is where GW2_UI keeps its own
  containers - it hides blizzards frames and moves them off screen, so ignoring them means drawing
  where nobody can see it)
- buttons: `frame:EnumerateValidItems()`, else `frame.Items[i]`, else `gw_items`, else
  `<name>Item<i>`
- which slot: the buttons `ItemLocation` / `GetBagID()` first, the frames `GetID()` as fallback,
  and `button:GetItem()` as the last resort that needs no numbering at all
- triggers: no `ContainerFrame_Update` global exists to hook, so it is `BAG_UPDATE_DELAYED`,
  `EQUIPMENT_SETS_CHANGED`, `PLAYER_EQUIPMENT_CHANGED` plus each frames own `UpdateItems` and
  `OnShow`

## dev/ - the harness

`dev/` is a test rig that runs the addon **without the game**. `dev/harness.lua` stubs the parts of
the wow api the addon touches (frames, textures, events, `C_EquipmentSet`, `C_Container`, a fake
bag with five slots) and then drives it: load the addon, put items in bags, change a set, run
`/esm`, move an item out, close the bag - asserting the marker state after each step. eight
scenarios cover two different container shapes, a client whose api throws, old saved variables,
four different shapes of set icon, and the idle cost. it needs node with
[fengari](https://github.com/fengari-lua/fengari) (a lua vm in javascript):

    cd dev && bun add fengari        # or: npm install fengari
    node run.js ../EquipmentSetMarker.lua harness.lua blizzard

see `dev/README.md` for the other scenarios and what each one is guarding.

## license

MIT - see [LICENSE](LICENSE).
