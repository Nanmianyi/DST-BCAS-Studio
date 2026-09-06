--[[
    Oasis-like ocean TILE look.

    Uses the same GROUND.OCEAN_* ids as workshop 3794362938, but never
    replaces ocean_combined / never blacks the floor / never spawns a
    full-screen water mesh. Only retints registered ocean tiles and
    nudges TUNING.OCEAN_SHADER toward translucent cyan sparkle.

    v3.6 (2026-09-06 定版): 水面折射 mesh 与全部运行时海洋覆盖
    （blend / clear color / 噪声参数 / oceancolor 钩子）已按用户决定移除 ——
    定版效果 = 本文件的海洋地皮调色（世界生成时烘进海洋纹理）+ 原版水面
    渲染。开关 OceanOn 改动地皮定义后需重进世界重烘焙才能生效（UI 第 7 页
    已注明）。历史实现见 git 历史 / src_shaders/ 与 tools/build_water_anim.py。
]]

local _G = rawget(_G, "GLOBAL") or _G
local OceanLook = {}
local saved_tiles = nil
local applied = false

local function Vec4(r, g, b, a)
    return { r, g, b, a }
end

local function CopyColourBlock(src)
    if src == nil then return nil end
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            out[k] = { v[1], v[2], v[3], v[4] }
        else
            out[k] = v
        end
    end
    return out
end

-- Oasis / hotspring: bright cyan primary (sparkle) + deeper teal secondary
-- (translucent body). Alpha on primary stays low so the water stays see-through.
local function OasisBlock(pr, pg, pb, pa, sr, sg, sb, sa, mr, mg, mb, ma)
    return {
        primary_color        = Vec4(pr, pg, pb, pa),
        secondary_color      = Vec4(sr, sg, sb, sa),
        secondary_color_dusk = Vec4(math.floor(sr * 0.45), math.floor(sg * 0.45), math.floor(sb * 0.5), math.min(255, sa + 20)),
        minimap_color        = Vec4(mr, mg, mb, ma or 102),
    }
end

-- Deep saturated blue body (MC-shaders feel), white sparkle channel kept
-- for glint, waves near-white. Murk comes from blending the low-res sampler
-- texture strongly, so the body stays deep and the blend stays LOW.
local OASIS_COLOURS = {
    OCEAN_COASTAL_SHORE  = OasisBlock(255, 255, 255,  90,  30,  92, 112, 150,  23, 51, 62),
    OCEAN_COASTAL        = OasisBlock(255, 255, 255,  60,  16,  80, 118, 120,  23, 51, 62),
    OCEAN_SWELL          = OasisBlock(200, 255, 255,  45,   0,  45,  92, 220,  14, 34, 61, 204),
    OCEAN_ROUGH          = OasisBlock( 60, 190, 220,  60,   1,  20,  50, 230,  19, 20, 40, 230),
    OCEAN_HAZARDOUS      = OasisBlock(255, 255, 255,  48,   0,   8,  18,  51,   8,  8, 14, 51),
    OCEAN_BRINEPOOL      = OasisBlock( 60, 200, 225,  80,   5,  25,  55, 200,  40, 87, 93, 51),
    OCEAN_BRINEPOOL_SHORE= OasisBlock(255, 255, 255,  48, 255,   0,   0, 255, 255,  0,  0, 255),
    OCEAN_WATERLOG       = OasisBlock(255, 255, 255,  60,  25, 110, 140, 100,  40, 87, 93, 51),
}

local WAVETINT_OASIS = {
    OCEAN_COASTAL_SHORE  = {1.00, 1.00, 1.00},
    OCEAN_COASTAL        = {1.00, 1.00, 1.00},
    OCEAN_SWELL          = {0.94, 1.00, 1.00},
    OCEAN_ROUGH          = {0.90, 0.98, 1.00},
    OCEAN_HAZARDOUS      = {0.55, 0.65, 0.78},
    OCEAN_BRINEPOOL      = {0.90, 1.00, 1.00},
    OCEAN_BRINEPOOL_SHORE= {1.00, 1.00, 1.00},
    OCEAN_WATERLOG       = {1.00, 1.00, 1.00},
}

local function TileId(name)
    local WT = _G.WORLD_TILES
    if WT and WT[name] ~= nil then return WT[name] end
    local G = _G.GROUND
    if G and G[name] ~= nil then return G[name] end
    return nil
end

local function ApplyTiles(enabled)
    local ok, GroundTiles = pcall(function()
        return require("worldtiledefs")
    end)
    if not ok or GroundTiles == nil or GroundTiles.ground == nil then
        return
    end
    if saved_tiles == nil then
        saved_tiles = {}
        for i, entry in ipairs(GroundTiles.ground) do
            local def = entry[2]
            if def ~= nil then
                saved_tiles[entry[1]] = {
                    colors = CopyColourBlock(def.colors),
                    wavetint = def.wavetint and { def.wavetint[1], def.wavetint[2], def.wavetint[3] } or nil,
                }
            end
        end
    end

    local id_of = {}
    for name in pairs(OASIS_COLOURS) do
        local id = TileId(name)
        if id ~= nil then
            id_of[id] = name
        end
    end

    for i, entry in ipairs(GroundTiles.ground) do
        local tile_id, def = entry[1], entry[2]
        if def ~= nil then
            local name = id_of[tile_id]
            local backup = saved_tiles[tile_id]
            if enabled and name ~= nil then
                def.colors = OASIS_COLOURS[name]
                if WAVETINT_OASIS[name] then
                    def.wavetint = WAVETINT_OASIS[name]
                end
            elseif backup ~= nil then
                if backup.colors then
                    def.colors = backup.colors
                end
                def.wavetint = backup.wavetint
            end
        end
    end
end

function OceanLook.Apply(enabled)
    enabled = enabled == true
    ApplyTiles(enabled)
    applied = enabled
end

function OceanLook.IsApplied()
    return applied
end

return OceanLook
