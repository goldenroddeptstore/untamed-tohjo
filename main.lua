
local MAX_DEX = 251
local FALLBACK_DEX = 25
local UNOWN_DEX = 201

local Unown

local Mon

local Roamers

local ZoomMod

local Encounter

local FollowerMod

local function unownLetter(mon)
  if not (Unown and mon) then return nil end
  local idx = Unown.monLetter(mon)
  return idx and Unown.name(idx) or nil
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
local RUNTIME = { pals = nil, warned = {} }

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

local function loadPalettes(mod)
  if RUNTIME.pals ~= nil then return RUNTIME.pals or nil end
  local pals = false
  local okRead, raw = pcall(function() return mod:read("assets/mon/palettes.json") end)
  if okRead and raw then
    local okDecode, decoded = pcall(decodeFlatJson, raw)
    if okDecode and type(decoded) == "table" then pals = decoded end
  end
  RUNTIME.pals = pals
  return pals or nil
end

local function loadAtlas(mod)
  if RUNTIME.atlas ~= nil then return RUNTIME.atlas or nil, RUNTIME.atlasIndex end
  local atlas, index = false, nil
  local okIdx, raw = pcall(function() return mod:read("assets/mon/gray_atlas_index.json") end)
  if okIdx and raw then
    local okDecode, decoded = pcall(decodeFlatJson, raw)
    if okDecode and type(decoded) == "table" then index = decoded end
  end
  if index then
    local okImg, data = pcall(love.image.newImageData, mod.assets:path("assets/mon/gray_atlas.png"))
    if okImg then atlas = data end
  end
  RUNTIME.atlas, RUNTIME.atlasIndex = atlas, index
  return atlas or nil, index
end

local function nearestShade(v255)
  local best, bestDelta = RUNTIME_SHADES[1], math.huge
  for _, s in ipairs(RUNTIME_SHADES) do
    local d = math.abs(s - v255)
    if d < bestDelta then bestDelta, best = d, s end
  end
  return best
end

local function ribbonFoam(x, row)
  if row == 0 then return (x % 8) < 4 else return (x % 8) >= 4 end
end

local function buildRuntimeSheet(atlasData, atlasY0, lut, submerge)
  local w, h = CARD, CARD * FRAME_COUNT
  local out = love.image.newImageData(w, h)
  for frame = 0, FRAME_COUNT - 1 do
    local y0 = frame * CARD
    for y = y0, y0 + CARD - 1 do
      for x = 0, CARD - 1 do
        local r, _, _, a = atlasData:getPixel(x, atlasY0 + y)
        if a > 0 then
          local shade = nearestShade(math.floor(r * 255 + 0.5))
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

