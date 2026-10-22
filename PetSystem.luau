-- Connected Discord-GitHub

-- grab the services we need to use
local players = game:GetService("Players") --im using getservice as it guarentees the service exists and yeilds
local runService = game:GetService("RunService")
local serverStorage = game:GetService("ServerStorage")
local physicsService = game:GetService("PhysicsService")

-- all the settings for the pet system live here so they are easy to tweak
local config = {
	maxEquipped = 3,	-- how many pets a player can have out at once
	spacing = 4,	-- how far apart pets stand from each other
	followDistance = 6,	-- how far behind the player the pets stay
	arcDepth = 0.75,	-- how much the outer pets curve backward to form an arc
	bobSpeed = 2,	-- how fast floating pets bob up and down
	bobHeight = 0.5,	-- how far up and down floating pets bob
	raycastLength = 50,	-- how far down we check for the ground
	defaultHoverHeight = 0,	-- how high a pet floats if it has no HoverHeight attribute
	updateResponsiveness = 50,	-- how fast the pet constraints react to new targets
	maxForce = 50000,	-- how strong the constraints are allowed to pull
}

-- names for our two collision groups
local petsCollisionGroup = "Pets"
local playersCollisionGroup = "Players"

-- makes a collision group only if it does not already exist
local function registerGroup(name)
	if not physicsService:IsCollisionGroupRegistered(name) then
		physicsService:RegisterCollisionGroup(name)
	end
end

-- create both groups
registerGroup(petsCollisionGroup)
registerGroup(playersCollisionGroup)

-- pets already have CanCollide = false, so this does not change any physics
-- between pets and players. Its real purpose is so we can set CollisionGroup
-- on the ground raycast below and have it automatically ignore players and
-- other pets, without building a manual ignore list every frame.
physicsService:CollisionGroupSetCollidable(petsCollisionGroup, playersCollisionGroup, false)
physicsService:CollisionGroupSetCollidable(petsCollisionGroup, petsCollisionGroup, false)

-- folder in ServerStorage that holds the pet models we clone from
local petTemplates = serverStorage:WaitForChild("Pets")

-- folder in the workspace where all spawned pets will live
local activePetsFolder = workspace:FindFirstChild("ActivePets")
if not activePetsFolder then
	-- if it does not exist yet, make one
	activePetsFolder = Instance.new("Folder")
	activePetsFolder.Name = "ActivePets"
	activePetsFolder.Parent = workspace
end

-- works out where a pet should stand based on its position in line and how many pets total
local function getSlotOffset(index, total)
	-- with index running 1 to total, this always lands on 0 for the middle
	-- pet and spreads evenly outward in both directions no matter how many
	-- pets are equipped. 3 pets gives -1, 0, 1, so pet 2 sits dead center.
	-- 2 pets gives -0.5, 0.5, so they straddle the center line instead of 
	-- one sitting in the middle. Same formula works for any count, so we
	-- never have to special-case odd vs even numbers of pets
	local centered = index - (total + 1) / 2
	local x = centered * config.spacing
	--squaring centered instead of using it directly means the sign doesn't 
	-- matter, -2 and 2 both become 4, so pets the same distance from center on
	-- either side curve back by the same amount and the arc stays symmetrical
	-- it also grows faster the further a pet is from center, so the outermost 
	--pets sweep back noticeably while the pets near the middle barely move,
	-- giving a curved arc instead of pets fanning out in a straight line 
	local z = config.followDistance + (centered * centered) * config.arcDepth
	return Vector3.new(x, 0, z)
end

-- settings for the downward raycast used to find the ground height
local groundRayParams = RaycastParams.new()
groundRayParams.IgnoreWater = true
groundRayParams.CollisionGroup = petsCollisionGroup	-- this makes the ray skip anything in the pets group (since Pets do not collide with Players either)

-- shoots a ray straight down from above a position to find how high the ground is there
local function getGroundHeight(position)
	-- start a bit above so we do not start inside the floor
	--this is at 5 so it can account for uneven ground too
	local origin = position + Vector3.new(0, 5, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -config.raycastLength, 0), groundRayParams)
	if result then
		return result.Position.Y
	end
	return nil	-- nothing was hit
end

-- this is our Pet "class" using a metatable so every pet object can use pet:update(), pet:destroy(), etc
local pet = {}
pet.__index = pet

