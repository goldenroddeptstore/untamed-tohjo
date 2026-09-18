
-- Local aliases: avoids repeated global-table lookups in hot spatial code.
local abs, floor, min, max, random =
  math.abs, math.floor, math.min, math.max, math.random

local MAX_DEX = 493
local FALLBACK_DEX = 25
local UNOWN_DEX = 201
local CASTFORM_DEX = 351

local Unown

local Mon

local Roamers

local ZoomMod

local Encounter

local Specials

local function unownLetter(mon)
  if not (Unown and mon) then return nil end
  local idx = Unown.monLetter(mon)
  return idx and Unown.name(idx) or nil
end

-- Read-only: mon._krCastformForm is KR's interop field. Translate KR's
-- sunny/rainy/snowy names to the atlas's sun/rain/cloud keys (no snow form).
local CASTFORM_FORM_MAP = { sunny = "sun", rainy = "rain", snowy = "cloud" }

local FORM_READERS = {
  [UNOWN_DEX] = unownLetter,
  [CASTFORM_DEX] = function(mon)
    local suffix = mon and mon._krCastformForm
    return suffix and CASTFORM_FORM_MAP[suffix] or nil
  end,
}

local function formOf(dex, mon)
  local reader = FORM_READERS[dex]
  return reader and reader(mon) or nil
end

local function leadMon(mod, game, world)
  local save = (game and game.save) or (world and world.save)
  local party = save and save.party
  if type(party) ~= "table" or #party == 0 then return nil end
  for _, mon in ipairs(party) do
    if mon and (mon.hp or 0) > 0 then
      return mon, (mon.species and mod.content.pokemon:get(mon.species)) or nil
    end
  end
  return nil
end

local CARD, FRAME_COUNT = 16, 6
local RUNTIME_SHADES = { 0, 85, 170 }
local RUNTIME_SHADES_85_170 = { 85, 170 }
local RUNTIME = { pals = nil, warned = {}, spriteImages = {} }

local function hexToUnit(h)
  return tonumber(h:sub(2, 3), 16) / 255,
         tonumber(h:sub(4, 5), 16) / 255,
         tonumber(h:sub(6, 7), 16) / 255
end

local function decodeFlatJson(raw)
  local pos = 1
  local function skipWs() local _, e = raw:find("^%s*", pos); pos = e + 1 end
  local function expect(ch)
    skipWs()
    if raw:sub(pos, pos) ~= ch then error("expected '" .. ch .. "' at " .. pos) end
    pos = pos + 1
  end
  local function parseString()
    skipWs()
    expect('"')
    local s, e = raw:find('^[^"]*', pos)
    local str = raw:sub(s, e)
    pos = e + 1
    expect('"')
    return str
  end
  local function parseValue()
    skipWs()
    local c = raw:sub(pos, pos)
    if c == '"' then return parseString() end
    if c == "t" then pos = pos + 4; return true end
    if c == "f" then pos = pos + 5; return false end
    if c == "n" then pos = pos + 4; return nil end
    if c == "[" then
      pos = pos + 1
      local arr = {}
      skipWs()
      if raw:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parseValue()
        skipWs()
        local sep = raw:sub(pos, pos)
        pos = pos + 1
        if sep == "]" then break end
        if sep ~= "," then error("expected ',' or ']' at " .. pos) end
      end
      return arr
    end
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skipWs()
      if raw:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        local key = parseString()
        expect(":")
        obj[key] = parseValue()
        skipWs()
        local sep = raw:sub(pos, pos)
        pos = pos + 1
        if sep == "}" then break end
        if sep ~= "," then error("expected ',' or '}' at " .. pos) end
      end
      return obj
    end
    local s, e, num = raw:find("^(-?%d+%.?%d*)", pos)
    if not s then error("unexpected character at " .. pos) end
    pos = e + 1
    return tonumber(num)
  end
  return parseValue()
end

-- atlas.json keys (dex[, "_" form]) to {frame, normal, shiny, shades}.
local function loadManifest(mod)
  if RUNTIME.manifest ~= nil then return RUNTIME.manifest or nil end
  local manifest = false
  local okRead, raw = pcall(function() return mod:read("assets/mon/atlas.json") end)
  if okRead and raw then
    local okDecode, decoded = pcall(decodeFlatJson, raw)
    if okDecode and type(decoded) == "table" then manifest = decoded end
  end
  RUNTIME.manifest = manifest
  return manifest or nil
end

local function loadAtlasImage(mod)
  if RUNTIME.atlas ~= nil then return RUNTIME.atlas or nil end
  local atlas = false
  local okImg, data = pcall(love.image.newImageData, mod.assets:path("assets/mon/atlas.png"))
  if okImg then atlas = data end
  RUNTIME.atlas = atlas
  return atlas or nil
end

local function nearestShade(v255)
  local best, bestDelta = RUNTIME_SHADES[1], math.huge
  for _, s in ipairs(RUNTIME_SHADES) do
    local d = abs(s - v255)
    if d < bestDelta then bestDelta, best = d, s end
  end
  return best
end

local function ribbonFoam(x, row)
  if row == 0 then return (x % 8) < 4 else return (x % 8) >= 4 end
end

local function buildRuntimeSheet(atlasData, atlasX0, atlasY0, lut, submerge)
  local w, h = CARD, CARD * FRAME_COUNT
  local out = love.image.newImageData(w, h)
  for frame = 0, FRAME_COUNT - 1 do
    local y0 = frame * CARD
    for y = y0, y0 + CARD - 1 do
      for x = 0, CARD - 1 do
        local r, _, _, a = atlasData:getPixel(atlasX0 + x, atlasY0 + y)
        if a > 0 then
          local shade = nearestShade(floor(r * 255 + 0.5))
          local c = lut[shade]
          if c then out:setPixel(x, y, c[1], c[2], c[3], a) end
        end
      end
    end
    if submerge then
      local top, bot = y0 + 9, y0 + 10
      for x = 0, CARD - 1 do
        local reaches = false
        for y = y0 + 8, y0 + 11 do
          local _, _, _, a = out:getPixel(x, y)
          if a > 0 then reaches = true break end
        end
        if reaches and ribbonFoam(x, 0) then
          out:setPixel(x, top, 232 / 255, 232 / 255, 248 / 255, 1)
        end
        if reaches and ribbonFoam(x, 1) then
          out:setPixel(x, bot, 232 / 255, 232 / 255, 248 / 255, 1)
        else
          out:setPixel(x, bot, 0, 0, 0, 0)
        end
        for y = y0 + 11, y0 + CARD - 1 do
          out:setPixel(x, y, 0, 0, 0, 0)
        end
      end
    end
  end
  return out
end

-- The built IMAGE is cached by (dex, terrain, form, shiny) and shared across
-- callers. The def TABLE is rebuilt fresh every call since its `id` prefix
-- is a real type-tag (reskin fixups read it), not safe to share.
local function spriteDefFor(mod, idPrefix, dex, terrain, form, shiny)
  if not (love and love.image) then return nil end

  local key = dex .. "_" .. terrain .. (form and ("_" .. form) or "")
    .. (shiny and "_S" or "")
  local image = RUNTIME.spriteImages[key]
  if image == nil then
    local manifest = loadManifest(mod)
    if not manifest then return nil end

    local ok, result = pcall(function()
      local atlasData = loadAtlasImage(mod)
      if not atlasData then error("atlas.png unavailable") end
      local atlasKey = tostring(dex)
      if form then
        local suffixed = dex .. "_" .. form
        if manifest[suffixed] then atlasKey = suffixed end
      end
      local entry = manifest[atlasKey]
      if not entry then error("no atlas entry for " .. atlasKey) end
      local colors = (shiny and entry.shiny) or entry.normal
      local frame = entry.frame
      -- Shade 0 (outline) is always black and omitted from the manifest;
      -- colors[1]/[2] are shade 85/170 (some species have no shade 170).
      local lut = { [0] = { 0, 0, 0 } }
      for i, shade in ipairs(RUNTIME_SHADES_85_170) do
        if colors[i] then
          local r, g, b = hexToUnit(colors[i])
          lut[shade] = { r, g, b }
        end
      end
      return buildRuntimeSheet(atlasData, frame[1], frame[2], lut, terrain == "water")
    end)
    if not ok then
      if not RUNTIME.warned[key] then
        RUNTIME.warned[key] = true
        mod.log:error("overworldmons: sprite build failed for "
          .. key .. " (no sprite for this combo): " .. tostring(result))
      end
      RUNTIME.spriteImages[key] = false
      return nil
    end
    image = result
    RUNTIME.spriteImages[key] = image
  end
  if not image then return nil end -- cached failure

  return {
    id = idPrefix .. (terrain == "water" and "W_" or "") .. key,
    image = image,
    frames = FRAME_COUNT,
    walker = true,
    spriteType = "WALKING_SPRITE",
    trueColor = true,
  }
end

local function bootstrapDef(mod, id)
  return {
    id = id,
    image = mod.path .. "/assets/mon/bootstrap.png",
    frames = FRAME_COUNT,
    walker = true,
    spriteType = "WALKING_SPRITE",
    trueColor = true,
  }
end

local FOLLOWER_SPRITE = "OWM_FOLLOWER_SLOT"

local POOL = 24
local RADIUS = { x = 4, y = 4 }
local WANDER, SWIM_WANDER = 2, 0x24
local MAX_LIVE_SHINIES = 3

local SPARKLE_FRAME_W, SPARKLE_FRAME_H, SPARKLE_FRAMES = 16, 24, 21
local SPARKLE_FRAME_SECONDS = 0.12

local function loadSparklePalette(mod)
  if RUNTIME.sparklePal ~= nil then return RUNTIME.sparklePal or nil end
  local pal = false
  local okRead, raw = pcall(function() return mod:read("assets/vfx/palettes.json") end)
  if okRead and raw then
    local okDecode, decoded = pcall(decodeFlatJson, raw)
    if okDecode and type(decoded) == "table" then pal = decoded.sparkle end
  end
  RUNTIME.sparklePal = pal
  return pal or nil
end

local SPARKLE_POOL = 8

-- A real companion NPC (not a render.hud overlay) so native draw handles
-- zoom offset and battle-screen hiding for free.
local function buildSparkleDef(mod)
  if RUNTIME.sparkleDef ~= nil then return RUNTIME.sparkleDef or nil end
  local def = false
  local ok, result = pcall(function()
    if not (love and love.image) then error("no love.image") end
    local pal = loadSparklePalette(mod)
    if not pal then error("assets/vfx/palettes.json missing 'sparkle' entry") end
    local lut = {}
    for i, s in ipairs(pal.shades) do
      local r, g, b = hexToUnit(pal.normal[i])
      lut[s] = { r, g, b }
    end
    local src = love.image.newImageData(mod.assets:path("assets/vfx/sparkle_gray.png"))
    local out = love.image.newImageData(SPARKLE_FRAME_W, SPARKLE_FRAME_H * SPARKLE_FRAMES)
    for y = 0, SPARKLE_FRAME_H * SPARKLE_FRAMES - 1 do
      for x = 0, SPARKLE_FRAME_W - 1 do
        local r, _, _, a = src:getPixel(x, y)
        if a > 0 then
          local shade = nearestShade(floor(r * 255 + 0.5))
          local c = lut[shade]
          if c then out:setPixel(x, y, c[1], c[2], c[3], a) end
        end
      end
    end
    return {
      id = "OWM_SPARKLE_SHEET",
      image = out,
      frames = SPARKLE_FRAMES,
      frameWidth = SPARKLE_FRAME_W,
      frameHeight = SPARKLE_FRAME_H,
      anchorX = SPARKLE_FRAME_W / 2,
      anchorY = SPARKLE_FRAME_H,
      walker = false,
      spriteType = "STANDING_SPRITE",
      trueColor = true,
    }
  end)
  if ok then def = result end
  RUNTIME.sparkleDef = def
  if not def then
    mod.log:error("overworldmons: sparkle sprite build failed: " .. tostring(result))
  end
  return def or nil
end

local MIN_SPAWN_DIST = 4
local CELLS_PER = 24
local MIN_DENSITY_CAP = 3
local MAX_DENSITY_CAP = POOL
local FALLBACK_VIEW_RADIUS = 5
local VIEW_BUFFER = 4
local DESPAWN_SLACK = 6
local MIN_WANDERER_SPACING = 3
local STEP_THROTTLE = 2

-- INCENSE submenu cycles wanderer density; REPEL also stamps save.repelSteps
-- so the engine's own repel gate blocks ordinary encounters for us.
local INCENSE_KEY = "incenseMode"
local INCENSE_SCREEN = "OverworldmonsIncense"
local INCENSE_ORDER = { "off", "low", "medium", "high", "repel" }
local INCENSE_SHORT_LABEL = {
  off = "OFF", low = "LOW", medium = "MEDIUM", high = "HIGH", repel = "REPEL",
}
local INCENSE_DESC = {
  off = "No Pokemon on the overworld.",
  low = "Fewer Pokemon appear.",
  medium = "A normal amount of Pokemon.",
  high = "Lots of Pokemon appear.",
  repel = "Only Roamers appear now.",
}
local INCENSE_DENSITY = { low = 0.3, medium = 0.6, high = 1.0 }
local INCENSE_REPEL_STEPS = 999999

local DECAY_MIN_SECONDS = 20
local DECAY_MAX_SECONDS = 35

-- MOVE.STANDING_DOWN: no autonomous wander, but scriptStep can still turn it.
-- A mod-owned NPC (not the engine's Pikachu-only follower module) so both
-- generations can share it.
local NPC_MOVE_STAND = 6

local followerNpcId, followerIndex, followerMapId
-- Captured once at spawn: WorldAPI:npc() is a linear scan + fresh table alloc
-- per call, too costly for the per-tick reskin()/advanceMovement() lookups.
-- rebuildPeople keeps mod-spawned npcs as the same table, so this stays valid.
local followerNpcRef
local followerTrail, followerGoal
local pokeballAnim -- in-flight Pokeball drop sequence, see startPokeballDrop
local pendingHealBall = false -- true while waiting for script.ended after a heal
local followerBootSpawn = false -- true for one spawn after a via=="boot" map.entered
-- A seamless connection crossing keeps coordinates continuous, so the
-- follower's offset from the player survives it. map.exited snapshots that
-- offset into pendingHandoff; map.entered promotes it to
-- pendingConnectionOffset for reskin() to re-apply on respawn.
local pendingHandoff, pendingConnectionOffset
local hideFollowerEmote, npcHasActiveEmote

local function currentFollowerHandle(mod)
  return followerNpcRef
end

-- Detects the engine dropping our npc from world.npcs outside despawnFollower
-- (rebuildPeople has many call sites). Checked periodically, not per-frame,
-- to avoid reintroducing the O(world.npcs) cost the ref cache avoids.
local function followerRefIsStale(world)
  if not followerNpcRef then return false end
  for _, npc in ipairs(world and world.npcs or {}) do
    if npc == followerNpcRef then return false end
  end
  return true
end

local function despawnFollower(mod)
  if followerNpcId then mod.world:removeNpc(followerNpcId) end
  followerNpcId, followerIndex, followerMapId = nil, nil, nil
  followerNpcRef = nil
  followerTrail, followerGoal = nil, nil
  if pokeballAnim then
    mod.world:removeNpc(pokeballAnim.npcId)
    pokeballAnim = nil
  end
  hideFollowerEmote(mod)
end

local function spawnFollower(mod, mapId, cx, cy, facing)
  despawnFollower(mod)
  if not (mapId and cx and cy) then return end
  local npcId = mod.world:spawnNpc(mapId, {
    sprite = FOLLOWER_SPRITE, x = cx, y = cy,
    movement = NPC_MOVE_STAND, radius = { x = 0, y = 0 },
  })
  if type(npcId) ~= "string" then return end
  local index = tonumber(npcId:match("_obj_(%d+)$"))
  local h = index and mod.world:npc(mapId, index)
  if not (h and h.npc) then
    mod.world:removeNpc(npcId)
    return
  end
  h.npc.passable = true
  h.npc.facing = facing or "down"
  -- -1 py so a same-cell overlap with the player always sorts behind them (World:drawPeople draws ascending py last-on-top)
  h.npc.px, h.npc.py = cx * 16, cy * 16 - 1
  followerNpcId, followerIndex, followerMapId = npcId, index, mapId
  followerNpcRef = h.npc
  -- Seed the trail to the PLAYER's cell, not the spawn cell, so
  -- advanceMovement doesn't stall for a tile when spawned off-player.
  local p = mod.game and mod.game.world and mod.game.world.player
  followerTrail = p and { x = p.cellX, y = p.cellY } or { x = cx, y = cy }
  followerGoal = nil
end

-- pokeball.png: 16x48 vertical sheet, top-to-bottom = opening/release/closed
local POKEBALL_SPRITE = "OWM_POKEBALL_SLOT"
local POKEBALL_FRAME_W, POKEBALL_FRAME_H, POKEBALL_FRAMES = 16, 16, 3
local POKEBALL_FRAME_OPEN, POKEBALL_FRAME_RELEASE, POKEBALL_FRAME_CLOSED = 0, 1, 2
local POKEBALL_DROP_SECONDS = 0.45
local POKEBALL_OPEN_SECONDS = 0.22
local POKEBALL_RELEASE_SECONDS = 0.22
local POKEBALL_BOUNCE_PX = 10

local FOLLOWER_BEHIND_DELTA = { -- opposite of facing, for the heal ball's drop cell
  up = { 0, 1 }, down = { 0, -1 }, left = { 1, 0 }, right = { -1, 0 },
}

-- Mirrors Map.DELTA: map.entered fires before tryConnection's rewind of
-- player.cellX/Y, so this anticipates it to avoid a one-frame flash.
local CONNECTION_DIR_DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }

