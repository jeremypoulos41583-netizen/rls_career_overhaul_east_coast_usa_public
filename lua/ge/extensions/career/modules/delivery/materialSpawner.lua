-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

print("[materialSpawner.lua] *** MODULE PARSED - materialSpawner is loaded ***")

-- File logging helper (writes to both console and file)
local logFile = nil
local function initLogFile()
  if not logFile then
    local logPath = "mods/unpacked/rls_career_overhaul_east_coast_usa4.7.4/materialSpawner.log"
    logFile = io.open(logPath, "w")
    if logFile then
      logFile:write("=== Material Spawner Log Started ===\n")
      logFile:flush()
    end
  end
end

local function fileLog(level, category, message, ...)
  -- Also log to console
  log(level, category, message, ...)

  -- Write to file
  initLogFile()
  if logFile then
    local formattedMsg = string.format(message, ...)
    local timestamp = os.date("%H:%M:%S")
    logFile:write(string.format("[%s] [%s] %s: %s\n", timestamp, level, category, formattedMsg))
    logFile:flush()
  end
end

-- Cache of materials that support prop spawning
local spawnableMaterials = {}
local spawnableMaterialsByType = {} -- Indexed by material.type (dryBulk/fluid/etc) for quick lookup

-- Cache for discovered vehicles by material type
local discoveredVehiclesByMaterial = {}

-- Cache for materials with autoDiscover enabled
local autoDiscoverMaterials = {}

-- Virtual container ID prefix to avoid conflicts with real containers
local VIRTUAL_CONTAINER_ID_PREFIX = 999000

-- Prop tracking
local spawnedProps = {} -- {propId = {materialType, cargoId, spawnTime, lastPlayerDistance, lastPlayerDistanceTime}}
local spawnedPropsByCargoId = {} -- {cargoId = {propId1, propId2, ...}}

-- Blacklist of files to ignore (same as generator.lua)
local blacklist = {
  ["/gameplay/delivery/materials.deliveryMaterials.json"] = true,
}