-- creates a brand new pet for a player, using one of the templates in ServerStorage
function pet.new(owner, template)
	local clone = template:Clone()	-- make our own copy of the template so we do not touch the original
	local root = clone.PrimaryPart or clone:FindFirstChild("Root")	-- figure out which part is the main part of the model
	if not root or not root:IsA("BasePart") then
		warn("Pet template " .. template.Name .. " has no PrimaryPart or Root part")	-- if there is no usable root part, stop here and clean up
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = root
	local self = setmetatable({}, pet)	-- build our pet object
	self.owner = owner	-- which player owns this pet
	self.templateName = template.Name	-- the name of the template, used to tell pets apart
	self.model = clone	-- the actual model in the workspace
	self.root = root	-- shortcut to the main part
	self.floating = template:GetAttribute("Floating") == true	-- does this pet float or walk
	self.hoverHeight = template:GetAttribute("HoverHeight") or config.defaultHoverHeight	-- how high it floats
	-- every pet reads the same clock (t) in update(), so without a per-pet
	-- offset they would all bob up and down in perfect sync and read as one
	-- object instead of several. A random phase here staggers them.
	self.bobOffset = math.random() * math.pi * 2
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = false	-- physics needs to be able to move it
			desc.CanCollide = false	-- pets should not physically block anything
			-- roblox always counts the root part's own mass no matter what,
			-- so this does not remove gravity or weight from the pet. What
			-- it actually does is make every other part add zero extra mass,
			-- so the assembly's total mass is just the root's mass. That way
			-- our MaxForce/Responsiveness settings behave the same whether
			-- the model is one part or fifty
			desc.Massless = true
			desc.CollisionGroup = petsCollisionGroup	-- put it in the pets group
			if desc ~= root then
				local weld = Instance.new("WeldConstraint")	-- weld every other part to the root so the whole pet moves as one piece
				weld.Part0 = root
				weld.Part1 = desc
				weld.Parent = root
			end
		end
	end
	local attachment = Instance.new("Attachment")	-- create an attachment point on the root, this is what the constraints will pull
	attachment.Name = "petAlignAttachment"
	attachment.Parent = root
	-- we move the pet with constraints instead of setting its CFrame
	-- directly because alignPosition/AlignOrientation ease toward a target
	-- over time. Writing .CFrame every frame would teleport the pet
	-- instantly each frame, which also breaks the smoothing that network
	-- ownership gives us, direct property writes aren't the physics
	-- simulation that ownership smooths out, only force-driven movement is
	local alignPos = Instance.new("AlignPosition")
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = attachment
	alignPos.MaxForce = config.maxForce
	alignPos.Responsiveness = config.updateResponsiveness
	alignPos.ApplyAtCenterOfMass = true
	alignPos.Parent = root
	local alignOri = Instance.new("AlignOrientation")	-- AlignOrientation rotates the pet smoothly to face a target direction
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = attachment
	alignOri.MaxTorque = config.maxForce
	alignOri.Responsiveness = config.updateResponsiveness
	alignOri.Parent = root
	self.alignPos = alignPos	-- save these so we can update them later
	self.alignOri = alignOri
	local character = owner.Character	-- try to place the pet near the player right away instead of at the world origin
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp then
		clone:PivotTo(hrp.CFrame * CFrame.new(0, 0, config.followDistance))
		alignPos.Position = root.Position	-- also give the constraints a starting target so they don't snap from (0,0,0)
		alignOri.CFrame = root.CFrame
	end
	clone.Parent = activePetsFolder	-- put the pet into the workspace
	if root:CanSetNetworkOwnership() then	-- give control of the pet's physics to the owning player's computer
		root:SetNetworkOwner(owner)	-- this keeps the pet moving smoothly on their screen instead of stuttering
	end	-- pets give no gameplay advantage, so letting the owner's client simulate them carries no real risk
	return self
end