local function behindPlayerCell(world, p)
  local delta = FOLLOWER_BEHIND_DELTA[p.facing]
  local bx = p.cellX + (delta and delta[1] or 0)
  local by = p.cellY + (delta and delta[2] or 0)
  local map = world and world.map
  if map and map.isWalkableCell and not map:isWalkableCell(bx, by) then
    return p.cellX, p.cellY -- behind is a wall: fall back to the player's own cell
  end
  return bx, by
end

local BOOT_SPAWN_OFFSETS = { -- cardinal before diagonal, checked in order
  { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 },
  { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

local function cellOccupied(world, cx, cy)
  for _, npc in ipairs(world and world.npcs or {}) do
    if npc.cellX == cx and npc.cellY == cy then return true end
  end
  return false
end

local function findFreeSpawnCell(world, p)
  local map = world and world.map
  for _, d in ipairs(BOOT_SPAWN_OFFSETS) do
    local cx, cy = p.cellX + d[1], p.cellY + d[2]
    if (not map or not map.isWalkableCell or map:isWalkableCell(cx, cy))
        and not cellOccupied(world, cx, cy) then
      return cx, cy
    end
  end
  return p.cellX, p.cellY -- boxed in on every side: fall back to co-located
end

local function buildPokeballDef(mod)
  if RUNTIME.pokeballDef ~= nil then return RUNTIME.pokeballDef or nil end
  RUNTIME.pokeballDef = {
    id = POKEBALL_SPRITE,
    image = mod.path .. "/assets/vfx/pokeball.png",
    frames = POKEBALL_FRAMES,
    frameWidth = POKEBALL_FRAME_W,
    frameHeight = POKEBALL_FRAME_H,
    anchorX = POKEBALL_FRAME_W / 2,
    anchorY = POKEBALL_FRAME_H,
    walker = false,
    spriteType = "STANDING_SPRITE",
    trueColor = true,
  }
  return RUNTIME.pokeballDef
end

local function pokeballDropOffsetPx(u) -- ease-out fall through 65%, then one decaying bounce
  if u < 0.65 then
    local f = 1 - (u / 0.65)
    return POKEBALL_BOUNCE_PX * f * f
  end
  local f = (u - 0.65) / 0.35
  return POKEBALL_BOUNCE_PX * 0.3 * math.sin(math.pi * f)
end

local function startPokeballDrop(mod, mapId, cx, cy, facing) -- cx/cy is exactly where the follower should end up
  if pokeballAnim or not (mapId and cx and cy) then return end
  local def = buildPokeballDef(mod)
  if not def then return end
  local world = mod.game and mod.game.world
  if world and world.sprites then world.sprites[POKEBALL_SPRITE] = def end
  local npcId = mod.world:spawnNpc(mapId, {
    sprite = POKEBALL_SPRITE, x = cx, y = cy,
    movement = NPC_MOVE_STAND, radius = { x = 0, y = 0 },
  })
  if type(npcId) ~= "string" then return end
  local index = tonumber(npcId:match("_obj_(%d+)$"))
  local h = index and mod.world:npc(mapId, index)
  if not (h and h.npc) then
    mod.world:removeNpc(npcId)
    return
  end
  h.npc.passable = true
  h.npc.facing = "down"
  pokeballAnim = {
    mapId = mapId, npcId = npcId, index = index, npcRef = h.npc,
    cx = cx, cy = cy, facing = facing or "down",
    phase = "drop", clock = 0, frame = POKEBALL_FRAME_CLOSED,
  }
  -- Installed once, not rebuilt every frame.
  local anim = pokeballAnim
  h.npc.bounceFrame = function() return anim.frame end
end

local function updatePokeballDrop(mod, dt)
  if not pokeballAnim then return end
  local a = pokeballAnim
  local npc = a.npcRef
  if not npc then
    pokeballAnim = nil
    return
  end
  a.clock = a.clock + (dt or 0)

  local frame, offsetPx = POKEBALL_FRAME_CLOSED, 0
  if a.phase == "drop" then
    local u = min(1, a.clock / POKEBALL_DROP_SECONDS)
    offsetPx = pokeballDropOffsetPx(u)
    if a.clock >= POKEBALL_DROP_SECONDS then a.phase, a.clock = "opening", 0 end
  elseif a.phase == "opening" then
    frame = POKEBALL_FRAME_OPEN
    if a.clock >= POKEBALL_OPEN_SECONDS then a.phase, a.clock = "release", 0 end
  elseif a.phase == "release" then
    frame = POKEBALL_FRAME_RELEASE
    if a.clock >= POKEBALL_RELEASE_SECONDS then
      mod.world:removeNpc(a.npcId)
      pokeballAnim = nil
      spawnFollower(mod, a.mapId, a.cx, a.cy, a.facing)
      return
    end
  end
  npc.px, npc.py = a.cx * 16, a.cy * 16 - offsetPx
  a.frame = frame
end

local function setupFollower(mod)
  -- spriteDefFor caches by (dex, terrain, form, shiny) itself now, shared
  -- across every system that calls it -- no per-system cache needed here.
  local function defFor(dex, terrain, form, shiny)
    return spriteDefFor(mod, "OWM_FOLLOWER_", dex, terrain, form, shiny)
  end

  do
    local ok, err = pcall(function()
      mod.content.sprites:patch(FOLLOWER_SPRITE, bootstrapDef(mod, FOLLOWER_SPRITE))
    end)
    if not ok then
      mod.log:error("overworldmons: follower sprite registration failed: " .. tostring(err))
      return
    end
  end

  local function followerTerrain(world, npc)
    local map = world and world.map
    if not (npc and map and map.isWaterCell) then return "land" end
    if map:isWaterCell(npc.cellX, npc.cellY) then return "water" end
    if npc.targetX and map:isWaterCell(npc.targetX, npc.targetY) then
      return "water"
    end
    return "land"
  end

  local function dexOfRec(rec)
    local dex = rec and rec.dex
    if type(dex) == "number" and dex >= 1 and dex <= MAX_DEX then return dex end
    return nil
  end

  -- Species water-type/Surf-TMHM eligibility is cached by dex (static data);
  -- mon.moves is checked fresh each call since it can change at runtime.
  local canSwimBySpecies = {}
  local function speciesCanSwim(dex, rec)
    local cached = canSwimBySpecies[dex]
    if cached ~= nil then return cached end
    local result = false
    for _, t in ipairs(rec and rec.types or {}) do
      if t == "WATER" then result = true; break end
    end
    if not result then
      for _, m in ipairs(rec and rec.tmhm or {}) do
        if m == "SURF" then result = true; break end
      end
    end
    canSwimBySpecies[dex] = result
    return result
  end

  local function canSwim(dex, mon, rec)
    if speciesCanSwim(dex, rec) then return true end
    for _, m in ipairs(mon and mon.moves or {}) do
      if (type(m) == "table" and m.id or m) == "SURF" then return true end
    end
    return false
  end

  local lastTerrain, lastForm, lastShinyApplied
  local lastDex -- only a real species change should Pokeball
  -- Cached by dvs table reference (a real dvs edit reassigns the table),
  -- so this avoids re-running Mon.isShiny every tick when nothing changed.
  local lastDvsRef, lastMonShiny

  local function reskin(game, world)
    local mon, rec = leadMon(mod, game, world)
    local dex = mon and (dexOfRec(rec) or FALLBACK_DEX) or nil
    local npc = currentFollowerHandle(mod)

    if not dex then
      lastDex, lastTerrain, lastForm, lastShinyApplied = nil, nil, nil, nil
      lastDvsRef = nil
      pendingConnectionOffset = nil -- no lead to carry a stale cross-seam offset for
      if npc then despawnFollower(mod) end
      return
    end

    if not npc then
      if pokeballAnim or pendingHealBall then return end -- let a heal/lead-change ball finish first
      local mapId = world and world.map and world.map.id
      local p = world and world.player
      if p then
        if followerBootSpawn then
          followerBootSpawn = false
          local cx, cy = findFreeSpawnCell(world, p)
          spawnFollower(mod, mapId, cx, cy, p.facing)
        elseif pendingConnectionOffset then
          local off = pendingConnectionOffset
          pendingConnectionOffset = nil
          local cx, cy = p.cellX + off.dx, p.cellY + off.dy
          -- A small offset (e.g. x=-1) is a real transitional cell, not a
          -- wall; only a large/stale offset falls back to co-located spawn.
          if abs(off.dx) > 1 or abs(off.dy) > 1 then
            cx, cy = p.cellX, p.cellY
          end
          spawnFollower(mod, mapId, cx, cy, p.facing)
        else
          spawnFollower(mod, mapId, p.cellX, p.cellY, p.facing)
        end
      end
      npc = currentFollowerHandle(mod)
      lastDex, lastTerrain, lastForm, lastShinyApplied = nil, nil, nil, nil
    end
    if not npc then return end

    if mon.dvs ~= lastDvsRef then
      lastDvsRef = mon.dvs
      lastMonShiny = Mon and mon.dvs
        and Mon.isShiny(mon.dvs, { species = mon.species, level = mon.level })
    end
    local shiny = lastMonShiny

    local onWater = followerTerrain(world, npc) == "water"
    local swims = onWater and canSwim(dex, mon, rec)
    npc.hiddenByMovement = (onWater and not swims) or nil
    if npc.hiddenByMovement and npcHasActiveEmote(npc) then
      hideFollowerEmote(mod)
    end

    local form = formOf(dex, mon)
    local terrain = swims and "water" or "land"

    -- Compared field-by-field to avoid building a string key every tick.
    if dex ~= lastDex or terrain ~= lastTerrain or form ~= lastForm
        or shiny ~= lastShinyApplied then
      if lastDex ~= nil and dex ~= lastDex then -- a real species change, not just terrain/shiny
        if game.stack and game.stack:top() then return end -- wait for the party menu to close
        local cx, cy, facing = npc.cellX, npc.cellY, npc.facing
        local mapId = world and world.map and world.map.id
        despawnFollower(mod)
        lastDex, lastTerrain, lastForm, lastShinyApplied = nil, nil, nil, nil
        startPokeballDrop(mod, mapId, cx, cy, facing)
        return
      end
      local def = defFor(dex, terrain, form, shiny)
      if world and world.sprites then
        world.sprites[FOLLOWER_SPRITE] = def
      end
      if npc.setSpriteDef and npc:setSpriteDef(def) then
        if world.applySpritePalette then world:applySpritePalette(npc) end
      end
      lastDex, lastTerrain, lastForm, lastShinyApplied = dex, terrain, form, shiny
      mod.log:info("overworldmons: follower sheet -> dex %d (%s%s)%s", dex, terrain,
        form and (" " .. form) or "", shiny and " SHINY" or "")
    end
  end

  -- Tracks the player's live in-flight step (targetX/Y) rather than a
  -- "step landed" event, to avoid falling behind under continuous movement.
  -- Matches follower stepFrames to player speed, halved when >1 cell behind.
  local function advanceMovement(world)
    local npc = currentFollowerHandle(mod)
    local p = world and world.player
    if not (npc and p) then return end
    if not followerTrail then followerTrail = { x = p.cellX, y = p.cellY } end
    local trail = followerTrail
    local destX, destY = p.targetX or p.cellX, p.targetY or p.cellY
    if destX ~= trail.x or destY ~= trail.y then
      followerGoal = { x = trail.x, y = trail.y }
      trail.x, trail.y = destX, destY
    end

    if npc.moving or not followerGoal then return end
    local gx, gy = followerGoal.x, followerGoal.y
    if npc.cellX == gx and npc.cellY == gy then
      followerGoal = nil
      return
    end

    -- more than a screen behind (a warp, a scripted move): snap, don't walk
    local far = abs(npc.cellX - gx) + abs(npc.cellY - gy)
    if far > 6 then
      npc.cellX, npc.cellY = gx, gy
      npc.px, npc.py = gx * 16, gy * 16
      followerGoal = nil
      return
    end

    local dir
    if npc.cellX < gx then dir = "right"
    elseif npc.cellX > gx then dir = "left"
    elseif npc.cellY < gy then dir = "down"
    else dir = "up" end
    if not (dir and npc.scriptStep) then return end
    npc:scriptStep(dir)
    local stepLen = p.stepFrames or 16
    if far > 1 then stepLen = max(1, floor(stepLen / 2)) end
    npc.stepFrames = stepLen
  end

  -- No respawn here for a plain warp/door/boot: player position isn't
  -- settled until the next input.step tick, reskin() handles it.
  mod.events:on("map.entered", function(ev)
    lastDex, lastTerrain, lastForm, lastShinyApplied = nil, nil, nil, nil
    lastDvsRef = nil
    despawnFollower(mod)
    followerBootSpawn = (ev and ev.via == "boot") or false
    pendingConnectionOffset = nil
    -- Only a connection crossing keeps coordinates continuous; a warp/door
    -- lands unrelated to where the player left, so skip pendingHandoff there.
    if not (ev and ev.via == "connection" and pendingHandoff) then return end
    -- Respawn synchronously (no fade to hide a one-frame flash otherwise).
    -- Falls back to the deferred path if anything here isn't ready.
    if pokeballAnim or pendingHealBall then
      pendingConnectionOffset = pendingHandoff
      return
    end
    local world = mod.game and mod.game.world
    local p = world and world.player
    local mapId = world and world.map and world.map.id
    local delta = p and CONNECTION_DIR_DELTA[p.facing]
    local mon, rec = leadMon(mod, mod.game, world)
    if not (world and p and mapId and delta and mon) then
      pendingConnectionOffset = pendingHandoff
      return
    end
    local off = pendingHandoff
    local settledX, settledY = p.cellX - delta[1], p.cellY - delta[2]
    local cx, cy = settledX + off.dx, settledY + off.dy
    if abs(off.dx) > 1 or abs(off.dy) > 1 then
      cx, cy = settledX, settledY -- stale/implausible offset: co-locate instead
    end
    spawnFollower(mod, mapId, cx, cy, p.facing)
    -- Re-seed the trail to the settled cell, not the live un-rewound one.
    followerTrail = { x = settledX, y = settledY }
    lastDex, lastTerrain, lastForm, lastShinyApplied = nil, nil, nil, nil
    lastDvsRef = nil
    -- Apply hiddenByMovement immediately (bypassing reskin() for this tick)
    -- so a non-swimming lead doesn't flash visible on a water crossing.
    local followerNpc = currentFollowerHandle(mod)
    if followerNpc then
      -- Off the new map's grid, isWaterCell/isWalkableCell can't distinguish
      -- "land" from "off the edge of the data", so trust the terrain
      -- snapshotted off the OLD map (map.exited) instead.
      local onNewGrid = world.map and world.map.widthCells and world.map.heightCells
        and cx >= 0 and cy >= 0 and cx < world.map.widthCells and cy < world.map.heightCells
      local onWater
      if onNewGrid then
        onWater = followerTerrain(world, followerNpc) == "water"
      else
        onWater = off.wasOnWater or false
      end
      local swims = onWater and canSwim(dexOfRec(rec) or FALLBACK_DEX, mon, rec)
      followerNpc.hiddenByMovement = (onWater and not swims) or nil
    end
  end)

  -- Fires while world.player/the follower npc still hold their real
  -- pre-transition positions (setMap emits this before touching either), so
  -- this is the only point the offset between them can still be read.
  mod.events:on("map.exited", function()
    local world = mod.game and mod.game.world
    local npc, p = currentFollowerHandle(mod), world and world.player
    pendingHandoff = (npc and p) and { dx = npc.cellX - p.cellX, dy = npc.cellY - p.cellY,
      -- Snapshotted now, while the OLD map can still answer for the follower's own cell.
      wasOnWater = followerTerrain(world, npc) == "water" } or nil
    despawnFollower(mod)
  end)

  -- A pool rebuild that misses (non-seamless rebuild, mod-caused eviction)
  -- allocates a new npc table for our follower and fires this event; re-point
  -- followerNpcRef immediately instead of waiting for the 1s stale check.
  mod.events:on("world.npc_spawned", function(ev)
    if not (ev and followerNpcId and ev.npcId == followerNpcId) then return end
    -- Not mod.world:npc(): pooledNpc fires this before the new npc is
    -- inserted into world.npcs, so read world.npcPool directly instead.
    local world = mod.game and mod.game.world
    local npc = world and world.npcPool and world.npcPool[ev.npcId]
    if npc and npc ~= followerNpcRef then
      followerNpcRef = npc
      mod.log:info("overworldmons: follower npc identity re-synced after a pool rebuild")
    end
  end)

  local followerVerifyClock = 0
  local FOLLOWER_VERIFY_INTERVAL = 1

  local function tickFollower(game, dt)
    local world = mod.game and mod.game.world
    if world then
      followerVerifyClock = followerVerifyClock + (dt or 0)
      if followerVerifyClock >= FOLLOWER_VERIFY_INTERVAL then
        followerVerifyClock = followerVerifyClock % FOLLOWER_VERIFY_INTERVAL
        -- Backstop for a genuinely removed npc (npc_spawned above only
        -- fires for a recreated one); despawnFollower, not a bare nil-out,
        -- to avoid leaking an orphaned duplicate.
        if followerRefIsStale(world) then
          despawnFollower(mod)
        end
      end
      reskin(game, world)
      advanceMovement(world)
      -- Keep the follower's map-object def synced to its live cell, or an
      -- off-grid seam-crossing spawn cell gets it dropped by rebuildPeople.
      local fnpc, map = followerNpcRef, world.map
      if fnpc and fnpc.def and map and map.id == followerMapId
          and fnpc.cellX and fnpc.cellY and fnpc.cellX >= 0 and fnpc.cellY >= 0
          and fnpc.cellX < (map.widthCells or 0) and fnpc.cellY < (map.heightCells or 0) then
        fnpc.def.x, fnpc.def.y = fnpc.cellX, fnpc.cellY
      end
    end
    updatePokeballDrop(mod, dt)
  end

  mod.log:info("overworldmons: follower armed")
  return tickFollower
end

-- Despawns on HealParty, redrops the ball once the whole script ends (not just the heal)
local function setupPokecenterFollowerHide(mod, Specials)
  if not (Specials and Specials.ALL and Specials.ALL.HealParty) then
    mod.log:info("overworldmons: no gen2 Specials.HealParty seam; follower "
      .. "stays visible through Pokecenter heals")
    return
  end
  local specials = Specials.ALL
  if specials.__owmHealPartyHooked then return end
  specials.__owmHealPartyHooked = true
  local origHealParty = specials.HealParty
  specials.HealParty = function(vm)
    despawnFollower(mod)
    pendingHealBall = true
    if origHealParty then origHealParty(vm) end
  end
  mod.events:on("script.ended", function()
    if not pendingHealBall then return end
    pendingHealBall = false
    local world = mod.game and mod.game.world
    local p = world and world.player
    if not p then return end
    local cx, cy = behindPlayerCell(world, p)
    startPokeballDrop(mod, world.map and world.map.id, cx, cy, p.facing)
  end)
  mod.log:info("overworldmons: follower armed for Pokecenter heal hide/reveal")
end

local EMOTE_FRAME_W, EMOTE_FRAME_H, EMOTE_FRAMES = 16, 16, 14
local EMOTE_DEFAULT_HOLD = 1.5

local EMOTE = {
  SMILE = 0, EXCLAIM = 1, QUESTION = 2, BLOCK = 3, LIGHTNING = 4, FISH = 5,
  HEART = 6, ELLIPSIS = 7, MUSIC = 8, NEUTRAL = 9, SAD = 10, ANGRY = 11,
  CROWN = 12, ZZZ = 13,
}

local emoteFrameCache = {}
local ownEmote = nil -- the table we last assigned to world.emote, for identity checks
local emotePersistent = false

local function emoteFrameImage(mod, index)
  if emoteFrameCache[index] ~= nil then return emoteFrameCache[index] or nil end
  local ok, result = pcall(function()
    if not (love and love.image and love.graphics) then error("no love.graphics") end
    local src = love.image.newImageData(mod.assets:path("assets/vfx/emotes.png"))
    local out = love.image.newImageData(EMOTE_FRAME_W, EMOTE_FRAME_H)
    out:paste(src, 0, 0, 0, index * EMOTE_FRAME_H, EMOTE_FRAME_W, EMOTE_FRAME_H)
    return love.graphics.newImage(out)
  end)
  if not ok then
    mod.log:error("overworldmons: emote frame %d build failed: %s", index, tostring(result))
    emoteFrameCache[index] = false
    return nil
  end
  emoteFrameCache[index] = result
  return result
end

function hideFollowerEmote(mod)
  local world = mod.game and mod.game.world
  if world and world.emote == ownEmote then world.emote = nil end
  ownEmote, emotePersistent = nil, false
end

function npcHasActiveEmote(npc)
  return ownEmote ~= nil and ownEmote.entity == npc
end

local function showFollowerEmote(mod, world, followerNpc, frameIndex, opts)
  if not (world and followerNpc) then return end
  opts = opts or {}
  local image = emoteFrameImage(mod, frameIndex)
  if not image then return end
  ownEmote = { image = image, entity = followerNpc,
    left = floor((opts.holdSeconds or EMOTE_DEFAULT_HOLD) * 60 + 0.5) }
  world.emote = ownEmote
  emotePersistent = opts.persistent and true or false
end

local function setupFollowerEmotes(mod)
  local function tickFollowerEmotes(game, dt)
    if not (emotePersistent and ownEmote) then return end
    local world = mod.game and mod.game.world
    if world and world.emote == ownEmote then
      world.emote.left = 120
    else
      ownEmote, emotePersistent = nil, false
    end
  end
  return tickFollowerEmotes
end

local CRY_PITCH = { pained = 0.75, joyous = 1.25, standard = 1.0 }

local function playFollowerCry(mod, mon, category)
  if not (mon and mon.species) then return end
  local ok, Sound = pcall(require, "src.core.Sound")
  if not (ok and Sound and Sound.playCry) then return end
  local data = mod.game and mod.game.data
  if not data then return end
  local okPlay, src = pcall(Sound.playCry, data, mon.species)
  if okPlay and src and src.setPitch then
    pcall(src.setPitch, src, CRY_PITCH[category] or CRY_PITCH.standard)
  end
end

local function friendshipTier(mon)
  local h = (mon and mon.happiness) or 0
  if h < 50 then return 1 end
  if h < 150 then return 2 end
  if h < 200 then return 3 end
  return 4
end

local FORAGE_STEP_INTERVAL = 128
local FORAGE_STEPS_KEY = "forageSteps"
local FORAGE_REFUSAL_CHANCE = 10

local FORAGE_POOLS = {
  { { "Potion", 40 }, { "Antidote", 30 }, { "Poke Ball", 20 }, { "Berry", 10 } },
  { { "Super Potion", 30 }, { "Great Ball", 30 }, { "Repel", 20 },
    { "Escape Rope", 15 }, { "Full Heal", 5 } },
  { { "Hyper Potion", 30 }, { "Ultra Ball", 25 }, { "Rare Candy", 15 },
    { "Nugget", 15 }, { "Revive", 10 }, { "Max Revive", 5 } },
}

local FORAGE_MAP_OVERRIDES = {
  { prefix = "ILEX_FOREST", rare = "Leaf Stone", ultra = "SilverPowder" },
  { prefix = "BURNED_TOWER", rare = "Fire Stone", ultra = "Charcoal" },
  { prefix = "SLOWPOKE_WELL", rare = "Water Stone", ultra = "King's Rock" },
  { prefix = "WHIRL_ISLAND", rare = "Water Stone", ultra = "King's Rock" },
  { prefix = "ROUTE_10", rare = "Thunderstone", ultra = "Metal Coat" },
  { prefix = "POWER_PLANT", rare = "Thunderstone", ultra = "Metal Coat" },
  { prefix = "NATIONAL_PARK", rare = "Sun Stone", ultra = "BrightPowder" },
  { prefix = "MT_MOON", rare = "Moon Stone", ultra = "Star Piece" },
  { prefix = "RUINS_OF_ALPH", rare = "TwistedSpoon", ultra = "Cleanse Tag" },
  { prefix = "ICE_PATH", rare = "NeverMeltIce", ultra = "Spell Tag" },
  { prefix = "DARK_CAVE", rare = "Hard Stone", ultra = "Blackbelt" },
  { prefix = "MT_MORTAR", rare = "Hard Stone", ultra = "Blackbelt" },
  { prefix = "DRAGONS_DEN", rare = "Dragon Scale", ultra = "Dragon Fang" },
  { prefix = "MT_SILVER", rare = "Focus Band", ultra = "Leftovers" },
  { prefix = "ROUTE_38", rare = "Moomoo Milk", ultra = "Quick Claw" },
  { prefix = "ROUTE_39", rare = "Moomoo Milk", ultra = "Quick Claw" },
}

local FORAGE_BASE_TIER = { emote = EMOTE.EXCLAIM, cry = "standard",
  text = "%s found something in the dirt!" }
local FORAGE_RARE_TIER = { emote = EMOTE.CROWN, cry = "joyous",
  text = "%s looks incredibly proud of what it found!" }
local FORAGE_REFUSAL_TIER = { emote = EMOTE.ANGRY, cry = "standard",
  text = "%s found something... but refuses to share!" }
local FORAGE_NOROOM_TIER = { emote = EMOTE.SAD, cry = "pained",
  text = "%s found something, but there's no room for it!" }

local function forageRng()
  return ((love and love.math and love.math.random) or random)()
end

local function weightedPick(pool)
  local total = 0
  for _, e in ipairs(pool) do total = total + e[2] end
  local r = forageRng() * total
  local acc = 0
  for _, e in ipairs(pool) do
    acc = acc + e[2]
    if r < acc then return e[1] end
  end
  return pool[#pool][1]
end

local function forageTier(mon)
  local h = (mon and mon.happiness) or 0
  if h < 100 then return 1 end
  if h < 150 then return 2 end
  if h < 200 then return 3 end
  return 4
end

local function forageOverride(mapId)
  if type(mapId) ~= "string" then return nil end
  for _, ov in ipairs(FORAGE_MAP_OVERRIDES) do
    if mapId:sub(1, #ov.prefix) == ov.prefix then return ov end
  end
  return nil
end

local forageItemIndex, forageItemIndexFor = nil, nil

local function normalizeItemName(s)
  return tostring(s or ""):gsub("%A", ""):lower()
end

local function guessItemId(displayName)
  local s = tostring(displayName or ""):upper():gsub("'", "")
  s = s:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or nil
end

local function findForageItemId(data, displayName)
  if not (data and data.items) then return nil end
  local guess = guessItemId(displayName)
  if guess and data.items[guess] then return guess end
  if forageItemIndex == nil or forageItemIndexFor ~= data.items then
    forageItemIndex, forageItemIndexFor = {}, data.items
    for id, def in pairs(data.items) do
      if def and def.name then
        forageItemIndex[normalizeItemName(def.name)] = id
      end
    end
  end
  return forageItemIndex[normalizeItemName(displayName)]
end

local forageState = { ready = false, rare = false, itemName = nil }

local function rollForage(mod, world, mon)
  local h = (mon and mon.happiness) or 0
  if forageRng() * 100 >= (h / 5) then return end

  local ov = h >= 150 and forageOverride(world and world.map and world.map.id)
  local rare, itemName = false, nil
  if ov then
    local r = forageRng() * 100
    if r < 10 then
      rare, itemName = true, ov.rare
    elseif r < 12 then
      rare, itemName = true, ov.ultra
    end
  end
  if not itemName then
    itemName = weightedPick(FORAGE_POOLS[min(forageTier(mon), 3)])
  end

  forageState.ready, forageState.rare, forageState.itemName = true, rare, itemName
  local npc = currentFollowerHandle(mod)
  if npc then
    showFollowerEmote(mod, world, npc, rare and EMOTE.CROWN or EMOTE.EXCLAIM,
      { persistent = true })
  end
  mod.log:info("overworldmons: forage ready (%s%s)", itemName,
    rare and " [rare]" or "")
end

local function setupFollowerForaging(mod)
  mod.events:on("world.stepped", function(ev)
    if forageState.ready then return end
    local world = mod.game and mod.game.world
    local mon = leadMon(mod, mod.game, world)
    if not mon then return end
    local npc = currentFollowerHandle(mod)
    if npc and npc.hiddenByMovement then return end
    local steps = mod.save:get(FORAGE_STEPS_KEY, 0) + 1
    if steps < FORAGE_STEP_INTERVAL then
      mod.save:set(FORAGE_STEPS_KEY, steps)
      return
    end
    mod.save:set(FORAGE_STEPS_KEY, 0)
    rollForage(mod, world, mon)
  end)
  mod.log:info("overworldmons: follower foraging armed (Phase C)")
end

local function resolveForageTier(mod, mon)
  if not forageState.ready then return nil end
  local rare, itemName = forageState.rare, forageState.itemName
  forageState.ready, forageState.rare, forageState.itemName = false, false, nil

  if not rare and friendshipTier(mon) == 1
      and forageRng() * 100 < FORAGE_REFUSAL_CHANCE then
    return FORAGE_REFUSAL_TIER
  end

  local data = mod.game and mod.game.data
  local save = mod.game and mod.game.save
  local ok, Bag = pcall(require, "src.inventory.Bag")
  local id = findForageItemId(data, itemName)
  local granted = false
  if ok and Bag and Bag.add and id and save then
    local okAdd, addResult = pcall(Bag.add, save, id, 1, data)
    granted = okAdd and addResult and true or false
  end
  if not granted then
    mod.log:warn("overworldmons: forage item %q could not be granted (id=%s)",
      tostring(itemName), tostring(id))
    return FORAGE_NOROOM_TIER
  end
  local playerName = (save and save.player and save.player.name)
    or "You"
  local base = rare and FORAGE_RARE_TIER or FORAGE_BASE_TIER
  return { emote = base.emote, cry = base.cry, text = base.text,
    obtainedText = string.format("%s received a %s!", playerName, itemName) }
end

local FRIENDSHIP_TIERS = {
  { emote = EMOTE.BLOCK, cry = "standard",
    text = "%s turned the other way indifferently." },
  { emote = EMOTE.NEUTRAL, cry = "standard", text = "%s gave a short cry." },
  { emote = EMOTE.SMILE, cry = "joyous",
    text = "%s stepped close and gave a happy cry!" },
  { emote = EMOTE.HEART, cry = "joyous",
    text = "%s rubbed against you affectionately!" },
}

local function displayName(mon)
  return (mon and mon.nickname) or (mon and mon.species) or "Your Pokemon"
end

local ok_TextBox, TextBox = pcall(require, "src.render.TextBox")

local function addLineWaits(text)
  if not (ok_TextBox and TextBox and TextBox.paginate) then return text end
  local ok, pages = pcall(TextBox.paginate, text, nil)
  if not ok or not (pages and pages[1]) then return text end
  local lines = pages[1]
  if #lines <= 2 then return text end
  local out = { lines[1] }
  for i = 2, #lines do
    out[#out + 1] = ((i - 1) % 2 == 0) and "\v" or "\n"
    out[#out + 1] = lines[i]
  end
  return table.concat(out)
end

local ok_ItemEffects, ItemEffects = pcall(require, "src.core.gen2.ItemEffects")
local STATUS_CLASS = (ok_ItemEffects and ItemEffects and ItemEffects.STATUS_CLASS) or {
  psn = "psn", poison = "psn", toxic = "psn",
  brn = "brn", burn = "brn",
  frz = "frz", freeze = "frz",
  par = "par", paralysis = "par", paralyze = "par",
  slp = "slp", sleep = "slp",
}

local AILMENT_TIER = { emote = EMOTE.LIGHTNING, cry = "pained",
  text = "%s is shivering from the pain." }
local SLEEP_TIER = { emote = EMOTE.ZZZ, cry = nil, text = "%s is fast asleep." }
local CRITICAL_HP_TIER = { emote = EMOTE.ELLIPSIS, cry = "pained",
  text = "%s seems unsteady on its feet." }
local CRITICAL_HP_RATIO = 0.2

local function maxHpOf(mon)
  return (mon and (mon.maxHp or (mon.stats and mon.stats.hp))) or 0
end

local function priority1Tier(mon)
  local maxHp = maxHpOf(mon)
  if maxHp > 0 and (mon.hp or 0) / maxHp < CRITICAL_HP_RATIO then
    return CRITICAL_HP_TIER
  end
  local class = STATUS_CLASS[tostring((mon and mon.status) or ""):lower()]
  if class == "slp" then return SLEEP_TIER end
  if class == "psn" or class == "brn" or class == "par" or class == "frz" then
    return AILMENT_TIER
  end
  return nil
end

local ENV_TERRAIN_CHECK = { WATER = "isWaterCell", GRASS = "isGrassCell" }
local ENV_MISMATCH_CHECK = { FIRE = "isWaterCell" }
local ENV_MATCH_TIER = { emote = EMOTE.MUSIC, cry = "joyous",
  text = "%s seems perfectly at home here!" }
local ENV_MISMATCH_TIER = { emote = EMOTE.SAD, cry = "pained",
  text = "%s hates the weather here..." }
local ENV_WATER_TIER = { emote = EMOTE.FISH, cry = "standard",
  text = "%s is staring intently at the water." }
local ENV_COUNTER_TIER = { emote = EMOTE.QUESTION, cry = "standard",
  text = "%s is inspecting the area." }

local function nearCell(map, checkName, cx, cy)
  local check = checkName and map[checkName]
  if not check then return false end
  return check(map, cx, cy) or check(map, cx + 1, cy) or check(map, cx - 1, cy)
    or check(map, cx, cy + 1) or check(map, cx, cy - 1)
end

local function priority3Tier(world, npc, rec)
  local map = world and world.map
  if not (map and npc) then return nil end
  local cx, cy = npc.cellX, npc.cellY
  for _, t in ipairs(rec and rec.types or {}) do
    if nearCell(map, ENV_TERRAIN_CHECK[t], cx, cy) then return ENV_MATCH_TIER end
  end
  for _, t in ipairs(rec and rec.types or {}) do
    if nearCell(map, ENV_MISMATCH_CHECK[t], cx, cy) then return ENV_MISMATCH_TIER end
  end
  if nearCell(map, "isWaterCell", cx, cy) then return ENV_WATER_TIER end
  if nearCell(map, "isCounterCell", cx, cy) then return ENV_COUNTER_TIER end
  return nil
end

local followerInteractionBusy = false

local RELEASE_DEBOUNCE_TICKS = 6
local pendingFollowerText = nil
local followerTextCleanTicks = 0

local function queueFollowerText(mod, text, onDone)
  pendingFollowerText = { text = text, onDone = onDone }
  followerTextCleanTicks = 0
  mod.log:info("overworldmons: follower text queued: %q", text)
end

local function pickInteractionTier(mod, world, npc, mon, rec)
  return priority1Tier(mon)
    or resolveForageTier(mod, mon)
    or priority3Tier(world, npc, rec)
    or FRIENDSHIP_TIERS[friendshipTier(mon)]
end

local function runFollowerInteraction(mod, world, npc, mon, rec)
  if followerInteractionBusy then return end
  local tier = pickInteractionTier(mod, world, npc, mon, rec)
  followerInteractionBusy = true
  showFollowerEmote(mod, world, npc, tier.emote, {})
  if tier.cry then playFollowerCry(mod, mon, tier.cry) end
  local text = addLineWaits(string.format(tier.text, displayName(mon)))
  local function finish()
    followerInteractionBusy = false
    hideFollowerEmote(mod)
  end
  if tier.obtainedText then
    local obtainedText = addLineWaits(tier.obtainedText)
    queueFollowerText(mod, text, function()
      queueFollowerText(mod, obtainedText, finish)
    end)
  else
    queueFollowerText(mod, text, finish)
  end
end

local function setupFollowerInteraction(mod)
  mod.events:on("world.interacted", function(ev)
    if not ev then return end
    local world = mod.game and mod.game.world
    if not world then return end
    local npc = currentFollowerHandle(mod)
    if not (npc and npc.cellX == ev.x and npc.cellY == ev.y) then return end
    if npc.hiddenByMovement then return end
    if npc.facePlayer and world.player then npc:facePlayer(world.player) end
    mod.log:info(
      "overworldmons: world.interacted at follower cell (%s,%s) kind=%s",
      tostring(ev.x), tostring(ev.y), tostring(ev.kind))
    local mon, rec = leadMon(mod, mod.game, world)
    if not mon then return end
    runFollowerInteraction(mod, world, npc, mon, rec)
  end)

  local function tickFollowerText(game, dt)
    if not pendingFollowerText then return end
    local input = game and game.input
    if input and (input:isDown("a") or input:isDown("b")
                  or input:wasPressed("a") or input:wasPressed("b")) then
      followerTextCleanTicks = 0
      return
    end
    followerTextCleanTicks = followerTextCleanTicks + 1
    if followerTextCleanTicks < RELEASE_DEBOUNCE_TICKS then return end
    local p = pendingFollowerText
    pendingFollowerText = nil
    mod.log:info("overworldmons: follower text shown after %d clean ticks: %q",
      followerTextCleanTicks, p.text)
    local ow = mod.world and mod.world.overworld and mod.world:overworld()
    if ow and ow.showText then
      ow:showText(p.text, p.onDone)
    elseif p.onDone then
      p.onDone()
    end
  end

  mod.log:info(
    "overworldmons: follower interaction armed (Phase A+B+C: health/status, "
    .. "foraging, environment, friendship fallback)")
  return tickFollowerText
end

local MAX_CHAIN = 100
local CHAIN_SPECIES_KEY, CHAIN_COUNT_KEY = "chainSpecies", "chainCount"

-- Ramps from vanilla 1/8192 to a 1/100 floor, reached right at count 100
-- (denom(100) = 8192 - 81*100 = 92, clamped up to the 100 floor).
local CHAIN_SHINY_BASE_DENOM, CHAIN_SHINY_STEP, CHAIN_SHINY_FLOOR_DENOM = 8192, 81, 100
local CHAIN_SHINY_ATTACK_DVS = { 2, 3, 6, 7, 10, 11, 14, 15 }

local function chainFloorK(count)
  if count < 10 then return 0 end
  if count < 25 then return 1 end
  if count < 40 then return 2 end
  return 3
end

local function setupChain(mod)
  local species = mod.save:get(CHAIN_SPECIES_KEY, "")
  local count = mod.save:get(CHAIN_COUNT_KEY, 0)
  if type(species) ~= "string" or species == "" then species = nil end
  if type(count) ~= "number" or count < 0 then count = 0 end

  local function persist()
    mod.save:set(CHAIN_SPECIES_KEY, species or "")
    mod.save:set(CHAIN_COUNT_KEY, count)
  end

  local function reset()
    if species == nil and count == 0 then return end
    species, count = nil, 0
    persist()
  end

  local function resolveWild(resolvedSpecies)
    if not resolvedSpecies then return end
    if species == resolvedSpecies then
      count = min(MAX_CHAIN, count + 1)
    else
      species, count = resolvedSpecies, 1
    end
    persist()
  end

  local function forceSpecies(dist, r)
    if not (species and count > 1 and dist and dist[species]) then return nil end
    local odds = 10 - min(count, 9)
    if floor(r() * odds) == 0 then return species end
    return nil
  end

  local function rollDVs(forSpecies, level, r, Mon)
    local dvs
    if forSpecies == species and count > 0 then
      local denom = max(CHAIN_SHINY_FLOOR_DENOM,
        CHAIN_SHINY_BASE_DENOM - CHAIN_SHINY_STEP * count)
      if floor(r() * denom) == 0 then
        dvs = {
          defense = 10, speed = 10, special = 10,
          attack = CHAIN_SHINY_ATTACK_DVS[
            floor(r() * #CHAIN_SHINY_ATTACK_DVS) + 1],
        }
      else
        dvs = Mon.randomDVs()
        local k = chainFloorK(count)
        if k > 0 then
          local stats = { "attack", "defense", "speed", "special" }
          for i = #stats, 2, -1 do
            local j = floor(r() * i) + 1
            stats[i], stats[j] = stats[j], stats[i]
          end
          for i = 1, k do dvs[stats[i]] = 15 end
        end
      end
    else
      dvs = Mon.randomDVs()
    end
    dvs.hp = Mon.hpDV(dvs)
    local shiny = Mon.isShiny(dvs, { species = forSpecies, level = level })
    return dvs, shiny
  end

  local pendingWildSpecies

  mod.events:on("battle.started", function(ev)
    if not ev then return end
    if ev.kind == "trainer" then
      reset()
    elseif ev.kind == "wild" then
      pendingWildSpecies = ev.species
    end
  end)

  mod.events:on("battle.ended", function(ev)
    local resolvedSpecies = pendingWildSpecies
    pendingWildSpecies = nil
    if not resolvedSpecies then return end
    local result = ev and ev.result
    if result == "win" or result == "caught" then
      resolveWild(resolvedSpecies)
    elseif result == "run" and resolvedSpecies == species then
      reset()
    end
  end)

  mod.events:on("world.blacked_out", reset)

  mod.log:info("overworldmons: chain armed (%s x%d)", species or "none", count)

  return { forceSpecies = forceSpecies, rollDVs = rollDVs }
end

local RESKIN = {
  SPRITE_SLOWPOKE   = { species = "SLOWPOKE" },
  SPRITE_SUDOWOODO  = { species = "SUDOWOODO" },
  SPRITE_SUICUNE    = { species = "SUICUNE" },
  SPRITE_ENTEI      = { species = "ENTEI" },
  SPRITE_RAIKOU     = { species = "RAIKOU" },
  SPRITE_VOLTORB    = { species = "VOLTORB" },
  SPRITE_LAPRAS     = { species = "LAPRAS" },
  SPRITE_SNORLAX    = { species = "SNORLAX" },
  SPRITE_POLIWAG    = { species = "POLIWAG" },
  SPRITE_DIGLETT    = { species = "DIGLETT" },
  SPRITE_GROWLITHE  = { species = "GROWLITHE" },
  SPRITE_RHYDON     = { species = "RHYDON" },
  SPRITE_CLEFAIRY   = { species = "CLEFAIRY" },
  SPRITE_JIGGLYPUFF = { species = "JIGGLYPUFF" },
  SPRITE_ZUBAT      = { species = "ZUBAT" },
  SPRITE_EKANS      = { species = "EKANS" },
  SPRITE_MACHOP     = { species = "MACHOP" },
  SPRITE_ODDISH     = { species = "ODDISH" },
  SPRITE_JYNX       = { species = "JYNX" },
  SPRITE_BUTTERFREE = { species = "BUTTERFREE" },
  SPRITE_BULBASAUR  = { species = "BULBASAUR" },
  SPRITE_CHARMANDER = { species = "CHARMANDER" },
  SPRITE_SQUIRTLE   = { species = "SQUIRTLE" },
  SPRITE_PARAS      = { species = "PARAS" },
  SPRITE_WEEDLE     = { species = "WEEDLE" },
  SPRITE_SHELLDER   = { species = "SHELLDER" },
  SPRITE_GENGAR     = { species = "GENGAR" },
  SPRITE_STARMIE    = { species = "STARMIE" },
  SPRITE_TENTACOOL  = { species = "TENTACOOL" },
  SPRITE_MAGIKARP   = { species = "MAGIKARP" },
  SPRITE_GEODUDE    = { species = "GEODUDE" },
  SPRITE_TOGEPI     = { species = "TOGEPI" },
  SPRITE_GRIMER     = { species = "GRIMER" },
  SPRITE_MOLTRES    = { species = "MOLTRES" },
  SPRITE_LUGIA      = { species = "LUGIA" },
  SPRITE_HO_OH      = { species = "HO_OH" },
  SPRITE_TAUROS     = { species = "MILTANK" },
}

local function setupOverworldReskin(mod)
  if not (love and love.image) then
    mod.log:warn("overworldmons: no love.image; NPC-mon reskin off")
    return
  end
  if not (mod.content and mod.content.pokemon and mod.content.sprites) then
    mod.log:warn("overworldmons: no mod.content.pokemon/sprites seam; NPC-mon reskin off")
    return
  end

  local ok, err = pcall(function()
    for spriteId in pairs(RESKIN) do
      mod.content.sprites:patch(spriteId, bootstrapDef(mod, spriteId))
    end
  end)
  if not ok then
    mod.log:error("overworldmons: NPC-mon reskin bootstrap failed: " .. tostring(err))
    return
  end

  local done = false
  local function tickOverworldReskin(game, dt)
    if done then return end
    local world = game and game.world
    if not (world and world.sprites) then return end
    done = true
    local patched, skipped = 0, 0
    for spriteId, r in pairs(RESKIN) do
      local applyOk, applyErr = pcall(function()
        local rec = mod.content.pokemon:get(r.species)
        local dex = rec and rec.dex
        if type(dex) ~= "number" or dex < 1 or dex > MAX_DEX then
          error("no dex for species " .. tostring(r.species))
        end
        local def = spriteDefFor(mod, "OWM_OWMON_", dex, "land", nil, r.shiny)
        if not def then error("spriteDefFor returned nil") end
        world.sprites[spriteId] = def
      end)
      if applyOk then
        patched = patched + 1
      else
        skipped = skipped + 1
        mod.log:warn("overworldmons: NPC-mon reskin skipped " .. spriteId
          .. " (" .. tostring(r.species) .. "): " .. tostring(applyErr))
      end
    end
    mod.log:info("overworldmons: NPC-mon reskin patched %d/%d sprites",
      patched, patched + skipped)
  end
  return tickOverworldReskin
end

-- Per-object reskins (shared vanilla sprite records rule out a per-sprite patch);
-- uses NPC:setSpriteDef, the ROM's own repaint-in-place seam (see Npc.lua).
local OBJECT_OVERRIDES = {
  { mapId = "OLIVINE_LIGHTHOUSE_6F", index = 2, species = "AMPHAROS",
    label = "Olivine Lighthouse Ampharos" },
  { mapId = "MAHOGANY_MART_1F", index = 4, species = "DRAGONITE",
    label = "Mahogany Mart Dragonite" },  -- Lance's Dragonite cameo (Team Rocket Base trap floor) was never added in vanilla.
  { mapId = "TEAM_ROCKET_BASE_B2F", index = 4, species = "DRAGONITE",
    label = "Team Rocket Base B2F Lance's Dragonite" },
  { mapId = "ROUTE_30", index = 6, species = "RATTATA",
    label = "Route 30 battling Rattata (1)" },
  { mapId = "ROUTE_30", index = 7, species = "RATTATA",
    label = "Route 30 battling Rattata (2)" },
  { mapId = "ILEX_FOREST", index = 1, species = "FARFETCH_D",
    label = "Ilex Forest Farfetch'd" },
  { mapId = "VIOLET_NICKNAME_SPEECH_HOUSE", index = 3, species = "PIDGEY",
    label = "Violet Speech House Pidgey (STRAWBERRY)" },
  { mapId = "MOUNT_MOON_SQUARE", index = 1, species = "CLEFAIRY",
    label = "Mt Moon Square Clefairy" },

  -- These borrow a shared generic sprite but play a different cry than their
  -- talk script's species. (The Team Rocket Base B2F Voltorb/Electrode
  -- mismatch is the vanilla puzzle, left alone.)
  { mapId = "BLACKTHORN_DRAGON_SPEECH_HOUSE", index = 2, species = "DRATINI",
    label = "Blackthorn Dragon Speech House Dratini" },
  { mapId = "CELADON_CITY", index = 2, species = "POLIWRATH",
    label = "Celadon City Poliwrath" },
  { mapId = "CELADON_MANSION_1F", index = 2, species = "MEOWTH",
    label = "Celadon Mansion 1F Meowth" },
  { mapId = "CELADON_MANSION_1F", index = 4, species = "NIDORAN_F",
    label = "Celadon Mansion 1F Nidoran-F" },
  { mapId = "CERULEAN_CITY", index = 3, species = "SLOWBRO",
    label = "Cerulean City Slowbro" },
  { mapId = "CERULEAN_TRADE_SPEECH_HOUSE", index = 3, species = "KANGASKHAN",
    label = "Cerulean Trade Speech House Kangaskhan" },
  { mapId = "CHARCOAL_KILN", index = 3, species = "FARFETCH_D",
    label = "Charcoal Kiln Farfetch'd" },
  { mapId = "COPYCATS_HOUSE_1F", index = 3, species = "BLISSEY",
    label = "Copycat's House 1F Blissey" },
  { mapId = "COPYCATS_HOUSE_2F", index = 2, species = "DODRIO",
    label = "Copycat's House 2F Dodrio" },
  { mapId = "GOLDENROD_DEPT_STORE_B1F", index = 8, species = "MACHOKE",
    label = "Goldenrod Dept Store B1F Machoke" },
  { mapId = "INDIGO_PLATEAU_POKECENTER_1F", index = 6, species = "ABRA",
    label = "Indigo Plateau PokeCenter 1F Abra" },
  { mapId = "MR_FUJIS_HOUSE", index = 3, species = "PSYDUCK",
    label = "Mr Fuji's House Psyduck" },
  { mapId = "MR_FUJIS_HOUSE", index = 4, species = "NIDORINO",
    label = "Mr Fuji's House Nidorino" },
  { mapId = "MR_FUJIS_HOUSE", index = 5, species = "PIDGEY",
    label = "Mr Fuji's House Pidgey" },
  { mapId = "NATIONAL_PARK", index = 7, species = "PERSIAN",
    label = "National Park Persian" },
  { mapId = "PEWTER_NIDORAN_SPEECH_HOUSE", index = 2, species = "NIDORAN_M",
    label = "Pewter Nidoran Speech House Nidoran-M" },
  { mapId = "POKEMON_FAN_CLUB", index = 6, species = "BAYLEEF",
    label = "Pokemon Fan Club Bayleef" },
  { mapId = "RADIO_TOWER_4F", index = 3, species = "MEOWTH",
    label = "Radio Tower 4F Meowth" },
  { mapId = "ROUTE_28_STEEL_WING_HOUSE", index = 2, species = "FEAROW",
    label = "Route 28 Steel Wing House Fearow" },
  { mapId = "VIRIDIAN_NICKNAME_SPEECH_HOUSE", index = 3, species = "SPEAROW",
    label = "Viridian Speech House Spearow" },
  { mapId = "VIRIDIAN_NICKNAME_SPEECH_HOUSE", index = 4, species = "RATTATA",
    label = "Viridian Speech House Rattata" },

  -- Its talk script has no cry op (unlike the others above), so the
  -- cry-based audit missed it; confirmed species from its own text instead.
  { mapId = "TEAM_ROCKET_BASE_B3F", index = 3, species = "MURKROW",
    label = "Team Rocket Base B3F password Murkrow" },
}

local function setupObjectOverrides(mod)
  if not (love and love.image) then
    mod.log:warn("overworldmons: no love.image; per-object overrides off")
    return
  end
  if not (mod.content and mod.content.pokemon and mod.content.sprites
      and mod.world and mod.world.npc) then
    mod.log:warn("overworldmons: no mod.content/mod.world:npc seam; per-object overrides off")
    return
  end

  local ok, err = pcall(function()
    for i, o in ipairs(OBJECT_OVERRIDES) do
      o.spriteId = "OWM_OWMON_OBJ_" .. i
      mod.content.sprites:patch(o.spriteId, bootstrapDef(mod, o.spriteId))
    end
  end)
  if not ok then
    mod.log:error("overworldmons: per-object override bootstrap failed: " .. tostring(err))
    return
  end

  -- Returns "ok", "retry" (object not live yet, e.g. a masked scripted
  -- actor), or "error" (not worth retrying).
  local function attemptApply(o)
    if not o.def then
      local okDef, errDef = pcall(function()
        local rec = mod.content.pokemon:get(o.species)
        local dex = rec and rec.dex
        if type(dex) ~= "number" or dex < 1 or dex > MAX_DEX then
          error("no dex for " .. tostring(o.species))
        end
        o.def = spriteDefFor(mod, "OWM_OWMON_", dex, "land", nil, o.shiny)
        if not o.def then error("spriteDefFor returned nil") end
      end)
      if not okDef then return "error", errDef end
    end
    local h = mod.world:npc(o.mapId, o.index)
    if not (h and h.npc and h.npc.setSpriteDef) then
      return "retry", "no live npc at " .. o.mapId .. " index " .. o.index
    end
    local okSet, errSet = pcall(function()
      h.npc:setSpriteDef(o.def)
      local world = mod.game and mod.game.world
      if world and world.applySpritePalette then world:applySpritePalette(h.npc) end
    end)
    if not okSet then return "error", errSet end
    return "ok"
  end

  local activeMapId
  local pending = {}

  mod.events:on("map.entered", function(ev)
    local mapId = ev and ev.mapId
    if not mapId then return end
    activeMapId = mapId
    pending = {}
    for _, o in ipairs(OBJECT_OVERRIDES) do
      if o.mapId == mapId then
        local status, applyErr = attemptApply(o)
        if status == "ok" then
          mod.log:info("overworldmons: %s reskinned", o.label)
        elseif status == "retry" then
          pending[#pending + 1] = o
        else
          mod.log:warn("overworldmons: %s override failed: %s", o.label, tostring(applyErr))
        end
      end
    end
  end)

  local function tickObjectOverrides(game, dt)
    if #pending == 0 then return end
    local world = mod.game and mod.game.world
    if not (world and world.map and world.map.id == activeMapId) then
      pending = {}
      return
    end
    local stillPending = {}
    for _, o in ipairs(pending) do
      local status, applyErr = attemptApply(o)
      if status == "ok" then
        mod.log:info("overworldmons: %s reskinned", o.label)
      elseif status == "retry" then
        stillPending[#stillPending + 1] = o
      else
        mod.log:warn("overworldmons: %s override failed: %s", o.label, tostring(applyErr))
      end
    end
    pending = stillPending
  end
  return tickObjectOverrides
end

local RESKIN_ID_PREFIX = "OWM_OWMON_"
local DAYCARE_ID_PREFIX = "OWM_DAYCARE_"

-- These MOVE.POKEMON "scenery" objects are hardcoded FIXED_FACING by the
-- engine and re-seeded on every rebuildPeople, so this re-clears it (and
-- bouncing) on every map.entered. See setupReskinFacePlayer for the actual
-- facing fix (clearing the flag alone isn't enough).
local function setupReskinNpcFixups(mod)
  local function scrub(world)
    if not (world and world.npcs) then return end
    for _, npc in ipairs(world.npcs) do
      if npc.spriteDef and type(npc.spriteDef.id) == "string"
          and npc.spriteDef.id:find(RESKIN_ID_PREFIX, 1, true) == 1 then
        if npc.bouncing then npc.bouncing = false end
        if npc.fixedFacing then npc.fixedFacing = false end
      end
    end
  end
  mod.events:on("map.entered", function()
    scrub(mod.game and mod.game.world)
  end)
end

-- Vanilla scripts behind reskinned NPC-mons never call faceplayer, so this
-- calls NPC:facePlayer directly on interact, before the script's textbox opens.
local function setupReskinFacePlayer(mod)
  mod.events:on("world.interacted", function(ev)
    if not (ev and ev.kind == "npc" and ev.target) then return end
    local npc = ev.target
    local id = npc.spriteDef and npc.spriteDef.id
    if type(id) ~= "string" then return end
    if id:find(RESKIN_ID_PREFIX, 1, true) ~= 1
        and id:find(DAYCARE_ID_PREFIX, 1, true) ~= 1 then
      return
    end
    local world = mod.game and mod.game.world
    if npc.facePlayer and world and world.player then
      npc.fixedFacing = false
      npc:facePlayer(world.player)
    end
  end)
end

-- World.lua's SPRITE.DAY_CARE_MON_1/2: the yard objects' reserved sprite ids.
-- Scanning world.npcs for these means "a bred mon is in the yard", without
-- needing to know the map/object index ourselves.
local DAY_CARE_MON_1, DAY_CARE_MON_2 = 0xe0, 0xe1
local DAYCARE_MAN_SPRITE, DAYCARE_LADY_SPRITE = "OWM_DAYCARE_MAN", "OWM_DAYCARE_LADY"

local function setupDaycareReskin(mod)
  if not (love and love.image) then
    mod.log:warn("overworldmons: no love.image; day-care mon reskin off")
    return
  end
  if not (mod.content and mod.content.pokemon and mod.content.sprites) then
    mod.log:warn("overworldmons: no mod.content seam; day-care mon reskin off")
    return
  end

  do
    local ok, err = pcall(function()
      mod.content.sprites:patch(DAYCARE_MAN_SPRITE, bootstrapDef(mod, DAYCARE_MAN_SPRITE))
      mod.content.sprites:patch(DAYCARE_LADY_SPRITE, bootstrapDef(mod, DAYCARE_LADY_SPRITE))
    end)
    if not ok then
      mod.log:error("overworldmons: day-care sprite registration failed: " .. tostring(err))
      return
    end
  end

  local function defFor(dex, shiny)
    return spriteDefFor(mod, "OWM_DAYCARE_", dex, "land", nil, shiny)
  end

  -- Shininess read from the deposited party mon (save.dayCare.man/lady.mon)
  -- directly, since the native icon def carries no `.dvs`. Guarded per slot
  -- by npc/dex/shiny so nothing rebuilds while a mon just sits in the yard.
  local daycareLast = { man = {}, lady = {} }
  local function reskinSlot(world, npc, which)
    local save = mod.game and mod.game.save
    local dc = save and save.dayCare
    local slot = dc and dc[which]
    local mon = slot and slot.mon
    if not (mon and mon.species) then return end
    local rec = mod.content.pokemon:get(mon.species)
    local dex = rec and rec.dex
    if not (type(dex) == "number" and dex >= 1 and dex <= MAX_DEX) then return end
    local shiny = Mon and mon.dvs
      and Mon.isShiny(mon.dvs, { species = mon.species, level = mon.level })
    local last = daycareLast[which]
    if last.npc ~= npc or last.dex ~= dex or last.shiny ~= shiny then
      local def = defFor(dex, shiny)
      if def and npc.setSpriteDef and npc:setSpriteDef(def) then
        if world.applySpritePalette then world:applySpritePalette(npc) end
      end
      last.npc, last.dex, last.shiny = npc, dex, shiny
    end
    -- Clear the native MOVE.POKEMON bounce/fixedFacing override every tick
    -- (this object's def can change mid-visit; setupReskinNpcFixups doesn't
    -- reach the OWM_DAYCARE_ prefix).
    npc.bouncing = false
    npc.fixedFacing = false
  end

  -- Throttled: scans every NPC on the active map (no map-id shortcut for
  -- the yard objects), for a state that only changes on a rare menu action.
  local daycareClock = 0
  local DAYCARE_RESKIN_INTERVAL = 0.25
  local function tickDaycare(game, dt)
    daycareClock = daycareClock + (dt or 0)
    if daycareClock < DAYCARE_RESKIN_INTERVAL then return end
    daycareClock = daycareClock % DAYCARE_RESKIN_INTERVAL
    local world = game and game.world
    if not (world and world.npcs) then return end
    for _, npc in ipairs(world.npcs) do
      local s = npc.def and npc.def.sprite
      if s == DAY_CARE_MON_1 or s == DAY_CARE_MON_2 then
        reskinSlot(world, npc, s == DAY_CARE_MON_1 and "man" or "lady")
      end
    end
  end

  mod.log:info("overworldmons: day-care mon reskin armed")
  return tickDaycare
end

-- Battle-HUD shiny glyph, registered as our own font page/charmap entry.
-- Code must avoid $100-$3FF (translation font pages' accented/kana block,
-- e.g. $101 broke PT-BR accents); parked just under Font.TTF_BASE instead.
local SHINY_GLYPH_SEQ = "<SHINY>"
local SHINY_GLYPH_CODE = 0x3F0000

local function setupWild(mod, Chain, Roamers)
  if not (mod.world and mod.world.effectiveEncounters and mod.world.spawnNpc) then
    mod.log:warn("overworldmons: no gen2 mod.world spawn surface; wild off")
    return
  end

  if mod.content and mod.content.font then
    mod.content.font:register("shiny_icon", {
      image = mod.assets:path("assets/vfx/shiny_icon.png"),
      base = SHINY_GLYPH_CODE, glyphsPerRow = 1,
    })
    mod.content.font:register("charmap:shiny_icon",
      { seq = SHINY_GLYPH_SEQ, code = SHINY_GLYPH_CODE })
  end

  -- Back-fill data.encounters[kind][mapId] from gen2Encounters, per-slot
  -- (not gated on "encounters == nil"), so another mod pre-creating
  -- data.encounters doesn't zero out every ordinary route's wild table.
  local ENCOUNTER_KINDS = { "grass", "water" }
  local encounterAliasDone = false
  local function ensureEncounterAlias()
    if encounterAliasDone then return end
    local gdata = mod.game and mod.game.data
    local gen2 = gdata and gdata.gen2Encounters
    if not gen2 then return end
    encounterAliasDone = true
    gdata.encounters = gdata.encounters or {}
    local filled = 0
    for _, kind in ipairs(ENCOUNTER_KINDS) do
      local maps = gen2[kind]
      if type(maps) == "table" then
        gdata.encounters[kind] = gdata.encounters[kind] or {}
        for mapId, tbl in pairs(maps) do
          if gdata.encounters[kind][mapId] == nil then
            gdata.encounters[kind][mapId] = tbl
            filled = filled + 1
          end
        end
      end
    end
    mod.log:info("overworldmons: backfilled %d data.encounters[kind][mapId] slots from gen2Encounters", filled)
  end
  ensureEncounterAlias()

  local function defFor(dex, terrain, form, shiny)
    return spriteDefFor(mod, "OWM_WILD_SHEET_", dex, terrain, form, shiny)
  end
  local function spriteId(slot) return "OWM_WILD_" .. slot end
  local function sparkleSpriteId(slot) return "OWM_SPARKLE_" .. slot end

  local ok, err = pcall(function()
    for slot = 1, POOL do
      mod.content.sprites:patch(spriteId(slot), bootstrapDef(mod, spriteId(slot)))
    end
    for slot = 1, SPARKLE_POOL do
      mod.content.sprites:patch(sparkleSpriteId(slot), bootstrapDef(mod, sparkleSpriteId(slot)))
    end
  end)
  if not ok then
    mod.log:error("overworldmons: wanderer sprite pool registration failed: " .. tostring(err))
    return
  end

  local function dexOf(species)
    local rec = species and mod.content.pokemon:get(species)
    local dex = rec and rec.dex
    if type(dex) == "number" and dex >= 1 and dex <= MAX_DEX then return dex end
    return FALLBACK_DEX
  end

  local function rng()
    return (love and love.math and love.math.random) or random
  end

  local NEIGH = {
    { 1, 0, "right" }, { -1, 0, "left" }, { 0, 1, "down" }, { 0, -1, "up" },
  }
  local function cheb(ax, ay, bx, by)
    local dx, dy = abs(ax - bx), abs(ay - by)
    return dx > dy and dx or dy
  end

  -- Hoisted out of visibleCellRadius so pcall isn't handed a fresh closure each call.
  local function computeVisibleCellRadius()
    local ww, wh = love.graphics.getDimensions()
    local S = ZoomMod.windowFitScale()
    local s = ZoomMod.scale(S)
    local vw, vh = ZoomMod.fillViewSize(s, ww, wh)
    local halfW = floor((vw / 16) / 2)
    local halfH = floor((vh / 16) / 2)
    return max(1, min(halfW, halfH))
  end

  local function visibleCellRadius()
    if not (ZoomMod and love and love.graphics and love.graphics.getDimensions) then
      return FALLBACK_VIEW_RADIUS
    end
    local ok, radius = pcall(computeVisibleCellRadius)
    return (ok and type(radius) == "number") and radius or FALLBACK_VIEW_RADIUS
  end

  local function windowRadii()
    local viewRadius = visibleCellRadius()
    local placementRadius = viewRadius + VIEW_BUFFER
    local despawnRadius = placementRadius + DESPAWN_SLACK
    return viewRadius, placementRadius, despawnRadius
  end

  local function densityCap(placementRadius)
    local diameter = 2 * placementRadius + 1
    local cap = floor((diameter * diameter) / CELLS_PER)
    if cap < MIN_DENSITY_CAP then cap = MIN_DENSITY_CAP end
    if cap > MAX_DENSITY_CAP then cap = MAX_DENSITY_CAP end
    return cap
  end

  local function crossable(map, cx, cy, dir)
    if not map.stepPermitted then return true end
    return map:stepPermitted(cx, cy, dir)
  end

  local function liveMap()
    local world = (mod.game and mod.game.world)
      or (mod.world and mod.world.overworld and mod.world:overworld())
    return world and world.map
  end

  local function isFillerCell(map, cx, cy)
    if not (map and map.blockId) then return false end
    return map:blockId(floor(cx / 2), floor(cy / 2))
      == (map.borderBlock or 0)
  end

  -- Native CheckGrassCollision reads a wider collision set than
  -- isGrassCell exposes; COLL_GRASS_48..4C is real encounter terrain
  -- isGrassCell misses, only visible via map:cellTile's raw byte.
  local EXTRA_GRASS_COLL = {
    [0x48] = true, [0x49] = true, [0x4a] = true, [0x4b] = true, [0x4c] = true,
  }
  local function isEncounterGrassCell(map, cx, cy)
    if map.isGrassCell and map:isGrassCell(cx, cy) then return true end
    if map.cellTile then
      local coll = map:cellTile(cx, cy)
      if coll and EXTRA_GRASS_COLL[coll % 256] then return true end
    end
    return false
  end

  -- Ice forces a slide; a wanderer can't stand/spawn on it. isIce's
  -- collision ids aren't exposed as a map method, so inlined here.
  local ICE_COLL = { [0x23] = true, [0x2b] = true }
  local function isIceCell(map, cx, cy)
    if map.cellTile then
      local coll = map:cellTile(cx, cy)
      if coll and ICE_COLL[coll % 256] then return true end
    end
    return false
  end

  -- A tile next to ice is where a slide comes to rest, so a wanderer there
  -- would block it, same as standing on the ice itself. Memoized per cell
  -- for the map visit: this runs on every wanderer's every move attempt,
  -- and map:cellTile crosses the Lua/engine boundary.
  local iceHazardCache = {}
  local function isIceHazardCell(map, cx, cy)
    local k = cy * 1024 + cx
    local cached = iceHazardCache[k]
    if cached ~= nil then return cached end
    local hazard = isIceCell(map, cx, cy)
    if not hazard then
      for _, d in ipairs(NEIGH) do
        if isIceCell(map, cx + d[1], cy + d[2]) then hazard = true; break end
      end
    end
    iceHazardCache[k] = hazard
    return hazard
  end

  -- Keeps solid wild mons off the shore (would block a 1-tile crossing).
  local function isShoreCell(map, cx, cy, terrain)
    for _, d in ipairs(NEIGH) do
      local nx, ny = cx + d[1], cy + d[2]
      local nWater = map.isWaterCell and map:isWaterCell(nx, ny)
      if terrain == "water" then
        if not nWater and map.isWalkableCell and map:isWalkableCell(nx, ny) then
          return true
        end
      elseif nWater then
        return true
      end
    end
    return false
  end

  local function localRegion(map, pcx, pcy)
    local land, water = {}, {}
    if not (map and map.isWalkableCell and map.widthCells) then
      return land, water
    end
    local W, H = map.widthCells, map.heightCells
    local function kindAt(x, y)
      if x < 0 or y < 0 or x >= W or y >= H then return " " end
      if map:isWarpTileCell(x, y) then return "+" end
      if map:isWaterCell(x, y) then return "~" end
      if map:isWalkableCell(x, y) then
        return isFillerCell(map, x, y) and " " or "."
      end
      return " "
    end
    local function walk(x, y)
      local c = kindAt(x, y)
      return c == "." or c == "+"
    end
    -- Stacks hold packed y*1024+x integers to avoid GC churn from a fresh
    -- table per push/pop; only the result lists hold {x,y} tables.
    local stack, seen, shore = {}, {}, {}
    if walk(pcx, pcy) then
      stack[1] = pcy * 1024 + pcx; seen[pcy * 1024 + pcx] = true
    elseif kindAt(pcx, pcy) == "~" then
      seen[pcy * 1024 + pcx] = true
      shore[pcy * 1024 + pcx] = { pcx, pcy }
    end
    while #stack > 0 do
      local k = stack[#stack]; stack[#stack] = nil
      local cx, cy = k % 1024, floor(k / 1024)
      if kindAt(cx, cy) == "." and not isIceHazardCell(map, cx, cy) then
        land[#land + 1] = { cx, cy }
      end
      for _, d in ipairs(NEIGH) do
        local nx, ny = cx + d[1], cy + d[2]
        local nk = ny * 1024 + nx
        if not seen[nk] and crossable(map, cx, cy, d[3]) then
          if walk(nx, ny) then
            seen[nk] = true; stack[#stack + 1] = nk
          elseif kindAt(nx, ny) == "~" then
            shore[nk] = { nx, ny }
          end
        end
      end
    end
    local wstack, wseen = {}, {}
    for k in pairs(shore) do wstack[#wstack + 1] = k; wseen[k] = true end
    while #wstack > 0 do
      local k = wstack[#wstack]; wstack[#wstack] = nil
      local cx, cy = k % 1024, floor(k / 1024)
      water[#water + 1] = { cx, cy }
      for _, d in ipairs(NEIGH) do
        local nx, ny = cx + d[1], cy + d[2]
        local nk = ny * 1024 + nx
        if not wseen[nk] and kindAt(nx, ny) == "~"
            and crossable(map, cx, cy, d[3]) then
          wseen[nk] = true; wstack[#wstack + 1] = nk
        end
      end
    end
    return land, water
  end

  -- Groups a flat cell list into contiguous 4-neighbor patches, so every
  -- encounter patch gets equal footing instead of one pool weighted by
  -- raw candidate count.
  local function labelPatches(cells)
    local index = {}
    for i, c in ipairs(cells) do index[c[2] * 1024 + c[1]] = i end
    local visited, patches = {}, {}
    for i, c in ipairs(cells) do
      local key = c[2] * 1024 + c[1]
      if not visited[key] then
        visited[key] = true
        -- Packed-int stack; patch entries reuse cells[] references directly.
        local patch, stack = {}, { key }
        while #stack > 0 do
          local k = stack[#stack]; stack[#stack] = nil
          patch[#patch + 1] = cells[index[k]]
          local cx, cy = k % 1024, floor(k / 1024)
          for _, d in ipairs(NEIGH) do
            local nx, ny = cx + d[1], cy + d[2]
            local nk = ny * 1024 + nx
            local ni = index[nk]
            if ni and not visited[nk] then
              visited[nk] = true
              stack[#stack + 1] = nk
            end
          end
        end
        patches[#patches + 1] = patch
      end
    end
    return patches
  end

  -- A 4+ tile patch floors at 2, +1 per additional 4 tiles; 1-3 tile
  -- patches floor at 1 so none are starved outright.
  local function patchQuota(size)
    if size <= 0 then return 0 end
    if size < 4 then return 1 end
    return 2 + floor((size - 4) / 4)
  end

  -- Largest-remainder proportional trim: when total quota demand exceeds what
  -- the overall on-screen cap allows for this pass, shrink every patch's
  -- allocation in proportion to its own quota (a proxy for its size) rather
  -- than emptying small patches first.
  local function allocateProportional(allocs, totalQuota, need)
    if totalQuota <= 0 or need <= 0 then
      for _, a in ipairs(allocs) do a.alloc = 0 end
      return
    end
    if totalQuota <= need then
      for _, a in ipairs(allocs) do a.alloc = a.quota end
      return
    end
    local sumFloors = 0
    for _, a in ipairs(allocs) do
      local exact = a.quota * need / totalQuota
      a.alloc = floor(exact)
      a.remainder = exact - a.alloc
      sumFloors = sumFloors + a.alloc
    end
    local remaining = need - sumFloors
    table.sort(allocs, function(x, y) return x.remainder > y.remainder end)
    for i = 1, remaining do
      if allocs[i] then allocs[i].alloc = allocs[i].alloc + 1 end
    end
  end

  local function eligibleDist(mapId, terrain)
    local res = mod.world:effectiveEncounters(mapId, terrain)
    if type(res) ~= "table" or (res.chance or 0) <= 0 then return nil end
    if not next(res.dist or {}) then return nil end
    return res.dist
  end

  local function fishSlots(mapId)
    local game = mod.game
    local world = game and game.world
    local def = world and world.maps and world.maps[mapId]
    local group = def and def.fishGroup
    if not group or group == 0 or group == "FISHGROUP_NONE" then return nil, nil end
    local encounters = game and game.data and game.data.encounters
    local groups = encounters and encounters.fishGroups
    if not groups then return nil, nil end
    local save = game and game.save
    local inv = save and save.inventory
    if not inv then return nil, nil end

    local swarm
    if Roamers and Roamers.Swarm and Roamers.Swarm.fishing then
      local okS, s = pcall(Roamers.Swarm.fishing, save)
      swarm = okS and s or nil
    end
    local resolvedGroup = (Encounter and Encounter.fishGroupFor
      and Encounter.fishGroupFor(encounters, group, swarm)) or group
    local row = groups[resolvedGroup]
    if not row then return nil, nil end

    local todKey = "day"
    do
      local okC, Clock = pcall(require, "src.core.gen2.Clock")
      local okP, Palettes = pcall(require, "src.world.gen2.Palettes")
      if okC and okP and save then
        local okH, hour = pcall(Clock.hour, save)
        if okH then
          local okD, daytime = pcall(Palettes.clockDaytime, hour)
          if okD and (daytime == "NITE" or daytime == "DARK") then todKey = "nite" end
        end
      end
    end

    local TIER_ITEM = { old = "OLD_ROD", good = "GOOD_ROD", super = "SUPER_ROD" }
    local dist, levelSum, levelWt = {}, {}, {}
    for tier, itemId in pairs(TIER_ITEM) do
      local owned = inv[itemId]
      local list = (owned == true or (type(owned) == "number" and owned > 0))
        and row[tier]
      if list then
        local prev = 0
        for _, r in ipairs(list) do
          local cumulative = r.chance or 256
          local weight = cumulative - prev
          prev = cumulative
          if weight > 0 then
            local slot = r[todKey]
            if not slot and r.timeGroup and encounters.timeFishGroups then
              local tg = encounters.timeFishGroups[r.timeGroup]
              slot = tg and tg[todKey]
            end
            slot = slot or r
            local species = slot.species
            if species and species ~= 0 and species ~= "NO_ITEM" then
              dist[species] = (dist[species] or 0) + weight
              levelSum[species] = (levelSum[species] or 0) + weight * (slot.level or 5)
              levelWt[species] = (levelWt[species] or 0) + weight
            end
          end
        end
      end
    end
    if not next(dist) then return nil, nil end
    local levels = {}
    for species, wt in pairs(levelWt) do
      levels[species] = floor(levelSum[species] / wt + 0.5)
    end
    return dist, levels
  end

  local function pickSpecies(dist, r)
    local total = 0
    for _, wt in pairs(dist) do total = total + wt end
    if total <= 0 then return nil end
    local roll = r() * total
    for species, wt in pairs(dist) do
      roll = roll - wt
      if roll <= 0 then return species end
    end
    return next(dist)
  end

  local fishLevels

  local function levelFor(species, dataTerrain, mapId)
    if dataTerrain == "water" and fishLevels and fishLevels[species] then
      return fishLevels[species]
    end
    local data = mod.game and mod.game.data and mod.game.data.encounters
    local entry = data and data[dataTerrain] and data[dataTerrain][mapId]
    local slots = entry and entry.slots
    if type(slots) ~= "table" then return 5 end
    local sum, n, any = 0, 0, nil
    local function scan(list)
      for _, s in ipairs(list) do
        if type(s) == "table" and s.level then
          any = any or s.level
          if s.species == species then sum = sum + s.level; n = n + 1 end
        end
      end
    end
    if slots[1] then scan(slots) else
      for _, list in pairs(slots) do
        if type(list) == "table" then scan(list) end
      end
    end
    if n > 0 then return floor(sum / n + 0.5) end
    return any or 5
  end

  local live = {}
  local liveById = {} -- npcId -> entry, kept in sync with `live`
  local activeMapId
  local grassDist, waterDist
  local regionLand, regionWater, regionEligible, regionTotalQuota
  local regionGrassLand -- regionLand filtered through isEncounterGrassCell; cached alongside it, see needFlood below
  local regionFloodAtX, regionFloodAtY
  local stepTick = 0
  local topUpClock = 0
  local TOPUP_INTERVAL = 1
  local pending
  local pendingDvs
  local pendingTouchClock
  local lastBattleQueueClock
  local topUp -- forward declaration; assigned below, called from setIncenseMode
  local function clock()
    return (love and love.timer and love.timer.getTime()) or nil
  end

  local function slotInUse()
    local u = {}
    for _, w in ipairs(live) do if w.slot then u[w.slot] = true end end
    return u
  end
  local function freeSlot()
    local u = slotInUse()
    for s = 1, POOL do if not u[s] then return s end end
    return nil
  end

  local function sparkleSlotInUse()
    local u = {}
    for _, w in ipairs(live) do if w.sparkleSlot then u[w.sparkleSlot] = true end end
    return u
  end
  local function freeSparkleSlot()
    local u = sparkleSlotInUse()
    for s = 1, SPARKLE_POOL do if not u[s] then return s end end
    return nil
  end

  local function liveShinyCount()
    local n = 0
    for _, w in ipairs(live) do if w.shiny then n = n + 1 end end
    return n
  end

  -- `live` is an unordered pool (every caller either scans it fully or
  -- indexes it by npcId via liveById), so a swap-and-pop is a correct O(1)
  -- replacement for table.remove's O(n) downward shift. Safe with every
  -- call site here: they either iterate `live` backwards (the swapped-in
  -- tail element lands on an already-visited index) or remove a single
  -- entry found by a completed scan, never a live forward iteration.
  local function removeWanderer(i)
    local w = live[i]
    if not w then return end
    if w.npcId then
      mod.world:removeNpc(w.npcId)
      liveById[w.npcId] = nil
    end
    if w.sparkleNpcId then mod.world:removeNpc(w.sparkleNpcId) end
    local n = #live
    live[i] = live[n]
    live[n] = nil
  end

  local function despawnAll()
    for i = #live, 1, -1 do removeWanderer(i) end
  end

  -- w.npcRef is the real engine npc table, captured once at spawn time
  -- (see followerNpcRef above) rather than re-resolved via mod.world:npc.
  local function npcCell(w)
    local npc = w.npcRef
    if npc then return npc.cellX, npc.cellY, npc end
    return nil
  end

  local function playerCell()
    local cur = mod.world.current and mod.world:current()
    if type(cur) == "table" and cur.x and cur.y then return cur.mapId, cur.x, cur.y end
    local world = mod.game and mod.game.world
    local p = world and world.player
    if p then return world.map and world.map.id, p.cellX, p.cellY end
    return nil
  end

  local incenseMode = mod.save:get(INCENSE_KEY, "high")

  local function densityMultiplier()
    return INCENSE_DENSITY[incenseMode] or 1.0
  end

  -- OFF and REPEL both keep our wanderer pool empty; REPEL also leans on
  -- the engine's real repel gate so vanilla encounters stay blocked too.
  local function incenseSpawningOff()
    return incenseMode == "off" or incenseMode == "repel"
  end

  local function setIncenseMode(mode)
    if mode == incenseMode then return end
    local prev = incenseMode
    incenseMode = mode
    mod.save:set(INCENSE_KEY, mode)

    local save = mod.game and mod.game.save
    if mode == "repel" then
      if save then save.repelSteps = INCENSE_REPEL_STEPS end
    elseif prev == "repel" and save and save.repelSteps == INCENSE_REPEL_STEPS then
      -- Only clear it if it's still exactly our sentinel -- a genuine Repel
      -- the player used in the meantime is left alone.
      save.repelSteps = 0
    end

    despawnAll()
    if mode ~= "off" then
      -- low/medium/high refill the ordinary pool; repel re-syncs a roamer
      -- (if any) right away rather than waiting for the next topUp tick.
      local mapId, px, py = playerCell()
      if mapId and mapId == activeMapId then topUp(px, py) end
    end
    mod.log:info("overworldmons: incense mode -> %s", mode)
  end

  mod.content.screens:register(INCENSE_SCREEN, {
    new = function(game)
      local items = {}
      for _, m in ipairs(INCENSE_ORDER) do
        items[#items + 1] = {
          label = INCENSE_SHORT_LABEL[m] or m,
          right = (m == incenseMode) and "*" or nil,
          value = m,
        }
      end
      local menu = mod.ui.ListMenu.new(game, "INCENSE", items, {
        footer = INCENSE_DESC[incenseMode],
        onChoose = function(item, m)
          setIncenseMode(item.value)
          for _, it in ipairs(m.items) do
            it.right = (it.value == item.value) and "*" or nil
          end
          m.footer = INCENSE_DESC[item.value]
        end,
        onCancel = function() end,
      })
      -- ListMenu has no per-row highlight callback of its own; refreshing the
      -- footer off menu.index every frame is the smallest way to get the
      -- "hovering shows what it does" behaviour the SAVE-menu-style UX wants.
      local baseUpdate = menu.update
      function menu:update(dt)
        baseUpdate(self, dt)
        local hovered = self.items[self.index]
        if hovered then self.footer = INCENSE_DESC[hovered.value] or self.footer end
      end
      return menu
    end,
  })

  mod.hooks:wrap("ui.start_menu.items", function(next_, game, items)
    local out = next_(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "INCENSE",
      onSelect = function(g) mod.ui.push(g, INCENSE_SCREEN) end,
    })
  end)

  local function spawnOne(mapId, cell, terrain, dist, r)
    local slot = freeSlot()
    if not slot then return end
    local species = (Chain and Chain.forceSpecies(dist, r)) or pickSpecies(dist, r)
    if not species then return end
    local level = levelFor(species, terrain == "water" and "water" or "grass", mapId)
    local sid = spriteId(slot)
    local dex = dexOf(species)
    local dvs, shiny
    if Mon then
      if Chain then
        dvs, shiny = Chain.rollDVs(species, level, r, Mon)
      else
        dvs = Mon.randomDVs(); dvs.hp = Mon.hpDV(dvs)
        shiny = Mon.isShiny(dvs, { species = species, level = level })
      end
      -- Cap concurrent shinies: past the cap, re-roll plain DVs rather than
      -- keeping a shiny-pattern DV spread on a mon that isn't shiny.
      if shiny and liveShinyCount() >= MAX_LIVE_SHINIES then
        shiny = false
        dvs = Mon.randomDVs(); dvs.hp = Mon.hpDV(dvs)
      end
    end
    local form
    if dex == UNOWN_DEX and Unown then
      form = dvs and Unown.name(Unown.letterFromDVs(dvs))
        or Unown.name(floor(r() * Unown.NUM_UNOWN) + 1)
    end
    local def = defFor(dex, terrain, form, shiny)

    local world = mod.game and mod.game.world
    if world and world.sprites then world.sprites[sid] = def end

    local npcId = mod.world:spawnNpc(mapId, {
      sprite = sid, x = cell[1], y = cell[2],
      movement = terrain == "water" and SWIM_WANDER or WANDER,
      radius = RADIUS,
    })
    if type(npcId) ~= "string" then return end
    local index = tonumber(npcId:match("_obj_(%d+)$"))

    local h = index and mod.world:npc(mapId, index)
    if h and h.npc then
      h.npc.passable = false -- solid; native collision handles occupancy now
      if world and world.applySpritePalette then world:applySpritePalette(h.npc) end
    end

    local entry = {
      npcId = npcId, index = index, npcRef = h and h.npc, slot = slot,
      species = species, level = level, terrain = terrain, dvs = dvs,
      shiny = shiny,
    }
    if not shiny then
      entry.decayTime = DECAY_MIN_SECONDS
        + r() * (DECAY_MAX_SECONDS - DECAY_MIN_SECONDS)
    end
    live[#live + 1] = entry
    liveById[npcId] = entry
    if shiny then
      mod.log:info("overworldmons: SHINY wild %s spawned on %s", species, mapId)
      local sSlot = freeSparkleSlot()
      local sDef = sSlot and buildSparkleDef(mod)
      if sSlot and sDef then
        local sSid = sparkleSpriteId(sSlot)
        if world and world.sprites then world.sprites[sSid] = sDef end
        local sNpcId = mod.world:spawnNpc(mapId, {
          sprite = sSid, x = cell[1], y = cell[2],
          movement = 6, radius = { x = 0, y = 0 },
        })
        if type(sNpcId) == "string" then
          local sIndex = tonumber(sNpcId:match("_obj_(%d+)$"))
          local sh = sIndex and mod.world:npc(mapId, sIndex)
          if sh and sh.npc then
            sh.npc.passable = true -- visual overlay riding the host's cell, never solid
            if world and world.applySpritePalette then world:applySpritePalette(sh.npc) end
          end
          entry.sparkleNpcId, entry.sparkleIndex, entry.sparkleSlot =
            sNpcId, sIndex, sSlot
          entry.sparkleNpcRef = sh and sh.npc
          entry.sparkleClock, entry.sparkleFrame = 0, 0
          -- Installed once: bounceFrame reads entry.sparkleFrame via upvalue,
          -- so the sync loop below only writes a number, no new closure.
          if entry.sparkleNpcRef then
            entry.sparkleNpcRef.bounceFrame = function() return entry.sparkleFrame end
          end
        end
      end
    end
  end

  local function arm(mapId)
    despawnAll()
    ensureEncounterAlias()  -- data may not have been ready at entry-chunk time
    grassDist, waterDist, activeMapId = nil, nil, nil
    fishLevels = nil
    regionLand, regionWater, regionEligible, regionTotalQuota = nil, nil, nil, nil
    regionGrassLand = nil
    regionFloodAtX, regionFloodAtY = nil, nil
    iceHazardCache = {}
    if not mapId then return false end
    grassDist = eligibleDist(mapId, "grass")
    waterDist = eligibleDist(mapId, "water")
    local fDist, fLevels = fishSlots(mapId)
    if fDist then
      if waterDist then
        local merged = {}
        for species, wt in pairs(waterDist) do merged[species] = wt end
        for species, wt in pairs(fDist) do
          merged[species] = (merged[species] or 0) + wt
        end
        waterDist = merged
      else
        waterDist = fDist
      end
      fishLevels = fLevels
    end
    if not (grassDist or waterDist) then
      mod.log:info("overworldmons: %s has no grass/water encounter table", mapId)
      return false
    end
    activeMapId = mapId
    return true
  end

  local function tickDecay(dt)
    for i = #live, 1, -1 do
      local w = live[i]
      if w.decayTime then
        w.decayTime = w.decayTime - dt
        if w.decayTime <= 0 then removeWanderer(i) end
      end
    end
  end

  local function despawnFar(pcx, pcy)
    local _, _, despawnRadius = windowRadii()
    for i = #live, 1, -1 do
      local cx, cy = npcCell(live[i])
      if not cx or cheb(cx, cy, pcx, pcy) > despawnRadius then
        removeWanderer(i)
      end
    end
  end

  local function roamerEntryIndex(index)
    for i, w in ipairs(live) do
      if w.roamerIndex == index then return i end
    end
    return nil
  end

  local function removeRoamerEntry(index)
    local i = roamerEntryIndex(index)
    if i then removeWanderer(i) end
  end

  local function evictOrdinaryFarthest(pcx, pcy)
    local worstI, worstD = nil, -1
    for i, w in ipairs(live) do
      if not w.roamer then
        local cx, cy = npcCell(w)
        local d = cx and cheb(cx, cy, pcx, pcy) or math.huge
        if d > worstD then worstD, worstI = d, i end
      end
    end
    if not worstI then return false end
    removeWanderer(worstI)
    return true
  end

  local function spawnRoamer(index, slot, cell, terrain, pcx, pcy)
    local rslot = freeSlot()
    if not rslot then
      if not evictOrdinaryFarthest(pcx, pcy) then return end
      rslot = freeSlot()
    end
    if not rslot then return end
    local species, level = slot.species, slot.level or Roamers.LEVEL
    local sid = spriteId(rslot)
    local dex = dexOf(species)
    local shiny = (Mon and slot.dvs)
      and Mon.isShiny(slot.dvs, { species = species, level = level }) or false
    local def = defFor(dex, terrain, nil, shiny)
    local world = mod.game and mod.game.world
    if world and world.sprites then world.sprites[sid] = def end

    local npcId = mod.world:spawnNpc(activeMapId, {
      sprite = sid, x = cell[1], y = cell[2],
      movement = terrain == "water" and SWIM_WANDER or WANDER, radius = RADIUS,
    })
    if type(npcId) ~= "string" then return end
    local npcIndex = tonumber(npcId:match("_obj_(%d+)$"))
    local h = npcIndex and mod.world:npc(activeMapId, npcIndex)
    if h and h.npc then
      h.npc.passable = false
      if world and world.applySpritePalette then world:applySpritePalette(h.npc) end
    end

    local entry = {
      npcId = npcId, index = npcIndex, npcRef = h and h.npc, slot = rslot,
      species = species, level = level, terrain = terrain,
      dvs = slot.dvs, shiny = shiny,
      roamer = true, roamerIndex = index,
    }
    live[#live + 1] = entry
    liveById[npcId] = entry
    mod.log:info("overworldmons: roamer %s appeared on %s (%d,%d)%s",
      species, activeMapId, cell[1], cell[2], shiny and " SHINY" or "")
  end

  local function syncRoamers(map, pcx, pcy, land, water, taken, placementRadius)
    if not (Roamers and activeMapId) then return end
    local save = mod.game and mod.game.save
    if not save then return end
    local r = rng()
    local function habitatCandidates(list, terrain)
      local out = {}
      for _, c in ipairs(list) do
        local d = cheb(c[1], c[2], pcx, pcy)
        if d >= MIN_SPAWN_DIST and d <= placementRadius
            and not taken[c[2] * 1024 + c[1]]
            and not (map.warpAt and map:warpAt(c[1], c[2]))
            and not isShoreCell(map, c[1], c[2], terrain) then
          out[#out + 1] = { c, terrain }
        end
      end
      return out
    end
    for index = 1, 3 do
      local slot = Roamers.slot(save, index)
      local existing = roamerEntryIndex(index)
      if not Roamers.active(slot) or slot.map ~= activeMapId then
        if existing then removeRoamerEntry(index) end
      elseif not existing then
        local candidates = habitatCandidates(land, "land")
        for _, e in ipairs(habitatCandidates(water, "water")) do
          candidates[#candidates + 1] = e
        end
        if #candidates > 0 then
          local pick = candidates[floor(r() * #candidates) + 1]
          local c, terrain = pick[1], pick[2]
          spawnRoamer(index, slot, c, terrain, pcx, pcy)
          taken[c[2] * 1024 + c[1]] = true
        end
      end
    end
  end

  topUp = function(pcx, pcy)
    if incenseMode == "off" then return end
    if pending or not activeMapId or not (pcx and pcy) then return end
    local map = liveMap()
    if not (map and map.isWalkableCell and map.widthCells) then return end

    local viewRadius, placementRadius, despawnRadius = windowRadii()

    -- Self-healing re-flood: an empty-of-spawnable-land/water result only
    -- "sticks" for the exact cell it was computed from, so real player
    -- movement re-attempts it instead of staying stuck at zero forever.
    local needFlood = not regionLand
      or (regionEligible == false and not (regionFloodAtX == pcx and regionFloodAtY == pcy))
    if needFlood then
      regionLand, regionWater = localRegion(map, pcx, pcy)
      regionFloodAtX, regionFloodAtY = pcx, pcy

      -- Gate to isEncounterGrassCell, not isGrassCell alone (see that
      -- helper). Filtered once per flood, not once per topUp call, since
      -- the result only changes when regionLand does.
      regionGrassLand = regionLand
      if #regionLand > 0 and map.isGrassCell then
        local g = {}
        for _, c in ipairs(regionLand) do
          if isEncounterGrassCell(map, c[1], c[2]) then g[#g + 1] = c end
        end
        if #g > 0 then
          regionGrassLand = g
        else
          local env = map.def and map.def.environment
          if env == "ROUTE" or env == "TOWN" then regionGrassLand = {} end
        end
      end
    end
    local water = regionWater or {}
    local land = grassDist and (regionGrassLand or regionLand or {}) or {}
    if not waterDist then water = {} end

    local taken = {}
    for _, w in ipairs(live) do
      local cx, cy = npcCell(w)
      if cx then
        for dx = -MIN_WANDERER_SPACING, MIN_WANDERER_SPACING do
          for dy = -MIN_WANDERER_SPACING, MIN_WANDERER_SPACING do
            taken[(cy + dy) * 1024 + (cx + dx)] = true
          end
        end
      end
    end
    do
      local world = mod.game and mod.game.world
      for _, npc in ipairs(world and world.npcs or {}) do
        if not npc.passable and not liveById[npc.id] then
          taken[npc.cellY * 1024 + npc.cellX] = true
        end
      end
    end

    syncRoamers(map, pcx, pcy, land, water, taken, placementRadius)

    local eligible = #land + #water
    regionEligible = eligible > 0
    -- REPEL only skips the ordinary wanderer pool below (roamer sync above
    -- still runs); must come after regionEligible is set, or the
    -- self-healing re-flood above gets stuck since it never reads false.
    if incenseMode == "repel" then return end
    if eligible == 0 then return end

    -- totalQuota depends only on land/water, not player position, so it's
    -- cached until the next needFlood instead of a fresh BFS every tick.
    if needFlood then
      regionTotalQuota = 0
      for _, list in ipairs({ land, water }) do
        for _, p in ipairs(labelPatches(list)) do
          regionTotalQuota = regionTotalQuota + patchQuota(#p)
        end
      end
    end

    local target = floor(
      min(densityCap(placementRadius), regionTotalQuota or 0) * densityMultiplier())
    if target < 2 then target = 2 end
    local nearby = 0
    for _, w in ipairs(live) do
      local cx, cy = npcCell(w)
      if cx and cheb(cx, cy, pcx, pcy) <= despawnRadius then nearby = nearby + 1 end
    end
    -- Cheap ceiling check: skips the BFS/shore-check pass once at capacity.
    if min(target - nearby, POOL - #live) <= 0 then return end

    local function windowFilter(list)
      local out = {}
      for _, c in ipairs(list) do
        local d = cheb(c[1], c[2], pcx, pcy)
        if d >= MIN_SPAWN_DIST and d <= placementRadius
            and not taken[c[2] * 1024 + c[1]]
            and not (map.warpAt and map:warpAt(c[1], c[2])) then
          out[#out + 1] = c
        end
      end
      return out
    end

    -- Patches are labeled from the TRUE, whole-region habitat lists (`land`/
    -- `water`, already flooded for the whole reachable area by localRegion),
    -- NOT the window-filtered candidate lists above -- the player-centered
    -- MIN_SPAWN_DIST exclusion and each live wanderer's MIN_WANDERER_SPACING
    -- ring otherwise chop one real contiguous field into several small
    -- fragments, each capped at patchQuota's tiny per-fragment floor. Quota
    -- is computed from the real patch; `windowFilter` is then only used to
    -- find which of that patch's cells are actually placeable this pass.
    local allocs = {}
    local visibleQuota = 0
    local function addPatches(list, kind)
      for _, p in ipairs(labelPatches(list)) do
        local q = patchQuota(#p)
        local pickable = {}
        for _, c in ipairs(windowFilter(p)) do
          if not isShoreCell(map, c[1], c[2], kind) then
            pickable[#pickable + 1] = c
          end
        end
        if #pickable > 0 then
          allocs[#allocs + 1] = { cells = pickable, quota = q, kind = kind }
          visibleQuota = visibleQuota + q
        end
      end
    end
    addPatches(land, "land")
    addPatches(water, "water")

    local need = min(target - nearby, POOL - #live)
    if need <= 0 then return end

    local r = rng()
    local landCount, waterCount = 0, 0
    for _, a in ipairs(allocs) do
      if a.kind == "water" then waterCount = waterCount + #a.cells
      else landCount = landCount + #a.cells end
    end

    allocateProportional(allocs, visibleQuota, need)

    local function takeRandomFrom(list)
      if #list == 0 then return nil end
      local i = floor(r() * #list) + 1
      local c = list[i]; list[i] = list[#list]; list[#list] = nil
      return c
    end
    local function pruneNear(list, cx, cy)
      local out = {}
      for _, c in ipairs(list) do
        if cheb(c[1], c[2], cx, cy) >= MIN_WANDERER_SPACING then
          out[#out + 1] = c
        end
      end
      return out
    end
    for _, a in ipairs(allocs) do
      local pool = a.cells
      local picked = 0
      while picked < a.alloc and #pool > 0 do
        local c = takeRandomFrom(pool)
        if c then
          pool = pruneNear(pool, c[1], c[2])
          if a.kind == "water" then
            spawnOne(activeMapId, c, "water", waterDist, r)
          else
            spawnOne(activeMapId, c, "land", grassDist, r)
          end
          picked = picked + 1
        end
      end
    end
    mod.log:info(
      "overworldmons: %s topUp @%d,%d -> %d live (view=%d place=%d %d land / %d water cand, %d patches/%d quota)",
      activeMapId, pcx, pcy, #live, viewRadius, placementRadius, landCount, waterCount,
      #allocs, regionTotalQuota)
  end

  mod.events:on("map.entered", function(ev)
    pending = nil
    stepTick = 0
    topUpClock = 0
    local mapId, px, py = playerCell()
    mapId = (ev and ev.mapId) or mapId
    mod.log:info("overworldmons: map.entered %s (player %s,%s)",
      tostring(mapId), tostring(px), tostring(py))
    if arm(mapId) then topUp(px, py) end
  end)

  mod.events:on("map.exited", function()
    pending = nil
    pendingDvs = nil
    despawnAll()
    grassDist, waterDist, activeMapId = nil, nil, nil
    fishLevels = nil
    regionLand, regionWater, regionEligible, regionTotalQuota = nil, nil, nil, nil
    regionGrassLand = nil
    regionFloodAtX, regionFloodAtY = nil, nil
    iceHazardCache = {}
  end)

  mod.events:on("roamer.moved", function(ev)
    if not (ev and (ev.to == activeMapId or ev.from == activeMapId)) then return end
    local _, px, py = playerCell()
    if px and py then topUp(px, py) end
  end)

  mod.events:on("roamer.encountered", function(ev)
    if ev and ev.index then removeRoamerEntry(ev.index) end
  end)

  -- Called from movement.collision's player branch on a bump, not touch.
  local function beginEncounter(i, w)
    removeWanderer(i)
    local realWorld = mod.game and mod.game.world
    if realWorld then realWorld.heldDir = nil end
    pendingTouchClock = clock()
    if w.roamer then
      pending = { roamer = true, index = w.roamerIndex,
        species = w.species, level = w.level }
    else
      pending = { species = w.species, level = w.level, dvs = w.dvs }
    end
    mod.log:info("overworldmons: bumped %s%s (Lv %d)", w.species,
      w.roamer and " [roamer]" or "", w.level)
  end

  mod.events:on("world.stepped", function(ev)
    if ev.mapId ~= activeMapId then return end

    stepTick = stepTick + 1
    if stepTick % STEP_THROTTLE == 0 then
      despawnFar(ev.x, ev.y)
      topUp(ev.x, ev.y)
    end
  end)

  local function tickWildStep(game, dt)
    if activeMapId then
      tickDecay(dt or 0)

      topUpClock = topUpClock + (dt or 0)
      if topUpClock >= TOPUP_INTERVAL then
        topUpClock = topUpClock % TOPUP_INTERVAL
        local mapId, px, py = playerCell()
        if mapId == activeMapId and px and py then
          despawnFar(px, py)
          topUp(px, py)
        end
      end
    end

    if activeMapId then
      -- Cached refs (see npcCell) instead of two mod.world:npc() lookups
      -- per live shiny, every frame.
      for _, w in ipairs(live) do
        if w.sparkleIndex then
          local npc, snpc = w.npcRef, w.sparkleNpcRef
          if npc and snpc then
            snpc.cellX, snpc.cellY = npc.cellX, npc.cellY
            -- +1 py (imperceptible) breaks the non-stable table.sort tie
            -- between host and sparkle at the same py in World:drawPeople.
            local hostPy = npc.py
            snpc.px, snpc.py = npc.px, hostPy and hostPy + 1 or hostPy
            w.sparkleClock = (w.sparkleClock or 0) + (dt or 0)
            local period = SPARKLE_FRAME_SECONDS * SPARKLE_FRAMES
            w.sparkleClock = w.sparkleClock % period
            w.sparkleFrame = floor(w.sparkleClock / SPARKLE_FRAME_SECONDS) % SPARKLE_FRAMES
          end
        end
      end
    end

    if not pending then return end
    local world = game and game.world
    if not world or (world.busy and world:busy()) or world.moveState then return end
    local battle = pending
    pending = nil
    do
      local now, then_ = clock(), pendingTouchClock
      if now and then_ then
        mod.log:info(
          "overworldmons: touch->battle-start-call %.1fms", (now - then_) * 1000)
      end
      lastBattleQueueClock = now
    end
    pendingTouchClock = nil

    if battle.roamer then
      local save = mod.game and mod.game.save
      local data = mod.game and mod.game.data
      local beast = (Roamers and save)
        and Roamers.beginBattle(save, battle.index, data)
      if beast then
        save.pokedex = save.pokedex or { seen = {}, caught = {} }
        save.pokedex.seen[beast.species] = true
        world:startBattle({ wild = beast, roaming = battle.index })
      else
        mod.log:warn(
          "overworldmons: roamer slot %d no longer active at touch-resolve (species %s)",
          tostring(battle.index), tostring(battle.species))
      end
      return
    end

    pendingDvs = battle.dvs
    mod.world:queueScript({
      { "start_battle", "wild", battle.species, battle.level },
    })
  end

  mod.events:on("battle.started", function(ev)
    if ev and ev.kind == "wild" then
      local now, then_ = clock(), lastBattleQueueClock
      lastBattleQueueClock = nil
      if now and then_ then
        mod.log:info(
          "overworldmons: queueScript->battle.started %.1fms", (now - then_) * 1000)
      end
    end
    if ev and ev.kind == "wild" and ev.battle and ev.battle.roaming then return end
    local dvs = pendingDvs
    pendingDvs = nil
    if not (dvs and ev and ev.kind == "wild" and Mon) then return end
    local b = ev.battle
    local enemy = b and b.enemy
    local enemyMon = enemy and (enemy.mon or enemy)
    if not enemyMon then return end
    local data = (b and b.data) or (mod.game and mod.game.data)
    enemyMon.dvs = dvs
    Mon.refreshStats(enemyMon, data)
    enemyMon.hp = enemyMon.stats and enemyMon.stats.hp or enemyMon.hp
    if enemy ~= enemyMon then
      enemy.curStats = enemyMon.stats
      enemy.shownHP = enemyMon.hp
    end
    mod.log:info(
      "overworldmons: wild %s dvs atk=%d def=%d spd=%d spc=%d hp=%d%s",
      tostring(ev.species), dvs.attack, dvs.defense, dvs.speed, dvs.special,
      dvs.hp, enemyMon.shiny and " SHINY" or "")
  end)

  -- Enemy HUD's row-1 gap left of "<LV>" (tile 1,1 / pixel 8,8), blank in
  -- vanilla. Gen2 BattleState has no .enemy field like Gen1's; use activeMon.
  mod.hooks:wrap("battle.overlay", function(next_, battleState)
    next_(battleState)
    if not (battleState and battleState.activeMon) then return end
    -- Same visibility gate drawEnemyHud itself uses.
    local visible = (not battleState.statusHUDVisible
        or battleState:statusHUDVisible())
      and battleState.showEnemyHud
      and not (battleState.hudCleared and battleState:hudCleared("enemy"))
    if not visible then return end
    local enemyMon = battleState:activeMon("enemy")
    if enemyMon and enemyMon.shiny and mod.ui and mod.ui.Font then
      mod.ui.Font.draw(SHINY_GLYPH_SEQ, 8, 8)
    end
  end)

  mod.hooks:wrap("encounter.roll", function(next_, tables, ctx)
    if ctx and ctx.mapId == activeMapId and not incenseSpawningOff() then return nil end
    return next_(tables, ctx)
  end)

  -- Wild mons are solid now: this hook only enforces wander/habitat rules.
  mod.hooks:wrap("movement.collision", function(next_, allowed, ctx)
    if not (activeMapId and ctx.map) then return next_(allowed, ctx) end
    local mover = ctx.mover
    local world = mod.game and mod.game.world
    local player = world and world.player

    if mover and mover == player then
      if not pending and allowed == false and ctx.reason == "entity" then
        local tx, ty = ctx.toX, ctx.toY
        for i, w in ipairs(live) do
          local cx, cy = npcCell(w)
          if cx == tx and cy == ty then
            beginEncounter(i, w)
            break
          end
        end
      end
      return next_(allowed, ctx)
    end

    local id = mover and mover.id
    local self_ = id and liveById[id]
    if not self_ then return next_(allowed, ctx) end
    -- Native refuses water tiles as "tile" (not land-walkable) -- that's the
    -- one veto a water wanderer needs lifted, so it's not respected here.
    -- Every other refusal (entity/radius/warp/bounds) still is.
    if not allowed and ctx.reason ~= "tile" then return next_(allowed, ctx) end

    local map = ctx.map
    local tx, ty = ctx.toX, ctx.toY
    local onWater = map.isWaterCell and map:isWaterCell(tx, ty) or false

    if self_.terrain == "water" then
      if not onWater then return next_(false, ctx) end
    else
      if onWater then return next_(false, ctx) end
      if isFillerCell(map, tx, ty) then return next_(false, ctx) end
      if isIceHazardCell(map, tx, ty) then return next_(false, ctx) end
      if map.isGrassCell and isEncounterGrassCell(map, mover.cellX, mover.cellY)
          and not isEncounterGrassCell(map, tx, ty) then
        return next_(false, ctx)
      end
    end

    if ctx.dir and not crossable(map, ctx.fromX, ctx.fromY, ctx.dir) then
      return next_(false, ctx)
    end

    if self_.terrain == "water" then return next_(true, ctx) end
    return next_(allowed, ctx)
  end)

  mod.log:info("overworldmons: wild wanderers armed (pool %d, view radius %d, 1/%d cells)",
    POOL, visibleCellRadius(), CELLS_PER)
  return tickWildStep
end

return function(mod)
  mod.log:info("overworldmons: entry chunk running (mod.world=%s mod.game=%s)",
    tostring(mod.world ~= nil), tostring(mod.game ~= nil))

  local okU, mod_ = pcall(require, "src.core.gen2.Unown")
  if okU and type(mod_) == "table" and mod_.monLetter then
    Unown = mod_
  else
    Unown = nil
    mod.log:info("overworldmons: no src.core.gen2.Unown seam; Unown -> letter A")
  end

  local okM, mod_m = pcall(require, "src.battle.gen2.Mon")
  if okM and type(mod_m) == "table" and mod_m.randomDVs and mod_m.refreshStats then
    Mon = mod_m
  else
    Mon = nil
    mod.log:info("overworldmons: no src.battle.gen2.Mon seam; wild DVs stay engine-default")
  end

  local okR, mod_r = pcall(require, "src.core.gen2.Roamers")
  if okR and type(mod_r) == "table" and mod_r.slot and mod_r.beginBattle then
    Roamers = mod_r
  else
    Roamers = nil
    mod.log:info("overworldmons: no src.core.gen2.Roamers seam; roamers stay invisible RNG")
  end

  local okZ, mod_z = pcall(require, "src.render.Zoom")
  if okZ and type(mod_z) == "table" and mod_z.scale and mod_z.fillViewSize then
    ZoomMod = mod_z
  else
    ZoomMod = nil
    mod.log:info("overworldmons: no src.render.Zoom seam; placement window "
      .. "falls back to a fixed 160x144 screen guess")
  end

  local okE, mod_e = pcall(require, "src.battle.gen2.Encounter")
  if okE and type(mod_e) == "table" and mod_e.fishGroupFor then
    Encounter = mod_e
  else
    Encounter = nil
    mod.log:info("overworldmons: no src.battle.gen2.Encounter seam; fish "
      .. "wanderers skip swarm substitution")
  end

  local okS, mod_s = pcall(require, "src.script.gen2.Specials")
  if okS and type(mod_s) == "table" and mod_s.ALL then
    Specials = mod_s
  else
    Specials = nil
    mod.log:info("overworldmons: no src.script.gen2.Specials seam; follower "
      .. "stays visible through Pokecenter heals")
  end

  local Chain = setupChain(mod)

  -- Each setupX returns a tick function (nil if it can't arm), sequenced
  -- from one "input.step" registration below instead of N separate hooks.
  local tickFollower = setupFollower(mod)
  setupPokecenterFollowerHide(mod, Specials)
  local tickFollowerEmotes = setupFollowerEmotes(mod)
  setupFollowerForaging(mod)
  local tickFollowerText = setupFollowerInteraction(mod)
  local tickWild = setupWild(mod, Chain, Roamers)
  local tickOverworldReskin = setupOverworldReskin(mod)
  local tickObjectOverrides = setupObjectOverrides(mod)
  setupReskinNpcFixups(mod)
  setupReskinFacePlayer(mod)
  local tickDaycare = setupDaycareReskin(mod)

  mod.hooks:wrap("input.step", function(next_, game, dt)
    -- Order preserves the original per-hook execution order (verified
    -- against LuaJIT's non-stable table.sort of equal-priority hooks).
    -- safeTick keeps each tick's own pcall boundary so one throwing hook
    -- doesn't skip every hook listed after it.
    local function safeTick(name, fn)
      if not fn then return end
      local ok, err = pcall(fn, game, dt)
      if not ok then
        mod.log:warn("overworldmons: %s threw: %s", name, tostring(err))
      end
    end

    safeTick("tickObjectOverrides", tickObjectOverrides)
    safeTick("tickOverworldReskin", tickOverworldReskin)

    next_(game, dt)

    safeTick("tickWild", tickWild)
    safeTick("tickFollowerText", tickFollowerText)
    safeTick("tickFollowerEmotes", tickFollowerEmotes)
    safeTick("tickDaycare", tickDaycare)
    safeTick("tickFollower", tickFollower)
  end)
end