-- =========================================================
-- VEHICLE DISCOVERY FOR autoDiscover MATERIALS
-- =========================================================
local function discoverVehiclesForMaterial(materialId, materialConfig)
  if discoveredVehiclesByMaterial[materialId] then
    return discoveredVehiclesByMaterial[materialId]
  end

  local discovered = {}

  local discoverConfigs = materialConfig.discoverConfigs
  if not discoverConfigs then
    discoveredVehiclesByMaterial[materialId] = discovered
    return discovered
  end

  if type(discoverConfigs) == "string" then
    discoverConfigs = {discoverConfigs}
  end

  if not util_configListGenerator or not util_configListGenerator.getEligibleVehicles then
    fileLog("W", "materialSpawner", "util_configListGenerator.getEligibleVehicles not available, falling back to file search")

    local vehicleFolders = FS:findFiles("vehicles/", "", 1, false, false)
    for _, folderPath in ipairs(vehicleFolders) do
      local folderName = string.match(folderPath, "([^/\\]+)/?$")
      if folderName then
        local infoFiles = FS:findFiles(folderPath, "info_*.json", 0, false, false)
        for _, infoFile in ipairs(infoFiles) do
          local fileName = string.match(infoFile, "([^/\\]+)$")
          if fileName then
            local configName = string.match(fileName, "^info_(.+)%.json$")
            if configName then
              local matches = false
              for _, pattern in ipairs(discoverConfigs) do
                if string.find(string.lower(configName), string.lower(pattern)) then
                  matches = true
                  break
                end
              end
              if matches then
                local infoData = jsonReadFile(infoFile)
                if infoData then
                  local modelKey = folderName
                  local config = infoData.Configuration or configName
                  local weight = infoData.Weight or (materialConfig.density and materialConfig.density * 1000) or 1000
                  local value = infoData.Value or materialConfig.money or 700
                  local name = infoData.Name or (modelKey .. " " .. configName)

                  local materialEntry = {
                    id = materialId .. "_" .. modelKey .. "_" .. configName,
                    name = name,
                    density = weight / 1000,
                    type = materialConfig.type or "dryBulk",
                    money = value,
                    canSpawn = true,
                    model_key = modelKey,
                    config = config,
                    icon = materialConfig.icon or "car",
                    slotsPerProp = materialConfig.slotsPerProp or 64,
                    spawnGridSpacing = materialConfig.spawnGridSpacing or 2.0,
                    spawnZoneName = materialConfig.spawnZoneName or "loadingZone"
                  }

                  table.insert(discovered, materialEntry)
                  fileLog("I", "materialSpawner", "Discovered vehicle for %s: %s/%s (name: %s)", materialId, modelKey, config, name)
                end
              end
            end
          end
        end
      end
    end

    discoveredVehiclesByMaterial[materialId] = discovered
    return discovered
  end

  fileLog("I", "materialSpawner", "Using game vehicle system to discover vehicles for material %s", materialId)
  local allVehicles = util_configListGenerator.getEligibleVehicles(false, false) or {}
  fileLog("I", "materialSpawner", "Found %d total vehicles in game system", #allVehicles)

  for _, vehicleInfo in ipairs(allVehicles) do
    if vehicleInfo.model_key and vehicleInfo.key then
      local configName = vehicleInfo.key
      local matches = false
      for _, pattern in ipairs(discoverConfigs) do
        if string.find(string.lower(configName), string.lower(pattern)) then
          matches = true
          break
        end
      end

      if matches then
        local modelKey = vehicleInfo.model_key
        local config = vehicleInfo.key

        local weight = vehicleInfo.Weight or (materialConfig.density and materialConfig.density * 1000) or 1000
        local value = vehicleInfo.Value or materialConfig.money or 700
        local name = vehicleInfo.Name or (modelKey .. " " .. configName)

        local materialEntry = {
          id = materialId .. "_" .. modelKey .. "_" .. configName,
          name = name,
          density = weight / 1000,
          type = materialConfig.type or "dryBulk",
          money = value,
          canSpawn = true,
          model_key = modelKey,
          config = config,
          icon = materialConfig.icon or "car",
          slotsPerProp = materialConfig.slotsPerProp or 64,
          spawnGridSpacing = materialConfig.spawnGridSpacing or 2.0,
          spawnZoneName = materialConfig.spawnZoneName or "loadingZone"
        }

        table.insert(discovered, materialEntry)
        fileLog("I", "materialSpawner", "Discovered vehicle for %s: %s/%s (name: %s)", materialId, modelKey, config, name)
      end
    end
  end

  fileLog("I", "materialSpawner", "Discovered %d vehicles for material %s", #discovered, materialId)
  discoveredVehiclesByMaterial[materialId] = discovered
  return discovered
end

local function getRandomVehicleForMaterial(materialId, materialConfig)
  local vehicles = discoverVehiclesForMaterial(materialId, materialConfig)
  if #vehicles == 0 then return nil end
  return vehicles[math.random(#vehicles)]
end

-- =========================================================
-- INITIALIZE SPAWNABLE MATERIAL LIST
-- =========================================================
local function initializeSpawnableMaterials()
  spawnableMaterials = {}
  spawnableMaterialsByType = {}
  autoDiscoverMaterials = {}

  local Allfiles = FS:findFiles("gameplay/delivery/", '*.deliveryMaterials.json', -1, false, true)
  local files = {}
  for _, file in ipairs(Allfiles) do
    if not blacklist[file] then
      table.insert(files, file)
    end
  end

  for _, file in ipairs(files) do
    local fileData = jsonReadFile(file)
    if fileData then
      for id, data in pairs(fileData) do
        data.id = id

        if data.autoDiscover then
          autoDiscoverMaterials[id] = data

          local discoveredVehicles = discoverVehiclesForMaterial(id, data)
          for _, vehicleData in ipairs(discoveredVehicles) do
            spawnableMaterials[vehicleData.id] = vehicleData
            spawnableMaterialsByType[vehicleData.type] = spawnableMaterialsByType[vehicleData.type] or {}
            table.insert(spawnableMaterialsByType[vehicleData.type], vehicleData)
          end

          -- keep base entry too (so materialType lookup works)
          spawnableMaterials[id] = data
          spawnableMaterialsByType[data.type] = spawnableMaterialsByType[data.type] or {}
          table.insert(spawnableMaterialsByType[data.type], data)
        else
          local isSpawnable = false
          if data.canSpawn == true then
            isSpawnable = true
          elseif data.model_key and data.config then
            isSpawnable = true
          end

          if isSpawnable and data.type then
            spawnableMaterials[id] = data
            spawnableMaterialsByType[data.type] = spawnableMaterialsByType[data.type] or {}
            table.insert(spawnableMaterialsByType[data.type], data)
          end
        end
      end
    end
  end

  local materialCount = 0
  for _ in pairs(spawnableMaterials) do materialCount = materialCount + 1 end
  local typeCount = 0
  for _ in pairs(spawnableMaterialsByType) do typeCount = typeCount + 1 end
  fileLog("I", "materialSpawner", "Initialized %d spawnable materials across %d types", materialCount, typeCount)
end

function M.getSpawnableMaterialsByType()
  return spawnableMaterialsByType
end

function M.isMaterialSpawnable(materialType)
  return spawnableMaterials[materialType] ~= nil or autoDiscoverMaterials[materialType] ~= nil
end

-- =========================================================
-- VIRTUAL CONTAINERS (unchanged)
-- =========================================================
function M.createVirtualContainer(vehId, veh, materialType, material, containerIndex, dGeneral)
  local vehName = dGeneral and dGeneral.getVehicleName(vehId) or ("Vehicle " .. vehId)
  local containerId = VIRTUAL_CONTAINER_ID_PREFIX + containerIndex

  local vehPos = veh:getPosition()
  local refNodeClusterId = veh:getNodeClusterId(veh:getRefNodeId())

  local containerName = string.format("%s Storage", material.name or materialType)

  local cargoTypes = {material.type}
  local cargoTypesLookup = {}
  for _, ct in ipairs(cargoTypes) do
    cargoTypesLookup[ct] = true
  end

  local defaultCapacity = 10000
  local capacity = material.virtualContainerCapacity or defaultCapacity

  local elem = {
    vehId = vehId,
    containerId = containerId,
    location = {type = "vehicle", vehId = vehId, containerId = containerId},
    vehName = vehName,
    name = containerName,
    moveToLabel = vehName .. " " .. containerName,
    cargoTypesLookup = cargoTypesLookup,
    cargoTypesString = table.concat(cargoTypes, ", "),
    totalCargoSlots = capacity,
    usedCargoSlots = 0,
    transientCargoSlots = 0,
    freeCargoSlots = capacity,
    refNodeClusterId = refNodeClusterId,
    clusterId = refNodeClusterId,
    position = vehPos,
    attachmentStatus = "attached",
    rawCargo = {},
    transientCargo = {},
    isVirtual = true,
    materialType = materialType,
  }

  return elem
end

-- =========================================================
-- SPAWN POSITION HELPERS
-- =========================================================
local function getSpawnPositionFromFacility(fac, dGenerator, materialData)
  if not fac then return nil end

  if materialData and materialData.spawnZoneName then
    fileLog("I", "materialSpawner", "Looking for spawn zone '%s' for facility %s", materialData.spawnZoneName, fac.id)

    local sites = nil
    if fac.sitesFile then
      if type(fac.sitesFile) == "string" then
        sites = gameplay_sites_sitesManager.loadSites(fac.sitesFile)
      elseif type(fac.sitesFile) == "table" and #fac.sitesFile > 0 then
        sites = gameplay_sites_sitesManager.loadSites(fac.sitesFile[1])
      end
    end

    if sites and sites.zones and sites.zones.byName then
      local zone = sites.zones.byName[materialData.spawnZoneName]
      if zone and not zone.missing and zone.vertices and #zone.vertices > 0 then
        fileLog("I", "materialSpawner", "Found spawn zone '%s' with %d vertices", materialData.spawnZoneName, #zone.vertices)

        local center = vec3(0, 0, 0)
        local count = 0
        for _, vertex in ipairs(zone.vertices) do
          if vertex.pos then
            center = center + vertex.pos
            count = count + 1
          end
        end

        if count > 0 then
          center = center / count
          center.z = core_terrain.getTerrainHeight(center) or center.z
          center = center + vec3(0, 0, 0.2)
          fileLog("I", "materialSpawner", "Using spawn zone center: %s", tostring(center))
          return center
        end
      else
        fileLog("W", "materialSpawner", "Spawn zone '%s' not found/invalid in facility %s", materialData.spawnZoneName, fac.id)
      end
    else
      fileLog("W", "materialSpawner", "Could not load sites file for facility %s to find spawn zone", fac.id)
    end
  end

  if fac.pickUpSpots and #fac.pickUpSpots > 0 then
    local ps = fac.pickUpSpots[1]
    if ps and ps.pos then
      fileLog("I", "materialSpawner", "Using fallback parking spot position")
      return ps.pos + vec3(0, 0, 0.2)
    end
  end

  if fac.center then
    fileLog("I", "materialSpawner", "Using fallback facility center position")
    return fac.center + vec3(0, 0, 0.2)
  end

  if fac.accessPointsByName then
    for _, ap in pairs(fac.accessPointsByName) do
      if ap.ps and ap.ps.pos then
        fileLog("I", "materialSpawner", "Using fallback access point position")
        return ap.ps.pos + vec3(0, 0, 0.2)
      end
    end
  end

  return nil
end

-- =========================================================
-- PROP SPAWNING
-- =========================================================
local function spawnProp(materialType, materialData, spawnPos)
  fileLog("I", "materialSpawner", "SPAWN_PROP: Starting spawn for %s", materialType)

  if not materialData.model_key or not materialData.config then
    fileLog("E", "materialSpawner", "SPAWN_PROP: Material %s missing model_key or config", materialType)
    return nil
  end

  if not spawnPos then
    fileLog("E", "materialSpawner", "SPAWN_PROP: No spawn position provided for material %s", materialType)
    return nil
  end

  local obj = core_vehicles.spawnNewVehicle(materialData.model_key, {
    pos = spawnPos,
    rot = quatFromDir(vec3(0, 1, 0)),
    config = materialData.config,
    autoEnterVehicle = false
  })

  if not obj then
    fileLog("E", "materialSpawner", "SPAWN_PROP: Failed to spawn prop for material %s", materialType)
    return nil
  end

  local propId = obj:getID()
  local actualObj = be:getObjectByID(propId)
  if not actualObj then
    obj:delete()
    fileLog("E", "materialSpawner", "SPAWN_PROP: Spawned prop %d for material %s but object not found", propId, materialType)
    return nil
  end

  fileLog("I", "materialSpawner", "SPAWN_PROP: Successfully spawned prop %d for material %s at %s", propId, materialType, tostring(spawnPos))
  return propId
end

local function chooseSpawnMaterialForCargo(materialType)
  local materialConfig = autoDiscoverMaterials[materialType]
  if materialConfig then
    local materialData = getRandomVehicleForMaterial(materialType, materialConfig)
    if materialData then
      return materialData
    end
    return nil
  end

  return spawnableMaterials[materialType]
end

local function spawnPropsForCargoItem(cargo, dGenerator, dGeneral)
  if not cargo or not cargo.id or not cargo.materialType then return false end
  if cargo.data and cargo.data.spawnedPropIds and #cargo.data.spawnedPropIds > 0 then
    return true -- already spawned
  end

  local materialType = cargo.materialType
  if not M.isMaterialSpawnable(materialType) then
    return false
  end

  local materialData = chooseSpawnMaterialForCargo(materialType)
  if not materialData then
    fileLog("W", "materialSpawner", "No spawn materialData found for %s (cargo %d)", materialType, cargo.id)
    return false
  end

  -- Facility for spawn zone
  local originFacId =
    (cargo.origin and cargo.origin.facId)
    or (cargo.data and cargo.data.sourceFacId)
    or nil

  if not originFacId then
    fileLog("W", "materialSpawner", "Cargo %d missing origin facility id, cannot spawn props", cargo.id)
    return false
  end

  local fac = dGenerator.getFacilityById(originFacId)
  if not fac then
    fileLog("W", "materialSpawner", "Facility %s not found for cargo %d, cannot spawn props", tostring(originFacId), cargo.id)
    return false
  end

  local spawnPos = getSpawnPositionFromFacility(fac, dGenerator, materialData)
  if not spawnPos then
    fileLog("W", "materialSpawner", "No spawn position for cargo %d material %s", cargo.id, materialType)
    return false
  end

  -- How many props?
  local slotsPerProp = materialData.slotsPerProp or 1
  local slots = cargo.slots or 0
  local numProps = 0
  if slotsPerProp > 0 then
    numProps = math.max(1, math.floor((slots / slotsPerProp) + 0.5))
  else
    numProps = 1
  end

  -- safety cap (keeps junk shells from going nuts)
  if numProps > 50 then numProps = 50 end

  fileLog("I", "materialSpawner", "Spawning %d props for cargo %d (material=%s, slots=%d, slotsPerProp=%d)",
    numProps, cargo.id, materialType, slots, slotsPerProp)

  local propIds = {}
  local gridSpacing = materialData.spawnGridSpacing or 2.0

  for i = 1, numProps do
    local offsetX = ((i - 1) % 10) * gridSpacing
    local offsetY = math.floor((i - 1) / 10) * gridSpacing
    local propSpawnPos = spawnPos + vec3(offsetX, offsetY, 0)

    local ok, propId = pcall(function()
      return spawnProp(materialType, materialData, propSpawnPos)
    end)

    if ok and propId then
      table.insert(propIds, propId)
      spawnedProps[propId] = {
        materialType = materialType,
        cargoId = cargo.id,
        spawnTime = dGeneral.time(),
        lastPlayerDistance = nil,
        lastPlayerDistanceTime = nil,
      }
    end
  end

  if not spawnedPropsByCargoId[cargo.id] then
    spawnedPropsByCargoId[cargo.id] = {}
  end
  for _, propId in ipairs(propIds) do
    table.insert(spawnedPropsByCargoId[cargo.id], propId)
  end

  cargo.data = cargo.data or {}
  cargo.data.spawnedPropIds = propIds
  cargo.data.isSpawnedProp = true
  cargo.data.spawnedPropMaterialType = materialType

  -- store the chosen spawn “shape” so it stays stable for this cargo id
  cargo.data.spawnedPropModelKey = materialData.model_key
  cargo.data.spawnedPropConfig = materialData.config

  fileLog("I", "materialSpawner", "Spawned %d props for cargo %d", #propIds, cargo.id)
  return true
end

-- =========================================================
-- OPTION B HOOK: CALL THIS AFTER CONTINUE / applyTransientMoves
-- =========================================================
-- movedCargoIds: array of cargo ids that were actually moved to the vehicle (rawCargo)
function M.onAfterContinue(movedCargoIds, dParcelManager, dGenerator, dGeneral)
  if not movedCargoIds or #movedCargoIds == 0 then return end
  if not dParcelManager or not dGenerator or not dGeneral then return end

  for _, cargoId in ipairs(movedCargoIds) do
    local cargo = dParcelManager.getCargoById and dParcelManager.getCargoById(cargoId) or nil
    if cargo and cargo.materialType then
      pcall(function()
        spawnPropsForCargoItem(cargo, dGenerator, dGeneral)
      end)
    end
  end
end

-- =========================================================
-- CLEANUP / DESPAWN
-- =========================================================
function M.updatePropCleanup(dt, dGeneral)
  if not dGeneral then return end

  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()

  local cleanupDistance = 60.0
  local cleanupTime = 60.0

  for propId, propData in pairs(spawnedProps) do
    local obj = be:getObjectByID(propId)
    if not obj then
      spawnedProps[propId] = nil
      if spawnedPropsByCargoId[propData.cargoId] then
        for i, id in ipairs(spawnedPropsByCargoId[propData.cargoId]) do
          if id == propId then
            table.remove(spawnedPropsByCargoId[propData.cargoId], i)
            break
          end
        end
        if #spawnedPropsByCargoId[propData.cargoId] == 0 then
          spawnedPropsByCargoId[propData.cargoId] = nil
        end
      end
    else
      local propPos = obj:getPosition()
      local distance = (propPos - playerPos):length()

      if distance > cleanupDistance then
        local currentTime = dGeneral.time()
        if not propData.lastPlayerDistanceTime then
          propData.lastPlayerDistanceTime = currentTime
        end
        propData.lastPlayerDistance = distance

        if (currentTime - propData.lastPlayerDistanceTime) > cleanupTime then
          obj:delete()
          spawnedProps[propId] = nil
          log("D", "materialSpawner", string.format(
            "Despawned prop %d (material %s) - player >%dm away for >%ds",
            propId, propData.materialType, cleanupDistance, cleanupTime
          ))
        end
      else
        propData.lastPlayerDistance = nil
        propData.lastPlayerDistanceTime = nil
      end
    end
  end
end

function M.despawnPropsForCargo(cargoId, dParcelManager)
  local list = spawnedPropsByCargoId[cargoId]
  if not list then return end

  local removed = 0
  for i = #list, 1, -1 do
    local propId = list[i]
    if propId then
      local obj = be:getObjectByID(propId)
      if obj then obj:delete() end
      spawnedProps[propId] = nil
      removed = removed + 1
    end
    list[i] = nil
  end

  spawnedPropsByCargoId[cargoId] = nil
  fileLog("I", "materialSpawner", "Despawned %d props for cargo parcel %d", removed, cargoId)
end

-- =========================================================
-- INIT
-- =========================================================
M.onCareerModulesActivated = function(alreadyInLevel)
  print("[materialSpawner.lua] *** onCareerModulesActivated() CALLED ***")
  initializeSpawnableMaterials()
end

return M
