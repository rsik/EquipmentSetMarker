# dev harness (not loaded by the game, the toc does not list it)

the addon can be run without the client. `harness.lua` stubs the wow frame/api surface and
drives the real addon file through: load, ADDON_LOADED, a filled bag, a set change, items
moving, every slash command, the tooltip line, and a client api that throws.

    cd dev
    npm install fengari           # once, a lua vm in node
    node run.js ../EquipmentSetMarker.lua harness.lua blizzard
    node run.js ../EquipmentSetMarker.lua harness.lua gw2
    node run.js ../EquipmentSetMarker.lua harness.lua broken
    node run.js ../EquipmentSetMarker.lua harness.lua numicon
    node run.js ../EquipmentSetMarker.lua harness.lua slotapi
    node run.js ../EquipmentSetMarker.lua harness.lua swapped
    node run.js ../EquipmentSetMarker.lua harness.lua noicon

scenarios:

- `blizzard` - `ContainerFrameContainer.ContainerFrames`, buttons answer `GetItemLocation`
- `gw2` - GW2_UI shape: unnamed `ItemFrame.Containers` frames, `gw_items`, buttons only know `GetID()`
- `broken` - `C_EquipmentSet` throws; the command must still answer and dump must name the api
- `stale` - saved variables from an older version (a bad old default) must be migrated, the
  users own scale must survive
- `numicon` - the set icon comes back as a texture id (number) instead of a path
- `slotapi` - the set info call has no icon, only the per slot api does; and that answer must
  not survive the item leaving the slot
- `swapped` - the icon path comes back before the name, so values must be classified and not
  read by position
- `noicon` - no icon anywhere, and the small numbers in the return (item counts) must not be
  painted as a texture
- the multi icon checks live in the bag scenarios: an item in two sets draws two icons in set
  order, the row never gets wider than the slot (checked again at size 1, where one icon already
  is the whole slot), `/esm max` caps and restores them, the second icon goes away when its set
  drops the item, and the tooltip prints one line per set

457 checks in total: 69 in `blizzard` and `gw2`, 73 in `stale`, 68 in `swapped`, 56 in the icon
scenarios, 10 in `broken`. When a check goes red, read the label: it
says what the addon was expected to do. Before trusting a green run, break the change by hand
and confirm the check goes red - a fence that cannot fail is decoration. The four mutations that
must each turn something red: only index the first set per item, drop the fit-to-slot shrink,
skip hiding the leftover icons, ignore `db.max` in `markerLimit`.