-- figures out the CFrame (position + rotation) this pet should be at right now
function pet:getTargetCFrame(index, total, rootCFrame, t)
	local offset = getSlotOffset(index, total)	-- get this pet's slot position relative to the player
	-- a CFrame's LookVector points down its own -Z axis, so +Z in local
	-- space is always "backwards" no matter which way the player is facing
	-- multiplying the CFrame by the offset Vector3 directly gives us the
	-- world position in one step, since offset.Y is already 0 there's no
	-- need to wrap it in CFrame.new first
	local slotPos = rootCFrame * offset
	local x, z = slotPos.X, slotPos.Z
	local groundY = getGroundHeight(Vector3.new(x, rootCFrame.Position.Y, z))	-- check how high the ground is at that spot
	local y
	if self.floating then
		local bob = math.sin(t * config.bobSpeed * math.pi * 2 + self.bobOffset) * config.bobHeight	-- floating pets hover above the ground (or the player if no ground found) with a bob
		y = (groundY or rootCFrame.Position.Y) + self.hoverHeight + bob
	elseif groundY then
		-- this assumes Root is centered in the model rather than sitting at its 
		-- feet, so half its height lands the bottom of Root exactly on the ground,
		-- if a template's Root is positioned at the very bottom instead of the
		-- center, this would plant the pet half its height into the floor 
		y = groundY + self.root.Size.Y / 2
	else
		y = rootCFrame.Position.Y	-- fallback if no ground was found, just match the player's height
	end
	local look = rootCFrame.LookVector
	-- we zero out Y so the pet only turns left/right to match the player's
	-- facing, it should not pitch up or down just because the player's 
	-- camera/look direction tilts up or down.
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.001 then
		-- if the player looks almost straight up or down, X and Z both
		-- collapse toward 0 and CFrame.lookAt can't turn a near-zero vector 
		-- into a valid rotation falling back to a fixed direction avoids
		-- a broken CFrame for that one frame instead of detecting the edge
		-- case separately every time 
		flatLook = Vector3.new(0, 0, -1)
	end
	local position = Vector3.new(x, y, z)
	return CFrame.lookAt(position, position + flatLook.Unit)
end

-- called every frame to move this pet toward where it should be 
function pet:update(index, total, t)
	local character = self.owner.Character 
	local hrp = character and character:FindFirstChild("HumanoidRootPart") 
	if not hrp then
		return	-- player has no character right now, skip
	end
	local target = self:getTargetCFrame(index, total, hrp.CFrame, t)
	self.alignPos.Position = target.Position 
	self.alignOri.CFrame = target
end

-- instantly teleports the pet to its slot, used right after a player respawns 
function pet:snapTo(index, total, rootCFrame)
	local target = self:getTargetCFrame(index, total, rootCFrame, time())
	self.model:PivotTo(target)	-- actually move the model there
	self.alignPos.Position = target.Position	-- update the constraint target too 
	self.alignOri.CFrame = target
end

-- removes the pet from the game and cleans up
function pet:destroy()
	if self.model then
		self.model:Destroy()
	end
	-- table.clear wipes every key so nothing in this pet object (model, root,
	-- constraints) can still be referenced and accidentally used after the pet
	-- is destroyed, since the Instances themselves are already gone this stops 
	-- stale fields from pointing at destroyed objects
	table.clear(self) 
	-- removing the metatable means this table silently stops behaving like a 
	-- Pet, calling pet:update() on it afterward throws instead of running on
	-- dead data, which surfaces bugs immediately instead of failing quietly
	setmetatable(self, nil)
end

-- table that stores every player's list of equipped pets
-- shape: playerPets[player] = { pet1, pet2, pet3 }
local playerPets = {}

-- gets a player's pet list, making an empty one if they don't have one yet
local function getPetList(player)
	local list = playerPets[player]
	if not list then
		list = {}
		playerPets[player] = list
	end
	return list
end

-- finds the position in a player's pet list of a pet with a given template name
local function findPetIndex(list, templateName)
	for i, p in ipairs(list) do
		if p.templateName == templateName then
			return i
		end
	end
	return nil	-- not found
end

-- removes one specific pet from a player
local function unequipPet(player, templateName)
	local list = getPetList(player)
	local idx = findPetIndex(list, templateName)
	if not idx then
		return	-- they don't have this pet equipped
	end
	local p = table.remove(list, idx)
	p:destroy()
end

-- gives a player a new pet, as long as they are not already at the max
local function equipPet(player, templateName)
	local list = getPetList(player)
	if #list >= config.maxEquipped then
		return false	-- already have the max number of pets out
	end
	local template = petTemplates:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		warn("Pet template not found: " .. tostring(templateName))
		return false
	end
	local newPet = pet.new(player, template)
	if not newPet then
		return false	-- pet.new failed, probably a bad template
	end
	table.insert(list, newPet)
	return true
end

-- if the player already has this pet, remove it, otherwise give it to them
local function togglePet(player, templateName)
	local list = getPetList(player) 
	if findPetIndex(list, templateName) then
		unequipPet(player, templateName)
	else
		equipPet(player, templateName)
	end
end