local function spriteDefFor(mod, idPrefix, dex, terrain, form, shiny)
  if not (love and love.image) then return nil end
  local pals = loadPalettes(mod)
  local entry = pals and pals[tostring(dex)]
  if not entry then return nil end
  local colors = (shiny and entry.shiny) or entry.normal

  local key = dex .. "_" .. terrain .. (form and ("_" .. form) or "")
    .. (shiny and "_S" or "")
  local ok, result = pcall(function()
    local atlasData, index = loadAtlas(mod)
    if not (atlasData and index) then error("gray_atlas.png / index unavailable") end
    local atlasKey = (dex == UNOWN_DEX and form) and (dex .. "_" .. form) or tostring(dex)
    local frameRow = index[atlasKey]
    if not frameRow then error("no atlas entry for " .. atlasKey) end
    local atlasY0 = frameRow * CARD
    local lut = {}
    for i, s in ipairs(entry.shades) do
      local r, g, b = hexToUnit(colors[i])
      lut[s] = { r, g, b }
    end
    return buildRuntimeSheet(atlasData, atlasY0, lut, terrain == "water")
  end)
  if not ok then
    if not RUNTIME.warned[key] then
      RUNTIME.warned[key] = true
      mod.log:error("overworldmons: sprite build failed for "
        .. key .. " (no sprite for this combo): " .. tostring(result))
    end
    return nil
  end

  return {
    id = idPrefix .. (terrain == "water" and "W_" or "") .. key,
    image = result,
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

local FOLLOWER_SPRITE = "SPRITE_PIKACHU"

local POOL = 24
local RADIUS = { x = 4, y = 4 }
local WANDER, SWIM_WANDER = 2, 0x24

local SPARKLE_FRAME_W, SPARKLE_FRAME_H, SPARKLE_FRAMES = 16, 24, 21
local SPARKLE_FRAME_SECONDS = 0.12
local SPARKLE_POOL = 8

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
          local shade = nearestShade(math.floor(r * 255 + 0.5))
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

local DECAY_MIN_SECONDS = 20
local DECAY_MAX_SECONDS = 35

local function setupFollower(mod)
  local ok, Follower = pcall(require, "src.world.PikachuFollower")
  if not ok or type(Follower) ~= "table" or not Follower.setShouldSpawn then
    mod.log:warn("overworldmons: no gen2 Follower.setShouldSpawn seam; follower off")
    return
  end
  FollowerMod = Follower

  local defs = { land = {}, water = {} }
  local function defFor(dex, terrain, form, shiny)
    local cache = defs[terrain]
    local key = (form and (dex .. form) or dex) .. (shiny and "S" or "")
    if not cache[key] then
      cache[key] = spriteDefFor(mod, "OWM_FOLLOWER_", dex, terrain, form, shiny)
    end
    return cache[key]
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

  local function canSwim(mon, rec)
    for _, t in ipairs(rec and rec.types or {}) do
      if t == "WATER" then return true end
    end
    for _, m in ipairs(rec and rec.tmhm or {}) do
      if m == "SURF" then return true end
    end
    for _, m in ipairs(mon and mon.moves or {}) do
      if (type(m) == "table" and m.id or m) == "SURF" then return true end
    end
    return false
  end

  local lastKey

  Follower.setShouldSpawn(function(game, world)
    local mon, rec = leadMon(mod, game, world)
    local dex = mon and (dexOfRec(rec) or FALLBACK_DEX) or nil
    if not dex then
      lastKey = nil
      return false
    end

    local npc = Follower.current and Follower.current(world)
    local onWater = followerTerrain(world, npc) == "water"
    local swims = onWater and canSwim(mon, rec)

    if npc then
      npc.hiddenByMovement = (onWater and not swims) or nil
    end

    local form = dex == UNOWN_DEX and unownLetter(mon) or nil
    local terrain = swims and "water" or "land"
    local shiny = Mon and mon.dvs
      and Mon.isShiny(mon.dvs, { species = mon.species, level = mon.level })
    local key = dex .. ":" .. terrain .. ":" .. (form or "") .. (shiny and ":S" or "")

    if key ~= lastKey then
      local def = defFor(dex, terrain, form, shiny)
      if world and world.sprites then
        world.sprites[FOLLOWER_SPRITE] = def
      end
      if npc and npc.setSpriteDef and npc:setSpriteDef(def) then
        if world.applySpritePalette then world:applySpritePalette(npc) end
      end
      lastKey = key
      mod.log:info("overworldmons: follower sheet -> dex %d (%s%s)%s", dex, terrain,
        form and (" " .. form) or "", shiny and " SHINY" or "")
    end

    return true
  end)

  mod.log:info("overworldmons: follower armed")
end

local EMOTE_SPRITE = "OWM_FOLLOWER_EMOTE"
local EMOTE_FRAME_W, EMOTE_FRAME_H, EMOTE_FRAMES = 16, 16, 14
local EMOTE_DEFAULT_HOLD = 1.5

local EMOTE = {
  SMILE = 0, EXCLAIM = 1, QUESTION = 2, BLOCK = 3, LIGHTNING = 4, FISH = 5,
  HEART = 6, ELLIPSIS = 7, MUSIC = 8, NEUTRAL = 9, SAD = 10, ANGRY = 11,
  CROWN = 12, ZZZ = 13,
}

local emoteState = {
  npcId = nil, index = nil, mapId = nil, frame = nil,
  clock = 0, hold = 0, persistent = false,
}

local function buildEmoteDef(mod)
  if RUNTIME.emoteDef ~= nil then return RUNTIME.emoteDef or nil end
  local def = {
    id = EMOTE_SPRITE, image = mod.path .. "/assets/vfx/emotes.png",
    frames = EMOTE_FRAMES, frameWidth = EMOTE_FRAME_W, frameHeight = EMOTE_FRAME_H,
    walker = false, spriteType = "STANDING_SPRITE", trueColor = true,
  }
  RUNTIME.emoteDef = def
  return def
end

local function hideFollowerEmote(mod)
  if emoteState.npcId and mod.world and mod.world.removeNpc then
    mod.world:removeNpc(emoteState.npcId)
  end
  emoteState.npcId, emoteState.index, emoteState.mapId, emoteState.frame = nil, nil, nil, nil
  emoteState.clock, emoteState.hold, emoteState.persistent = 0, 0, false
end

local function showFollowerEmote(mod, world, followerNpc, frameIndex, opts)
  if not (world and world.map and followerNpc) then return end
  opts = opts or {}
  hideFollowerEmote(mod)
  local def = buildEmoteDef(mod)
  if not def then return end
  local mapId = world.map.id
  if world.sprites then world.sprites[EMOTE_SPRITE] = def end
  local npcId = mod.world:spawnNpc(mapId, {
    sprite = EMOTE_SPRITE, x = followerNpc.cellX, y = followerNpc.cellY,
    movement = 6, radius = { x = 0, y = 0 },
  })
  if type(npcId) ~= "string" then return end
  local index = tonumber(npcId:match("_obj_(%d+)$"))
  local h = index and mod.world:npc(mapId, index)
  if not (h and h.npc) then
    mod.world:removeNpc(npcId)
    return
  end
  h.npc.passable = true
  h.npc.px, h.npc.py = followerNpc.px, followerNpc.py - EMOTE_FRAME_H
  h.npc.bounceFrame = function() return frameIndex end
  if world.applySpritePalette then world:applySpritePalette(h.npc) end
  emoteState.npcId, emoteState.index, emoteState.mapId, emoteState.frame =
    npcId, index, mapId, frameIndex
  emoteState.hold = opts.holdSeconds or EMOTE_DEFAULT_HOLD
  emoteState.clock = 0
  emoteState.persistent = opts.persistent and true or false
end

local function setupFollowerEmotes(mod)
  mod.hooks:wrap("input.step", function(next_, game, dt)
    next_(game, dt)
    if not emoteState.npcId then return end
    local world = mod.game and mod.game.world
    local npc = FollowerMod and world and FollowerMod.current(world)
    local h = emoteState.index and mod.world:npc(emoteState.mapId, emoteState.index)
    if not (npc and h and h.npc) then
      hideFollowerEmote(mod)
      return
    end
    h.npc.px, h.npc.py = npc.px, npc.py - EMOTE_FRAME_H
    h.npc.bounceFrame = function() return emoteState.frame end
    if emoteState.persistent then return end
    emoteState.clock = emoteState.clock + (dt or 0)
    if emoteState.clock >= emoteState.hold then hideFollowerEmote(mod) end
  end)
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
  return ((love and love.math and love.math.random) or math.random)()
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
    itemName = weightedPick(FORAGE_POOLS[math.min(forageTier(mon), 3)])
  end

  forageState.ready, forageState.rare, forageState.itemName = true, rare, itemName
  local npc = FollowerMod and FollowerMod.current(world)
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
    if not (FollowerMod and ev) then return end
    local world = mod.game and mod.game.world
    if not world then return end
    local npc = FollowerMod.current(world)
    if not (npc and npc.cellX == ev.x and npc.cellY == ev.y) then return end
    mod.log:info(
      "overworldmons: world.interacted at follower cell (%s,%s) kind=%s",
      tostring(ev.x), tostring(ev.y), tostring(ev.kind))
    local mon, rec = leadMon(mod, mod.game, world)
    if not mon then return end
    runFollowerInteraction(mod, world, npc, mon, rec)
  end)

  mod.hooks:wrap("input.step", function(next_, game, dt)
    next_(game, dt)
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
  end)

  mod.log:info(
    "overworldmons: follower interaction armed (Phase A+B+C: health/status, "
    .. "foraging, environment, friendship fallback)")
