-- virtualContainers.lua
-- Patches career_modules_delivery_general.getNearbyVehicleCargoContainers(cb)
-- Injects ONE virtual container for the PLAYER vehicle only when the player has no real containers.


-- Simple file logger to mod directory
local function fileLogSimple(msg)
  local logPath = "mods/unpacked/rls_career_overhaul_east_coast_usa/virtualContainer.log"
  local f = io.open(logPath, "a")
  if f then 
    f:write(os.date("[%H:%M:%S] ")..msg.."\n") 
    f:close() 
  end
end

fileLogSimple("[virtualContainers] file parsed")
print("[virtualContainer.lua] *** MODULE PARSED - virtualContainer is loaded ***")

-- Kill-switch: set to true to enable patching; false disables virtual containers
local ENABLE_VIRTUAL_CONTAINERS = true

local M = {}

local originalGetNearbyCb = nil
local didPatch = false

local didLogFirstCall = false
local injectedForVeh = {}     -- vehId -> true
local virtualByVehId = {}     -- vehId -> container table
local asyncQueryInProgress = false
local lastResultContainers = nil  -- Cache last result

local function getPlayerVehId()
  local veh = be:getPlayerVehicle(0)
  return veh and veh:getId() or nil
end

local function buildVirtualContainer(vehId)
  -- IMPORTANT: cargoCards.lua uses string.format("container_%d_%d", con.vehId, con.containerId)
  -- so con.containerId MUST be a NUMBER.
  local VIRTUAL_CONTAINER_NUM_ID = 1
  local big = 1000000000 -- large slot count

  return {
    -- identity (NUMBERS!)
    vehId = vehId,
    containerId = VIRTUAL_CONTAINER_NUM_ID,

    -- optional string id (safe)
    id = ("virtualContainer_%d"):format(vehId),

    -- UI labels
    name = "Virtual Flatbed",
    moveToLabel = "Virtual Flatbed",

    -- LOCATION MUST include containerId (this matters in move/add logic)
    location = { type = "vehicle", vehId = vehId, containerId = VIRTUAL_CONTAINER_NUM_ID },

    -- capacity/slots (NUMBERS)
    totalCargoSlots = big,
    usedCargoSlots = 0,
    freeCargoSlots = big,
    transientCargoSlots = 0,

    -- cargo lists (must exist)
    rawCargo = {},
    transientCargo = {},

    -- Keep it boring/compatible.
    -- Most “materials” are type dryBulk; parcel is common too.
    cargoTypesLookup = {
      dryBulk = true,
      parcel  = true,
      fluid   = true,
    },
    cargoTypesString = "dryBulk",

    -- marker
    isVirtual = true,
    type = "virtual",
  }
end

local function ensureVirtualForVeh(vehId)
  if not virtualByVehId[vehId] then
    virtualByVehId[vehId] = buildVirtualContainer(vehId)
  end
  return virtualByVehId[vehId]
end

local insideWrapper = false
local function wrappedGetNearbyVehicleCargoContainers(callback, ...)
  if insideWrapper then
    fileLogSimple("[virtualContainers] re-entrancy detected, passing through to original")
    return originalGetNearbyCb(callback, ...)
  end

  local playerVehId = getPlayerVehId()

  -- If we already have a cached result, return it immediately
  if lastResultContainers and #lastResultContainers > 0 then
    fileLogSimple("[virtualContainers] Returning cached containers immediately")
    return callback(lastResultContainers)
  end

  -- If no cache and we have a player vehicle, synthesize virtual container immediately
  if playerVehId then
    local vc = ensureVirtualForVeh(playerVehId)
    local synthetic = {vc}
    lastResultContainers = synthetic
    fileLogSimple(string.format("[virtualContainers] Immediate synth container vehId=%s", tostring(playerVehId)))

    -- Kick off async refresh in the background to capture real containers if present
    if not asyncQueryInProgress then
      asyncQueryInProgress = true
      originalGetNearbyCb(function(containers)
        if type(containers) ~= "table" then containers = {} end

        -- If we find real containers for the player, replace cache; else keep virtual
        local playerHasReal = false
        if playerVehId then
          for _, con in ipairs(containers) do
            if con and con.vehId == playerVehId and not con.isVirtual then
              playerHasReal = true
              break
            end
          end
        end

        if playerHasReal then
          lastResultContainers = containers
          fileLogSimple(string.format("[virtualContainers] Async refresh found REAL containers for vehId=%s", tostring(playerVehId)))
        else
          -- ensure virtual present in cache
          local hasVirtual = false
          for _, con in ipairs(containers) do
            if con and con.isVirtual then hasVirtual = true break end
          end
          if not hasVirtual then
            containers[#containers+1] = vc
          end
          lastResultContainers = containers
          fileLogSimple(string.format("[virtualContainers] Async refresh kept virtual container for vehId=%s", tostring(playerVehId)))
        end
        asyncQueryInProgress = false
      end, ...)
    end

    return callback(synthetic)
  end

  -- Fallback: no player vehicle, just call original
  return originalGetNearbyCb(callback, ...)
end

local function tryPatch()
  if didPatch then return true end

  local dg = extensions and extensions.career_modules_delivery_general
  if dg and type(dg.getNearbyVehicleCargoContainers) == "function" then
    originalGetNearbyCb = dg.getNearbyVehicleCargoContainers
    dg.getNearbyVehicleCargoContainers = wrappedGetNearbyVehicleCargoContainers
    didPatch = true
    print("[virtualContainers] patched career_modules_delivery_general.getNearbyVehicleCargoContainers")
    return true
  end

  print("[virtualContainers] patch FAILED (delivery_general not ready yet)")
  return false
end

function M.onExtensionLoaded()
  print("[virtualContainer.lua] *** onExtensionLoaded() CALLED ***")
  print("[virtualContainers] onExtensionLoaded()")
  if not ENABLE_VIRTUAL_CONTAINERS then
    print("[virtualContainers] disabled via kill-switch")
    return
  end
  tryPatch()
end

function M.onCareerActivated()
  print("[virtualContainer.lua] *** onCareerActivated() CALLED ***")
  if not ENABLE_VIRTUAL_CONTAINERS then return end
  if not didPatch then
    print("[virtualContainers] onCareerActivated() retry patch")
    tryPatch()
  end
end

return M