--one single loop that runs every frame and updates every pet for every
-- player, keeping the cost at one scheduled callback no matter how many 
-- pets exist, if each pet instead connected its own Heartbeat in pet.new,
-- we would be paying for a separate connection per pet, and cleanup would
--depend on every single pet correctly disconnecting itself, one missed
-- disconnect would leak a connection forever
runService.Heartbeat:Connect(function()
	-- time() is used instead of the dt Heartbeat passes in because we need an
	-- absolute, ever-increasing clock for the bob sine wave, dt is just the gap
	-- since last frame and accumulating it ourselves would drift if frame rate
	-- changes, time() stays consistent regardless of framerate
	local t = time()
	for _, list in pairs(playerPets) do
		local total = #list
		for i, p in ipairs(list) do
			p:update(i, total, t)
		end
	end
end)

-- puts a single part into the Players collision group
local function setPartGroup(part)
	if part:IsA("BasePart") then
		part.CollisionGroup = playersCollisionGroup
	end
end

-- runs whenever a player's character spawns or respawns
local function onCharacterAdded(player, character)
	for _, desc in ipairs(character:GetDescendants()) do	--put every current part of the character into the Players group
		setPartGroup(desc)
	end
	character.DescendantAdded:Connect(setPartGroup)	-- also catch any parts added later, like accessories that load in 
	local hrp = character:WaitForChild("HumanoidRootPart", 10)	-- wait for the important part of the character to exist
	if not hrp then
		return	-- character never finished loading, give up
	end
	local list = playerPets[player]	-- the player's pets already exist from before, we just need to move them
	if not list then	-- to the new character instead of destroying and remaking them 
		return
	end
	local total = #list
	for i, p in ipairs(list) do
		p:snapTo(i, total, hrp.CFrame)	-- teleport pet to its slot near the new character
	end
end

-- runs once when a player joins the game
local function onPlayerAdded(player)
	playerPets[player] = {}	-- start them with an empty pet list
	player.CharacterAdded:Connect(function(character)	-- every time their character spawns, run our setup function
		onCharacterAdded(player, character)
	end)
	-- A player's character can already exist by the time this connects,
	-- most commonly because they joined before this script finished running
	-- PlayerAdded for them, which happens often in Studio play testing.
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

-- runs when a player leaves the game
local function onPlayerRemoving(player)
	local list = playerPets[player]
	if list then
		for _, p in ipairs(list) do	-- destroy every pet they had 
			p:destroy()
		end
	end
	playerPets[player] = nil	-- remove their data so nothing lingers 
end

-- hook up the player join/leave events
players.PlayerAdded:Connect(onPlayerAdded) 
players.PlayerRemoving:Connect(onPlayerRemoving) 

-- covers players who are already in the game when this script runs, same
-- join-order reasoning as above, not a script reload since scripts do not 
-- reload while a game is running
for _, player in ipairs(players:GetPlayers()) do
	onPlayerAdded(player)
end

-- folder in the workspace holding all the pedestal parts
local pedestalsFolder = workspace:WaitForChild("Pedestals")

-- gives the pedestal a prompt that equips or unequips a pet
local function setupPedestal(pedestal)
	if not pedestal:IsA("BasePart") then
		return	-- only works on actual parts
	end
	local petName = pedestal:GetAttribute("PetName")
	if type(petName) ~= "string" or petName == "" then
		warn("Pedestal " .. pedestal.Name .. " is missing a PetName attribute")
		return
	end
	if not petTemplates:FindFirstChild(petName) then	-- make sure the template this pedestal points to actually exists 
		warn("Pedestal " .. pedestal.Name .. " points to missing template " .. petName)
		return
	end
	local prompt = pedestal:FindFirstChildOfClass("ProximityPrompt")	-- use the existing prompt if there is one, otherwise make a new one 
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = pedestal
	end
	prompt.ActionText = "Equip / Unequip"	-- actionText is the verb on the button
	prompt.ObjectText = petName	-- objectText is the thing the verb acts on 
	prompt.HoldDuration = 0 
	prompt.MaxActivationDistance = 10 
	prompt.RequiresLineOfSight = false 
	prompt.Triggered:Connect(function(player) 	-- when a player uses the prompt, toggle their pet 
		togglePet(player, petName)
	end)
end

-- set up every pedestal that already exists
for _, child in ipairs(pedestalsFolder:GetChildren()) do
	setupPedestal(child)
end

-- in case more pedestals get added later while the game is running 
pedestalsFolder.ChildAdded:Connect(setupPedestal)
