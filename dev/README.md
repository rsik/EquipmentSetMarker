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

37 checks in each bag scenario, 39 in `stale`, 34-35 in the icon scenarios, 9 in `broken` - 275 total. When a check goes red, read the label: it
says what the addon was expected to do. Before trusting a green run, break the change by hand
and confirm the check goes red - a fence that cannot fail is decoration.