end

local MAX_CHAIN = 50
local CHAIN_SPECIES_KEY, CHAIN_COUNT_KEY = "chainSpecies", "chainCount"

local CHAIN_SHINY_BASE_DENOM, CHAIN_SHINY_STEP, CHAIN_SHINY_FLOOR_DENOM = 8192, 164, 15
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
      count = math.min(MAX_CHAIN, count + 1)
    else
      species, count = resolvedSpecies, 1
    end
    persist()
  end

  local function forceSpecies(dist, r)
    if not (species and count > 1 and dist and dist[species]) then return nil end
    local odds = 10 - math.min(count, 9)
    if math.floor(r() * odds) == 0 then return species end
    return nil
  end

  local function rollDVs(forSpecies, level, r, Mon)
    local dvs
    if forSpecies == species and count > 0 then
      local denom = math.max(CHAIN_SHINY_FLOOR_DENOM,
        CHAIN_SHINY_BASE_DENOM - CHAIN_SHINY_STEP * count)
      if math.floor(r() * denom) == 0 then
        dvs = {
          defense = 10, speed = 10, special = 10,
          attack = CHAIN_SHINY_ATTACK_DVS[
            math.floor(r() * #CHAIN_SHINY_ATTACK_DVS) + 1],
        }
      else
        dvs = Mon.randomDVs()
        local k = chainFloorK(count)
        if k > 0 then
          local stats = { "attack", "defense", "speed", "special" }
          for i = #stats, 2, -1 do
            local j = math.floor(r() * i) + 1
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
  mod.hooks:wrap("input.step", function(next_, game, dt)
    if not done then
      local world = game and game.world
      if world and world.sprites then
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
    end
    return next_(game, dt)
  end)
end

-- Per-object reskins (shared vanilla sprite records rule out a per-sprite patch);
-- uses NPC:setSpriteDef, the ROM's own repaint-in-place seam (see Npc.lua).
local OBJECT_OVERRIDES = {
  { mapId = "OLIVINE_LIGHTHOUSE_6F", index = 2, species = "AMPHAROS",
    label = "Olivine Lighthouse Ampharos" },
  { mapId = "MAHOGANY_MART_1F", index = 4, species = "DRAGONITE",
    label = "Mahogany Mart Dragonite" },
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

  mod.events:on("map.entered", function(ev)
    local mapId = ev and ev.mapId
    if not mapId then return end
    for _, o in ipairs(OBJECT_OVERRIDES) do
      if o.mapId == mapId then
        local applyOk, applyErr = pcall(function()
          if not o.def then
            local rec = mod.content.pokemon:get(o.species)
            local dex = rec and rec.dex
            if type(dex) ~= "number" or dex < 1 or dex > MAX_DEX then
              error("no dex for " .. tostring(o.species))
            end
            o.def = spriteDefFor(mod, "OWM_OWMON_", dex, "land", nil, o.shiny)
            if not o.def then error("spriteDefFor returned nil") end
          end
          local h = mod.world:npc(o.mapId, o.index)
          if not (h and h.npc and h.npc.setSpriteDef) then
            error("no live npc at " .. o.mapId .. " index " .. o.index)
          end
          h.npc:setSpriteDef(o.def)
          local world = mod.game and mod.game.world
          if world and world.applySpritePalette then world:applySpritePalette(h.npc) end
        end)
        if applyOk then
          mod.log:info("overworldmons: %s reskinned", o.label)
        else
          mod.log:warn("overworldmons: %s override failed: %s", o.label, tostring(applyErr))
        end
      end
    end
  end)
end

local RESKIN_ID_PREFIX = "OWM_OWMON_"

local function setupReskinBounceFix(mod)
  local function scrub(world)
    if not (world and world.npcs) then return end
    for _, npc in ipairs(world.npcs) do
      if npc.bouncing and npc.spriteDef and type(npc.spriteDef.id) == "string"
          and npc.spriteDef.id:find(RESKIN_ID_PREFIX, 1, true) == 1 then
        npc.bouncing = false
      end
    end
  end
  mod.events:on("map.entered", function()
    scrub(mod.game and mod.game.world)
  end)
end

local function setupWild(mod, Chain, Roamers)
  if not (mod.world and mod.world.effectiveEncounters and mod.world.spawnNpc) then
    mod.log:warn("overworldmons: no gen2 mod.world spawn surface; wild off")
    return
  end

  local function ensureEncounterAlias()
    local gdata = mod.game and mod.game.data
    if gdata and gdata.encounters == nil and gdata.gen2Encounters ~= nil then
      gdata.encounters = gdata.gen2Encounters
      mod.log:info("overworldmons: aliased data.encounters <- data.gen2Encounters")
    end
  end
  ensureEncounterAlias()

  local defCache = { land = {}, water = {} }
  local function defFor(dex, terrain, form, shiny)
    local cache = defCache[terrain]
    local key = (form and (dex .. form) or dex) .. (shiny and "S" or "")
    if not cache[key] then
      cache[key] = spriteDefFor(mod, "OWM_WILD_SHEET_", dex, terrain, form, shiny)
    end
    return cache[key]
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
    return (love and love.math and love.math.random) or math.random
  end

  local NEIGH = {
    { 1, 0, "right" }, { -1, 0, "left" }, { 0, 1, "down" }, { 0, -1, "up" },
  }
  local function cheb(ax, ay, bx, by)
    local dx, dy = math.abs(ax - bx), math.abs(ay - by)
    return dx > dy and dx or dy
  end

  local function visibleCellRadius()
    if not (ZoomMod and love and love.graphics and love.graphics.getDimensions) then
      return FALLBACK_VIEW_RADIUS
    end
    local ok, radius = pcall(function()
      local ww, wh = love.graphics.getDimensions()
      local S = ZoomMod.windowFitScale()
      local s = ZoomMod.scale(S)
      local vw, vh = ZoomMod.fillViewSize(s, ww, wh)
      local halfW = math.floor((vw / 16) / 2)
      local halfH = math.floor((vh / 16) / 2)
      return math.max(1, math.min(halfW, halfH))
    end)
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
    local cap = math.floor((diameter * diameter) / CELLS_PER)
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
    return map:blockId(math.floor(cx / 2), math.floor(cy / 2))
      == (map.borderBlock or 0)
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
    local stack, seen, shore = {}, {}, {}
    if walk(pcx, pcy) then
      stack[1] = { pcx, pcy }; seen[pcy * 1024 + pcx] = true
    elseif kindAt(pcx, pcy) == "~" then
      seen[pcy * 1024 + pcx] = true
      shore[pcy * 1024 + pcx] = { pcx, pcy }
    end
    while #stack > 0 do
      local cell = stack[#stack]; stack[#stack] = nil
      if kindAt(cell[1], cell[2]) == "." then land[#land + 1] = cell end
      for _, d in ipairs(NEIGH) do
        local nx, ny = cell[1] + d[1], cell[2] + d[2]
        local nk = ny * 1024 + nx
        if not seen[nk] and crossable(map, cell[1], cell[2], d[3]) then
          if walk(nx, ny) then
            seen[nk] = true; stack[#stack + 1] = { nx, ny }
          elseif kindAt(nx, ny) == "~" then
            shore[nk] = { nx, ny }
          end
        end
      end
    end
    local wstack, wseen = {}, {}
    for k, cell in pairs(shore) do wstack[#wstack + 1] = cell; wseen[k] = true end
    while #wstack > 0 do
      local cell = wstack[#wstack]; wstack[#wstack] = nil
      water[#water + 1] = cell
      for _, d in ipairs(NEIGH) do
        local nx, ny = cell[1] + d[1], cell[2] + d[2]
        local nk = ny * 1024 + nx
        if not wseen[nk] and kindAt(nx, ny) == "~"
            and crossable(map, cell[1], cell[2], d[3]) then
          wseen[nk] = true; wstack[#wstack + 1] = { nx, ny }
        end
      end
    end
    return land, water
  end

  -- Groups a flat cell list into contiguous 4-neighbor patches (BUGS.md #16/#18:
  -- treat every encounter patch on equal footing instead of one pool weighted by
  -- raw candidate count, which let one big water body or grass field starve
  -- smaller patches nearby).
  local function labelPatches(cells)
    local index = {}
    for i, c in ipairs(cells) do index[c[2] * 1024 + c[1]] = i end
    local visited, patches = {}, {}
    for i, c in ipairs(cells) do
      local key = c[2] * 1024 + c[1]
      if not visited[key] then
        visited[key] = true
        local patch, stack = {}, { c }
        while #stack > 0 do
          local cell = stack[#stack]; stack[#stack] = nil
          patch[#patch + 1] = cell
          for _, d in ipairs(NEIGH) do
            local nx, ny = cell[1] + d[1], cell[2] + d[2]
            local nk = ny * 1024 + nx
            local ni = index[nk]
            if ni and not visited[nk] then
              visited[nk] = true
              stack[#stack + 1] = cells[ni]
            end
          end
        end
        patches[#patches + 1] = patch
      end
    end
    return patches
  end

  -- BUGS.md #18's own pitch: a 4+ tile patch floors at 2, +1 per additional 4
  -- tiles. Extended down to a floor of 1 for 1-3 tile patches so a tiny patch
  -- is never silently starved outright.
  local function patchQuota(size)
    if size <= 0 then return 0 end
    if size < 4 then return 1 end
    return 2 + math.floor((size - 4) / 4)
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
      a.alloc = math.floor(exact)
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
      levels[species] = math.floor(levelSum[species] / wt + 0.5)
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
    if n > 0 then return math.floor(sum / n + 0.5) end
    return any or 5
  end

  local live = {}
  local liveById = {} -- npcId -> entry, kept in sync with `live`
  local activeMapId
  local grassDist, waterDist
  local regionLand, regionWater, regionEligible, regionTotalQuota
  local regionFloodAtX, regionFloodAtY
  local stepTick = 0
  local topUpClock = 0
  local TOPUP_INTERVAL = 1
  local pending
  local pendingDvs
  local pendingTouchClock
  local lastBattleQueueClock
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

  local function removeWanderer(i)
    local w = live[i]
    if w and w.npcId then mod.world:removeNpc(w.npcId) end
    if w and w.sparkleNpcId then mod.world:removeNpc(w.sparkleNpcId) end
    if w and w.npcId then liveById[w.npcId] = nil end
    table.remove(live, i)
  end

  local function despawnAll()
    for i = #live, 1, -1 do removeWanderer(i) end
  end

  local function npcCell(w)
    local h = w.index and mod.world:npc(activeMapId, w.index)
    if h and h.npc then return h.npc.cellX, h.npc.cellY, h.npc end
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
    end
    local form
    if dex == UNOWN_DEX and Unown then
      form = dvs and Unown.name(Unown.letterFromDVs(dvs))
        or Unown.name(math.floor(r() * Unown.NUM_UNOWN) + 1)
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
      npcId = npcId, index = index, slot = slot,
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
          entry.sparkleClock = 0
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
    regionFloodAtX, regionFloodAtY = nil, nil
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
      npcId = npcId, index = npcIndex, slot = rslot,
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
          local pick = candidates[math.floor(r() * #candidates) + 1]
          local c, terrain = pick[1], pick[2]
          spawnRoamer(index, slot, c, terrain, pcx, pcy)
          taken[c[2] * 1024 + c[1]] = true
        end
      end
    end
  end

  local function topUp(pcx, pcy)
    if pending or not activeMapId or not (pcx and pcy) then return end
    local map = liveMap()
    if not (map and map.isWalkableCell and map.widthCells) then return end

    local viewRadius, placementRadius, despawnRadius = windowRadii()

    -- Self-healing re-flood: if the flood computed from the player's entry
    -- cell (or wherever they were standing on the last attempt) ends up
    -- having nothing SPAWNABLE in it -- confirmed on a real Route 35 entry
    -- from Route 36: the player lands in a small, real, walkable alcove
    -- (localRegion finds it fine) that simply has no grass tiles in it at
    -- all -- the OLD code cached that dead-end result for the rest of the
    -- map visit and never tried again, so spawns stayed stuck at zero even
    -- after the player walked elsewhere on the same map. Now: a flood that
    -- comes up empty of spawnable land/water only "sticks" for the exact
    -- cell it was computed from; any actual player movement re-attempts it
    -- from the new position, bounded by real movement rather than the
    -- periodic topUpClock tick (so it can't cost a fresh BFS every second
    -- while the player is stationary in a genuinely grass/water-free spot
    -- like a town).
    local needFlood = not regionLand
      or (regionEligible == false and not (regionFloodAtX == pcx and regionFloodAtY == pcy))
    if needFlood then
      regionLand, regionWater = localRegion(map, pcx, pcy)
      regionFloodAtX, regionFloodAtY = pcx, pcy
    end
    local landRaw, water = regionLand or {}, regionWater or {}
    local land = landRaw
    if not grassDist then land = {} end
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

    if grassDist and #land > 0 and map.isGrassCell then
      local g = {}
      for _, c in ipairs(land) do
        if map:isGrassCell(c[1], c[2]) then g[#g + 1] = c end
      end
      if #g > 0 then
        land = g
      else
        local env = map.def and map.def.environment
        if env == "ROUTE" or env == "TOWN" then land = {} end
      end
    end

    syncRoamers(map, pcx, pcy, land, water, taken, placementRadius)

    local eligible = #land + #water
    regionEligible = eligible > 0
    if eligible == 0 then return end

    -- `totalQuota` (the region's real carrying capacity) depends only on
    -- `land`/`water` -- the whole-region habitat lists -- never on the
    -- player's position or which cells are currently taken. So it's stable
    -- for as long as regionLand/regionWater are (i.e. until the next
    -- `needFlood`), and can be cached instead of recomputed via a full
    -- patch-labeling BFS on every topUp tick (every ~1s). This matters even
    -- once the wanderer pool is full (see below), AND when the habitat is
    -- simply too small to ever fill the pool -- without this cache, a small
    -- pocket of grass that tops out at e.g. 4 mons would still pay for the
    -- full BFS forever, every tick, since `#live < POOL` never stops being
    -- true. Was a real music-stutter source on weak hardware.
    if needFlood then
      regionTotalQuota = 0
      for _, list in ipairs({ land, water }) do
        for _, p in ipairs(labelPatches(list)) do
          regionTotalQuota = regionTotalQuota + patchQuota(#p)
        end
      end
    end

    local target = math.min(densityCap(placementRadius), regionTotalQuota or 0)
    if target < 2 then target = 2 end
    local nearby = 0
    for _, w in ipairs(live) do
      local cx, cy = npcCell(w)
      if cx and cheb(cx, cy, pcx, pcy) <= despawnRadius then nearby = nearby + 1 end
    end
    -- Cheap ceiling check using the cached quota above -- skips the
    -- expensive per-tick BFS/shore-check pass below entirely once the area
    -- is at capacity (whether that capacity is POOL or the habitat's own
    -- smaller ceiling).
    if math.min(target - nearby, POOL - #live) <= 0 then return end

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
    -- fragments, each capped at patchQuota's tiny per-fragment floor. That
    -- undercounted badly on real routes (regression found on Route 37:
    -- reported "only 2 Pokemon ever spawn"). Quota is computed from the real
    -- patch; `windowFilter` is then only used to find which of that patch's
    -- cells are actually placeable this pass.
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

    local need = math.min(target - nearby, POOL - #live)
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
      local i = math.floor(r() * #list) + 1
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
    regionFloodAtX, regionFloodAtY = nil, nil
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

  mod.hooks:wrap("input.step", function(next_, game, dt)
    next_(game, dt)

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
      for _, w in ipairs(live) do
        if w.sparkleIndex then
          local h = mod.world:npc(activeMapId, w.index)
          local sh = mod.world:npc(activeMapId, w.sparkleIndex)
          if h and h.npc and sh and sh.npc then
            sh.npc.cellX, sh.npc.cellY = h.npc.cellX, h.npc.cellY
            sh.npc.px, sh.npc.py = h.npc.px, h.npc.py
            w.sparkleClock = (w.sparkleClock or 0) + (dt or 0)
            local period = SPARKLE_FRAME_SECONDS * SPARKLE_FRAMES
            w.sparkleClock = w.sparkleClock % period
            local frame = math.floor(w.sparkleClock / SPARKLE_FRAME_SECONDS) % SPARKLE_FRAMES
            sh.npc.bounceFrame = function() return frame end
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
  end)

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

  mod.hooks:wrap("encounter.roll", function(next_, tables, ctx)
    if ctx and ctx.mapId == activeMapId then return nil end
    return next_(tables, ctx)
  end)

  -- Wild mons are solid now; this only handles the player's bump and wander/habitat rules.
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
      if map.isGrassCell and map:isGrassCell(mover.cellX, mover.cellY)
          and not map:isGrassCell(tx, ty) then
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

  local Chain = setupChain(mod)

  setupFollower(mod)
  setupFollowerEmotes(mod)
  setupFollowerForaging(mod)
  setupFollowerInteraction(mod)
  setupWild(mod, Chain, Roamers)
  setupOverworldReskin(mod)
  setupObjectOverrides(mod)
  setupReskinBounceFix(mod)
end
