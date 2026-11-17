const { lauxlib, lualib, lua, to_luastring } = require('fengari');
const fs = require('fs');
const [addonPath, harnessPath, scenario] = process.argv.slice(2);
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
// the client puts the globals table in _G, fengari does not, and the addon looks frames up by name
lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, lua.LUA_RIDX_GLOBALS);
lua.lua_setglobal(L, to_luastring('_G'));
lua.lua_pushstring(L, to_luastring(fs.readFileSync(addonPath, "utf8")));
lua.lua_setglobal(L, to_luastring('__addonSrc'));
lua.lua_pushstring(L, to_luastring(scenario || 'blizzard'));
lua.lua_setglobal(L, to_luastring('__scenario'));
const rc = lauxlib.luaL_dofile(L, to_luastring(harnessPath));
if (rc !== lua.LUA_OK) { console.error('harness error: ' + lua.lua_tojsstring(L, -1)); process.exit(1); }
