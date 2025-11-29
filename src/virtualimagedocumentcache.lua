local lru = require("ffi/lru")
local util = require("util")
local logger = require("logger")

local function calcTileCacheSize()
    local min = 32 * 1024 * 1024
    local max = 256 * 1024 * 1024

    local memfree = util.calcFreeMem() or 0
    local calc = memfree * 0.25

    return math.min(max, math.max(min, calc))
end

local function computeNativeCacheSize()
    local total = calcTileCacheSize()
    local native_size = total

    local mb_size = native_size / 1024 / 1024
    if mb_size >= 8 then
        return native_size
    else
        return 8 * 1024 * 1024
    end
end

local VIDCache = {
    _native_cache = nil,
    _stats = {
        hits = 0,
        misses = 0,
        sets = 0,
        evictions = 0,
    },
}

function VIDCache:init()
    if self._native_cache then
        return
    end

    local cache_size = computeNativeCacheSize()
    local cache_size_mb = cache_size / (1024 * 1024)

    -- Put 9999 since we want to limit by size only
    self._native_cache = lru.new(9999, cache_size, true)

    logger.info(string.format("VIDCache: Initialized | Max size: %.1fMB | Free mem: %.1fMB",
                              cache_size_mb,
                              (util.calcFreeMem() or 0) / (1024 * 1024)))
end

function VIDCache:getNativeTile(hash)
    if not self._native_cache then
        self:init()
    end

    local tile = self._native_cache:get(hash)

    if tile then
        self._stats.hits = self._stats.hits + 1
    else
        self._stats.misses = self._stats.misses + 1
    end

    return tile
end

function VIDCache:setNativeTile(hash, tile, size)
    if not self._native_cache then
        self:init()
    end

    local current_size = self._native_cache:used_size() or 0
    local max_size = self._native_cache:total_size() or 0

    if current_size + size > max_size then
        self._stats.evictions = self._stats.evictions + 1
    end

    self._native_cache:set(hash, tile, size)
    self._stats.sets = self._stats.sets + 1
end

function VIDCache:clear()
    if self._native_cache then
        self._native_cache:clear()
    end
    self._stats = {
        hits = 0,
        misses = 0,
        sets = 0,
        evictions = 0,
    }
end

function VIDCache:getCacheSize()
    if not self._native_cache then
        self:init()
    end
    return self._native_cache:total_size() or computeNativeCacheSize()
end

function VIDCache:getStats()
    if not self._native_cache then
        self:init()
    end

    local current_size = self._native_cache:used_size() or 0
    local max_size = self._native_cache:total_size() or 0
    local current_count = self._native_cache:used_slots() or 0

    return {
        hits = self._stats.hits,
        misses = self._stats.misses,
        sets = self._stats.sets,
        evictions = self._stats.evictions,
        hit_rate = (self._stats.hits + self._stats.misses > 0)
                   and (self._stats.hits / (self._stats.hits + self._stats.misses) * 100)
                   or 0,
        current_size_mb = current_size / (1024 * 1024),
        max_size_mb = max_size / (1024 * 1024),
        usage_pct = (max_size > 0) and (current_size / max_size * 100) or 0,
        tile_count = current_count,
    }
end

function VIDCache:logStats()
    local stats = self:getStats()
    logger.info(string.format("VIDCache stats | Hits: %d | Misses: %d | Rate: %.1f%% | Size: %.1f/%.1fMB (%.0f%%) | Tiles: %d | Sets: %d | Evictions: %d",
                              stats.hits, stats.misses, stats.hit_rate,
                              stats.current_size_mb, stats.max_size_mb, stats.usage_pct,
                              stats.tile_count, stats.sets, stats.evictions))
end

return VIDCache
