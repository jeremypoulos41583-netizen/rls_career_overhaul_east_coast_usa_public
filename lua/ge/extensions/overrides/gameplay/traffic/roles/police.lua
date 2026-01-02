-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

function C:init()
  self.class = 'emergency'
  self.keepActionOnRefresh = false
  self.personalityModifiers = {
    aggression = {offset = 0.1}
  }
  self.veh.drivability = 0.5
  self.targetPursuitMode = 0
  self.avoidSpeed = 40 -- speed difference at which the police vehicle will try to dodge the target vehicle
  self.sirenTimer = -1
  self.cooldownTimer = -1
  self.driveInLane = true
  self.validTargets = {}
  self.actions = {
    pursuitStart = function (args)
      local firstMode = 'chase'
      local modeNum = 0
      local obj = getObjectByID(self.veh.id)

      if self.veh.isAi then
        obj:queueLuaCommand('ai.setSpeedMode("off")')
        obj:queueLuaCommand('ai.driveInLane("on")')

        if args.targetId then
          local targetVeh = gameplay_traffic.getTrafficData()[args.targetId]
          if targetVeh then
            modeNum = targetVeh.pursuit.mode
            firstMode = modeNum <= 1 and 'follow' or 'chase'
          end
        end

        if modeNum == 1 then -- passive
          self.veh:setAiMode('follow')
          self.veh:useSiren(0.5 + math.random())
          self.sirenTimer = 2 + math.random() * 2
        else -- aggressive
          self.veh:setAiMode('chase')
          obj:queueLuaCommand('electrics.set_lightbar_signal(2)')
          self.sirenTimer = -1
        end
      end

      self.targetPursuitMode = modeNum
      self.state = firstMode
      self.driveInLane = true
      self.flags.roadblock = nil
      self.flags.busy = 1
      self.cooldownTimer = -1
      self.avoidSpeed = math.random(18, 24) * modeNum

      if not self.flags.pursuit then
        self.veh:modifyRespawnValues(500)
        self.flags.pursuit = 1
      end
    end,
    pursuitEnd = function ()
      if self.veh.isAi then
        self.veh:setAiMode('stop')
        getObjectByID(self.veh.id):queueLuaCommand('electrics.set_lightbar_signal(1)')
        self:setAggression()
      end
      self.flags.pursuit = nil
      self.flags.reset = 1
      self.flags.cooldown = 1
      self.cooldownTimer = math.max(10, gameplay_police.getPursuitVars().arrestTime + 5)
      self.state = 'disabled'

      self.targetPursuitMode = 0
    end,
    chaseTarget = function ()
      self.veh:setAiMode('chase')
      getObjectByID(self.veh.id):queueLuaCommand('ai.driveInLane("off")')
      self.driveInLane = false
      self.state = 'chase'
    end,
    avoidTarget = function ()
      self.veh:setAiMode('flee')
      getObjectByID(self.veh.id):queueLuaCommand('ai.driveInLane("on")')
      self.driveInLane = true
      self.state = 'flee'
    end,
    roadblock = function ()
      if self.veh.isAi then
        self.veh:setAiMode('stop')
        getObjectByID(self.veh.id):queueLuaCommand('electrics.set_lightbar_signal(2)')
      end
      self.flags.roadblock = 1
      self.state = 'stop'
      self.veh:modifyRespawnValues(300, 40)
    end
  }

  for k, v in pairs(self.baseActions) do
    self.actions[k] = v
  end
  self.baseActions = nil
end

function C:checkTarget()
  local traffic = gameplay_traffic.getTrafficData()
  local targetId
  local bestScore = 0

  for id, veh in pairs(traffic) do
    if id ~= self.veh.id and veh.role.name ~= 'police' and not veh.ignorePolice then
      -- Ignore vehicles with license plate "911"
      local plate = core_vehicles.getVehicleLicenseText(getObjectByID(id))
      if plate == "911" then
        goto continue
      end

      if veh.pursuit.mode >= 1 and veh.pursuit.score > bestScore then
        bestScore = veh.pursuit.score
        targetId = id
      end
    end
    ::continue::
  end

  return targetId
end

function C:onRefresh()
  if self.state == 'disabled' then self.state = 'none' end
  self.actionTimer = 0
  self.cooldownTimer = -1

  if self.flags.reset then
    self:resetAction()
  end

  local targetId = self:checkTarget()
  if targetId then
    self:setTarget(targetId)
    self.flags.targetVisible = nil
    local targetVeh = gameplay_traffic.getTrafficData()[targetId]
    if not targetVeh.pursuit.roadblockPos or (targetVeh.pursuit.roadblockPos and getObjectByID(self.veh.id):getPosition():squaredDistance(targetVeh.pursuit.roadblockPos) > 400) then
      self:setAction('pursuitStart', {targetId = targetId})
    end
    self.veh:modifyRespawnValues(750 - self.targetPursuitMode * 150)
  else
    if self.flags.pursuit then
      self:resetAction()
    end
  end

  if self.flags.pursuit then
    self.veh.respawn.spawnRandomization = 0.25
  end
end

function C:onTrafficTick(dt)
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    if id ~= self.veh.id and veh.role.name ~= 'police' and not veh.ignorePolice then
      -- Ignore vehicles with license plate "911"
      local plate = core_vehicles.getVehicleLicenseText(getObjectByID(id))
      if plate == "911" then
        self.validTargets[id] = nil
        goto continue
      end

      if not self.validTargets[id] then self.validTargets[id] = {} end
      local interDist = self.veh:getInteractiveDistance(veh.pos, true)

      self.validTargets[id].dist = self.veh.pos:squaredDistance(veh.pos)
      self.validTargets[id].interDist = interDist
      self.validTargets[id].visible = interDist <= 10000 and self:checkTargetVisible(id)

      if self.flags.pursuit and self.validTargets[id].dist <= 100 and self.veh.speed < 2.5 and veh.speed < 2.5 then
        self.validTargets[id].visible = true
      end

      if self.flags.pursuit and self.validTargets[id].visible and not self.flags.targetVisible then
        local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
        if targetVeh then
          targetVeh.pursuit.policeCount = targetVeh.pursuit.policeCount + 1
          self.flags.targetVisible = 1
        end
      end
    else
      self.validTargets[id] = nil
    end
    ::continue::
  end

  local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
  -- ... rest of onTrafficTick unchanged ...
end

function C:onUpdate(dt, dtSim)
  -- unchanged
end

return function(...) return require('/lua/ge/extensions/gameplay/traffic/baseRole')(C, ...) end
