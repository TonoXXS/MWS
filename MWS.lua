--[[
	Mini War v2.0.4 / Cyraa Hub v2.0.4
	Core, configuration, economy, building, collection, and market systems.

	This section is a behavior-preserving high-level reconstruction of source
	lines 1-2774 from MiniWar.deobfuscated.lua. The assembler concatenates the
	combat, progression, interface, and startup sections after it in the same
	lexical chunk, sharing the compatibility locals declared here.

	WARNING: loading this script downloads and executes the Obsidian UI
	dependencies below. No code in this repository was executed while this
	refactor was produced.
]]

-- ============================================================================
-- Application namespaces
-- ============================================================================

local MiniWar = {}
local Services = {}
local Config = {}
local State = getgenv()
local GameApi = {}
local Automation = {
	Economy = {},
	Buildings = {},
	Collection = {},
	Servers = {},
	Combat = {},
	Progression = {},
}
local UI = {}
local runtimeActive = true
local runtimeConnections = {}

local function trackRuntimeConnection(connection)
	if connection then
		table.insert(runtimeConnections, connection)
	end
	return connection
end

local function stopRuntimeConnections()
	if not runtimeActive then
		return
	end

	runtimeActive = false
	for _, connection in ipairs(runtimeConnections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(runtimeConnections)
end

MiniWar.Services = Services
MiniWar.Config = Config
MiniWar.State = State
MiniWar.GameApi = GameApi
MiniWar.Automation = Automation
MiniWar.UI = UI

-- ============================================================================
-- External UI dependencies and Roblox services
-- ============================================================================

local function loadRemoteModule(url, moduleName)
	local lastError

	for attempt = 1, 3 do
		local succeeded, result = pcall(function()
			local source = game:HttpGet(url)
			assert(type(source) == "string" and #source > 100, moduleName .. " returned an empty response")

			local chunk, compileError = loadstring(source)
			assert(chunk, compileError)

			local module = chunk()
			assert(type(module) == "table", moduleName .. " did not return a module")
			return module
		end)

		if succeeded then
			return result
		end

		lastError = result
		if attempt < 3 then
			task.wait(attempt)
		end
	end

	error(("Failed to load %s after 3 attempts: %s"):format(moduleName, tostring(lastError)))
end

local Library = loadRemoteModule(
	"https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua",
	"Obsidian Library"
)
local SaveManager = loadRemoteModule(
	"https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua",
	"Obsidian SaveManager"
)
local ThemeManager = loadRemoteModule(
	"https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/ThemeManager.lua",
	"Obsidian ThemeManager"
)

-- Obsidian currently evaluates Icons.GetAsset before its internal pcall. If
-- the icon endpoint transiently returns an empty chunk, Icons is nil and UI
-- construction aborts. Catch the whole method and provide an invisible icon
-- so the interface remains usable while the provider is unavailable.
local obsidianGetIcon = Library.GetIcon
function Library:GetIcon(iconName)
	if type(obsidianGetIcon) == "function" then
		local succeeded, icon = pcall(obsidianGetIcon, self, iconName)
		if succeeded and icon then
			return icon
		end
	end

	return {
		IconName = iconName,
		Url = "rbxassetid://0",
		ImageRectOffset = Vector2.zero,
		ImageRectSize = Vector2.zero,
	}
end

local Options, Toggles = Library.Options, Library.Toggles

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true
Library.Scheme.AccentColor = Color3.fromRGB(0, 255, 33)
Library:UpdateColorsUsingRegistry()

UI.Library = Library
UI.SaveManager = SaveManager
UI.ThemeManager = ThemeManager
UI.Options = Options
UI.Toggles = Toggles

local Players, ReplicatedStorage, RunService, TeleportService, HttpService, Workspace, UserInputService, CollectionService, VirtualUser, CoreGui =
	game:GetService("Players"),
	game:GetService("ReplicatedStorage"),
	game:GetService("RunService"),
	game:GetService("TeleportService"),
	game:GetService("HttpService"),
	game:GetService("Workspace"),
	game:GetService("UserInputService"),
	game:GetService("CollectionService"),
	game:GetService("VirtualUser"),
	game:GetService("CoreGui")

Services.Players = Players
Services.ReplicatedStorage = ReplicatedStorage
Services.RunService = RunService
Services.TeleportService = TeleportService
Services.HttpService = HttpService
Services.Workspace = Workspace
Services.UserInputService = UserInputService
Services.CollectionService = CollectionService
Services.VirtualUser = VirtualUser
Services.CoreGui = CoreGui

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

Services.LocalPlayer = LocalPlayer
Services.Character = Character
Services.HumanoidRootPart = HumanoidRootPart

trackRuntimeConnection(LocalPlayer.CharacterAdded:Connect(function(newCharacter)
	Character = newCharacter
	newCharacter:WaitForChild("HumanoidRootPart")
	HumanoidRootPart = newCharacter:FindFirstChild("HumanoidRootPart")

	Services.Character = Character
	Services.HumanoidRootPart = HumanoidRootPart
end))

-- ============================================================================
-- BridgeNet remotes and game-module discovery
-- ============================================================================

local BRIDGENET_PACKAGE_NAME = "ncxyzero_bridgenet2-fork@1.1.5"
local bridgeNetPackage = ReplicatedStorage:WaitForChild(BRIDGENET_PACKAGE_NAME)
local DataRemoteEvent = bridgeNetPackage:WaitForChild("dataRemoteEvent")
local BridgeNet = require(ReplicatedStorage.package._Index[BRIDGENET_PACKAGE_NAME]["bridgenet2-fork"])
local SellSingularItemBridge = BridgeNet.ClientBridge("SellSingularItem")

GameApi.DataRemoteEvent = DataRemoteEvent
GameApi.BridgeNet = BridgeNet
GameApi.SellSingularItemBridge = SellSingularItemBridge

-- The game lazily creates these bridges. Invoking the bridge factory once is
-- retained because later calls rely on the corresponding remotes existing.
local function primeBridge(bridgeName)
	pcall(function()
		ReplicatedStorage._GetBridgeFunction:InvokeServer(bridgeName)
	end)
end

primeBridge("BuyFromShop")
primeBridge("TryToBuySkill")
primeBridge("SendRocketsToPoint")
primeBridge("SendTroopsToPoint")
primeBridge("SellBuilding")
primeBridge("ClaimBPReward")
primeBridge("TryToCompleteQuest")
primeBridge("ClanGetResearch")
primeBridge("ClanGetResearchResult")
primeBridge("ClanStartResearch")
primeBridge("ClanResearchUpdate")

local ClientData
local ResourcesConfig
local BuildingsConfig
local GetBridge
local GetPlotModel
local Grid
local Objects
local SkillsConfig
local ClanUpgradeTreeConfig
local GetSkillsData
local QuestsConfig

local function loadGameModules()
	pcall(function()
		ClientData = require(ReplicatedStorage.client.modules.ClientData)
	end)
	pcall(function()
		ResourcesConfig = require(ReplicatedStorage.shared.config.ResourcesConfig)
	end)
	pcall(function()
		BuildingsConfig = require(ReplicatedStorage.shared.config.BuildingsConfig)
	end)
	pcall(function()
		GetBridge = require(ReplicatedStorage.util.GetBridge)
	end)
	pcall(function()
		GetPlotModel = require(ReplicatedStorage.util.GetPlotModel)
	end)
	pcall(function()
		Grid = require(ReplicatedStorage.shared.modules.Grid)
	end)
	pcall(function()
		Objects = ReplicatedStorage.shared.model.Objects
	end)
	pcall(function()
		SkillsConfig = require(ReplicatedStorage.shared.config.SkillsConfig)
	end)
	pcall(function()
		ClanUpgradeTreeConfig = require(ReplicatedStorage.shared.config.ClanUpgradeTreeConfig)
	end)
	pcall(function()
		GetSkillsData = require(ReplicatedStorage.util.getSkillsData)
	end)
	pcall(function()
		QuestsConfig = require(ReplicatedStorage.shared.config.QuestsConfig)
	end)

	GameApi.ClientData = ClientData
	GameApi.ResourcesConfig = ResourcesConfig
	GameApi.BuildingsConfig = BuildingsConfig
	GameApi.GetBridge = GetBridge
	GameApi.GetPlotModel = GetPlotModel
	GameApi.Grid = Grid
	GameApi.Objects = Objects
	GameApi.SkillsConfig = SkillsConfig
	GameApi.ClanUpgradeTreeConfig = ClanUpgradeTreeConfig
	GameApi.GetSkillsData = GetSkillsData
	GameApi.QuestsConfig = QuestsConfig
end

task.spawn(loadGameModules)

local bridgeCache = {}

local function getCachedBridge(bridgeName)
	local cachedBridge = bridgeCache[bridgeName]
	if cachedBridge then
		return cachedBridge
	end

	local bridge
	if GetBridge then
		pcall(function()
			bridge = GetBridge(bridgeName)
		end)
	end

	if not bridge then
		pcall(function()
			bridge = BridgeNet.ClientBridge(bridgeName)
		end)
	end

	if bridge then
		bridgeCache[bridgeName] = bridge
	end
	return bridge
end

local function fireBridge(bridgeName, payload)
	local bridge = getCachedBridge(bridgeName)
	if not bridge then
		primeBridge(bridgeName)
		bridge = getCachedBridge(bridgeName)
	end
	if not bridge then
		return false
	end

	local fireMethod
	if type(bridge.Fire) == "function" then
		fireMethod = bridge.Fire
	elseif type(bridge.FireServer) == "function" then
		fireMethod = bridge.FireServer
	else
		return false
	end

	local succeeded = pcall(function()
		if payload == nil then
			fireMethod(bridge)
		else
			fireMethod(bridge, payload)
		end
	end)

	return succeeded
end

local function fireDataRemote(payload)
	pcall(function()
		DataRemoteEvent:FireServer(payload)
	end)
end

local latestClanResearchData

local function connectClanResearchUpdates()
	for _ = 1, 10 do
		if not runtimeActive then
			return
		end

		local resultBridge = getCachedBridge("ClanGetResearchResult")
		if resultBridge and type(resultBridge.Connect) == "function" then
			local succeeded, connection = pcall(function()
				return resultBridge:Connect(function(researchData)
					if type(researchData) == "table" then
						latestClanResearchData = researchData
					end
				end)
			end)
			if succeeded and connection then
				trackRuntimeConnection(connection)

				local updateBridge = getCachedBridge("ClanResearchUpdate")
				if updateBridge and type(updateBridge.Connect) == "function" then
					local updateConnected, updateConnection = pcall(function()
						return updateBridge:Connect(function()
							if runtimeActive then
								fireBridge("ClanGetResearch")
							end
						end)
					end)
					if updateConnected and updateConnection then
						trackRuntimeConnection(updateConnection)
					end
				end

				fireBridge("ClanGetResearch")
				return
			end
		end

		primeBridge("ClanGetResearchResult")
		primeBridge("ClanResearchUpdate")
		task.wait(0.5)
	end
end

task.spawn(connectClanResearchUpdates)

local function teleportToCFrame(targetCFrame)
	local character = LocalPlayer.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		rootPart.CFrame = targetCFrame
	end
end

GameApi.loadGameModules = loadGameModules
GameApi.getCachedBridge = getCachedBridge
GameApi.fireBridge = fireBridge
GameApi.fireDataRemote = fireDataRemote
GameApi.teleportToCFrame = teleportToCFrame

-- The quest catalog is populated before runtime defaults, matching the
-- original top-level initialization order.
local questDifficultyByName = {
	AllyPlayer = "easy",
	Kill100Troops = "easy",
	Place5Roads = "easy",
	Place5Rocks = "easy",
	BaseConquer = "easy",
	CropHarvest = "easy",
	BuildHouses = "easy",
	Build3Farms = "easy",
	PlaceFountain = "easy",
	PlaceBench = "easy",
	SellWood = "easy",
	SellGold = "easy",
	SellCarrots = "easy",
	SellBuilding = "easy",
	TalkToBlackMarket = "easy",
	SellIron = "easy",
	SellWheat = "easy",
	Place15Decorations = "easy",
	JoinClan = "easy",
	ConquerPlayerBase = "medium",
	ConquerGarrison = "medium",
	PlaceSalutingStatue = "medium",
	ConquerLaboratory = "medium",
	EarnMillion = "medium",
	Play30Minutes = "medium",
	KillTroopsRocket = "medium",
	ExperienceWeather = "medium",
	ConquerOilRig = "medium",
	RollGeneral = "medium",
	Conquer2Laboratories = "hard",
	Kill1000Troops = "hard",
	CropHarvest100k = "hard",
	SendAllyHelicopter = "hard",
	ConquerCity = "hard",
	StayAllied1Hour = "hard",
	ConquerCity5Mins = "hard",
	CaptureKOHBase = "hard",
	BuyFromBlackMarket = "hard",
	SellDataCube = "hard",
	SellStableUran = "hard",
	RollLegendaryGeneral = "hard",
	Kill10kTroops = "insane",
	Harvest250kCrops = "insane",
	DefeatWeatherBoss = "insane",
}

local questNames = {}
for questName in pairs(questDifficultyByName) do
	table.insert(questNames, questName)
end

-- ============================================================================
-- Runtime settings
-- ============================================================================

-- The original script overwrites these values at startup. Assignments stay in
-- source order so persisted configuration can subsequently replace them.
State.autoCollectRunning = false
State.autoCollectInterval = 1
State.selectedCollectItems = {}
State.autoSellRunning = false
State.autoSellInterval = 10
State.autoSellMinPercent = 0
State.selectedSellItems = {}
State.autoSellByMarketRunning = false
State.autoSellMarketCondition = "Price Up"
State.marketBonusPercent = 0
State.selectedHouseItem = {}
State.selectedMilItem = {}
State.selectedFarmItem = {}
State.selectedSpecialItem = {}
State.selectedDecorItem = {}
State.selectedBlackMarketItem = {}
State.autoClaimQuestRunning = false
State.selectedQuestDifficulty = {}
State.autoUpgradeStatsRunning = false
State.selectedUpgradeStat = {}
State.selectedClanUpgrades = {}
State.autoAttackRunning = false
State.autoAttackDelay = 5
State.autoAttackSwitchTime = 900
State.attackMode = "Any"
State.attackPriority1 = "Laboratory1"
State.attackPriority2 = "Laboratory2"
State.attackPriority3 = "Laboratory3"
State.attackPriority4 = "Laboratory4"
State.attackPriority5 = "Laboratory5"
State.attackPriority6 = "Laboratory6"
State.attackArmyIndex1 = 1
State.attackArmyIndex2 = 1
State.attackArmyIndex3 = 1
State.attackArmyIndex4 = 1
State.attackArmyIndex5 = 1
State.attackArmyIndex6 = 1
State.raidPriority1 = "KingOfTheHillBase"
State.raidPriority2 = "ToxicKingOfTheHillBase"
State.raidPriority3 = "RiotBase"
State.raidPriority4 = "CargoBase"
State.raidPriority5 = "BeastBreach"
State.raidPriority6 = "MeteorCargo"
State.raidPriority7 = "MeteorGems"
State.raidPriority8 = "Invaded"
State.raidPriority9 = "Hacker"
State.raidArmyIndex1 = 1
State.raidArmyIndex2 = 1
State.raidArmyIndex3 = 1
State.raidArmyIndex4 = 1
State.raidArmyIndex5 = 1
State.raidArmyIndex6 = 1
State.raidArmyIndex7 = 1
State.raidArmyIndex8 = 1
State.raidArmyIndex9 = 1
State.autoBuyRunning = false
State.autoBuyAllRunning = false
State.autoBuyDelay = 0.3
State.autoPlaceBuildingRunning = false
State.autoPlaceInterval = 1
State.selectedSellBuildingItem = {}
State.autoSellBuildingRunning = false
State.autoSellBuildingDelay = 0.5
State.miscFlyEnabled = false
State.miscFlySpeed = 50
State.miscInfJumpEnabled = false
State.miscNoClipEnabled = false
State.miscAntiAfkEnabled = false
State.MISC_FLYING = false
State.miscFlyKeyDown = nil
State.miscFlyKeyUp = nil
State.miscFlyHB = nil
State.miscFlyDied = nil
State.miscFlyGyro = nil
State.miscFlyVel = nil
State.miscInfJumpConn = nil
State.perfSettingsEnabled = false
State.perfNpcCullingDistance = 150
State.perfLowPerformanceMode = false
State.autoHopEnabled = false
State.autoHopInterval = 5
State.autoReconnectEnabled = false
State.disableNotifications = false
State.showMarketMenu = false
State.autoReExecEnabled = false
State.weatherHopRunning = false
State.weatherHopTarget = "Storm"
State.BlockNotif = false
State._perfSnapshot = nil
State._perfDescConn = nil
State.masterArmyDeploy = false
State.masterArmyRockets = false
State.masterArmyIndex = 1
State.masterArmyTarget = nil
State.autoBPClaimRunning = false
State.autoBPTrack = "Free"
State.autoBPCoinsRunning = false
State._noClipCollisionSnapshot = nil
State._fogSnapshot = nil

local function restoreNoClipCollisions()
	local snapshot = State._noClipCollisionSnapshot
	if not snapshot then
		return
	end

	for part, canCollide in pairs(snapshot) do
		pcall(function()
			part.CanCollide = canCollide
		end)
	end
	State._noClipCollisionSnapshot = nil
end

local function setNoClipEnabled(enabled)
	State.miscNoClipEnabled = enabled
	if not enabled then
		restoreNoClipCollisions()
	end
end

local function enforceNoClip()
	if not State.miscNoClipEnabled then
		return
	end

	local character = LocalPlayer.Character
	if not character then
		return
	end

	local snapshot = State._noClipCollisionSnapshot
	if not snapshot then
		snapshot = {}
		State._noClipCollisionSnapshot = snapshot
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if snapshot[descendant] == nil then
				snapshot[descendant] = descendant.CanCollide
			end
			descendant.CanCollide = false
		end
	end
end

local function setFogRemoved(enabled)
	local lighting = game:GetService("Lighting")

	if enabled then
		if not State._fogSnapshot then
			local atmosphereStates = {}
			for _, descendant in ipairs(lighting:GetDescendants()) do
				if descendant:IsA("Atmosphere") then
					table.insert(atmosphereStates, {
						instance = descendant,
						density = descendant.Density,
						haze = descendant.Haze,
						glare = descendant.Glare,
					})
				end
			end

			State._fogSnapshot = {
				fogEnd = lighting.FogEnd,
				atmospheres = atmosphereStates,
			}
		end

		lighting.FogEnd = 9000000000
		for _, savedAtmosphere in ipairs(State._fogSnapshot.atmospheres) do
			pcall(function()
				savedAtmosphere.instance.Density = 0
				savedAtmosphere.instance.Haze = 0
				savedAtmosphere.instance.Glare = 0
			end)
		end
		return
	end

	local snapshot = State._fogSnapshot
	if not snapshot then
		return
	end

	lighting.FogEnd = snapshot.fogEnd
	for _, savedAtmosphere in ipairs(snapshot.atmospheres) do
		pcall(function()
			savedAtmosphere.instance.Density = savedAtmosphere.density
			savedAtmosphere.instance.Haze = savedAtmosphere.haze
			savedAtmosphere.instance.Glare = savedAtmosphere.glare
		end)
	end
	State._fogSnapshot = nil
end

-- ============================================================================
-- Static catalogs and configuration
-- ============================================================================

local autoRemoveCollectItemsEnabled = false
local autoRemoveCollectItemNames = {
	"Wheat",
	"Books",
	"Iron",
	"Cement",
	"Flour",
	"Coal",
	"Oil",
	"Gold",
	"Stable Uran",
	"Dark Matter",
	"Corn",
	"UranOre",
	"Research",
	"QuantumCore",
	"AlienEssence",
	"Carrots",
	"Diamonds",
	"Robo Head",
	"Coin Bag",
	"Wood",
	"Data Cube",
	"Antimatter",
	"Supernova",
	"GamaRay",
}

local collectExcludedBuildingNames = {
	ClansHub = true,
	GeneralResidence = true,
	ShoppingCenter = true,
	CommandCenter = true,
	BuilderControl = true,
}

local function removeWorldCollectItems()
	for _, descendant in pairs(Workspace:GetDescendants()) do
		if table.find(autoRemoveCollectItemNames, descendant.Name) then
			descendant:Destroy()
		end
	end
end

local function getUpgradeNames()
	local names = {}
	local upgradeTree = Workspace:FindFirstChild("UpgradeTree")
	local upgrades = upgradeTree and upgradeTree:FindFirstChild("Upgrades")

	if upgrades then
		for _, upgrade in ipairs(upgrades:GetChildren()) do
			table.insert(names, upgrade.Name)
		end
	end

	if #names == 0 then
		names = {
			"Start",
			"Alliance1",
			"ArmyTraining",
			"FastWorkers",
			"OfficerTraining",
			"Bandage",
			"Medkit",
			"Juggernaut",
			"Boots",
			"Chocolate",
			"EnergyDrink",
			"EliteTraining",
			"Mech",
			"AmmoCrates",
			"HeavyCannon",
			"ExplosiveAmmo",
			"HeavyArmor",
			"SteelPlating",
			"TitanArmor",
			"ImprovedEngine",
			"RocketCooldown1",
			"RocketCooldown2",
			"MoreFuel",
			"NuclearFuel",
			"Radar",
			"Satellite",
			"ArmySize1",
			"ArmySize2",
			"ArmySize3",
			"RocketLimit1",
			"RocketLimit2",
			"Binoculars",
			"Noctovisor",
			"Radio",
			"MassProduction",
			"SmartFactories",
			"Automation",
			"BiggerCrates1",
			"BiggerCrates2",
			"LogisticDepot",
			"Warehouse",
			"Financier",
			"Trader",
			"Area51",
			"LuckyRestock1",
			"LuckyRestock2",
			"LuckyRestock3",
			"Alliance2",
			"Researcher",
			"ResearchTeam",
			"Conqueror",
			"Emperor",
			"Laboratory",
			"ResearchFacility",
			"Speed1",
			"Speed2",
			"Civilians1",
			"Civilians2",
			"Civilians3",
			"Population",
			"Builders1",
			"Builders2",
			"Builders3",
			"ArmyControl",
			"AdditionalArmy1",
			"AdditionalArmy2",
			"Spider",
			"AirFortress",
			"Antimatter",
			"Quantum",
			"PassiveEarnings",
			"AdditionalQuest",
			"AdditionalHelipad",
			"LuckyTrader",
			"CargoFortune",
			"RiotBaseTraining",
			"RebellionResistance",
			"CloneMastery",
			"ClanSupport",
			"ArmySize4",
			"RocketDamage1",
			"RocketDamage2",
			"RocketDamage3",
			"RocketRadius",
			"HealRadius",
			"IncreasedHealing",
			"OrbitalRecon",
			"AutoBuy",
			"Supernova",
			"AdvancedAutomation",
			"StatueRadius",
			"FasterRestock",
			"RapidLogistics",
			"GENERALS",
			"ExtraGeneralSlot",
			"GeneralLuck1",
			"GeneralLuck2",
			"RicherQuests",
			"AdditionalQuest2",
			"FasterConquer",
			"CommandCenter",
			"AutoConquer",
			"BiggerPlot",
			"HighAchievers",
			"Top Performers",
			"+1MaxSuperWorker",
			"Builders4",
			"ConstructionControl",
			"BuilderControl",
		}
	end

	table.sort(names)
	return names
end

local upgradeNames = getUpgradeNames()

local houseItemNames = {
	"ApartmentBuilding",
	"FarmHouse",
	"SmallHouse",
	"House",
	"Villa",
	"ModernBlock",
	"Skyscraper",
	"HelixTower",
	"TheManor",
	"Hotel",
	"Giant Skyscraper",
	"TwinTurboTower",
	"GrandHotel",
}

local militaryItemNames = {
	"BorderTower",
	"Barracks",
	"SniperTower",
	"Barracks2",
	"TankBase",
	"HeliPad",
	"SpecialForce",
	"MissleHangar",
	"Hangar",
	"BigTankBase",
	"BigHangar",
	"MissleLauncher",
	"MilitaryHospital",
	"GeneralsBase",
	"Air Base",
	"Artillery Depot",
	"Rocket Bunker",
	"MechStation",
	"SpiderBase",
	"BioRocket",
	"AirFortress",
	"Pentagon",
	"Sci-Fi Tank Hangar",
	"Nuclear Warhead",
	"BlackHawkSpawner",
	"HomarSpawner",
	"RocketTankSpawner",
	"HealerSpawner",
	"PlasmaRocket",
	"PlasmaHangar",
}

local farmItemNames = {
	"FarmWheat",
	"FarmCorn",
	"WoodPlant",
	"Windmill",
	"FarmCarrots",
	"Library",
	"OilAmerica",
	"CaveIron",
	"CementPlant",
	"CaveGold",
	"Bank",
	"Labs",
	"CaveDiamond",
	"CaveUran",
	"NuclearReactor",
	"Data Center",
	"Blackhole Generator",
	"Area51Lab",
	"AntimatterReactor",
	"CaveCoal",
	"TreeFarm",
	"QuantumCoreGenerator",
	"Mega Drill",
	"Robo Lab",
	"SupernovaAccelerator",
	"GammaRayGenerator",
}

local specialItemNames = {
	"Workshop",
	"Storage Center",
	"Worker Statue",
	"Soldier Statue",
	"Worker Statue V2",
	"Vault",
	"GeneralResidence",
	"ShoppingCenter",
	"CommandCenter",
	"BuilderControl",
	"ClansHub",
}

local decorItemNames = {
	"Grass",
	"Road2",
	"Rocks",
	"Road1",
	"Road3",
	"StreetLamp",
	"PineTree",
	"Lamp",
	"Tree",
	"Flowers",
	"Bench",
	"SalutingStatue",
	"Statue",
	"Fountain",
	"TrafficLights",
	"RoadWithCar",
	"Mech Statue",
	"Roundabout",
	"T-INTERSECTION",
	"CROSS INTERSECTION",
	"FullParking",
	"EmptyParking",
	"Wall",
	"Water",
	"Sidewalk",
}

local blackMarketItemNames = {
	"Flag Pole",
	"Elite Base",
	"Research Booster",
	"Gem Mine",
	"Rocket Pad",
	"Advance Heli Pad",
	"Clone Facility",
	"Elite Tank Base",
	"Transport Pad",
	"Fireworks Barrel",
	"Ferris Wheel",
	"Player Statue",
	"ConstructionSpecial",
	"CloneFacilityV2",
	"Builders Hub",
	"UpgradedWorkshop",
}

local blackMarketItemIdByName = {
	["Flag Pole"] = "FlagPole",
	["Elite Base"] = "SpecialForceV2",
	["Research Booster"] = "ResearchLab",
	["Gem Mine"] = "GemMine",
	["Rocket Pad"] = "RocketPad",
	["Advance Heli Pad"] = "AdvancedHeliPad",
	["Clone Facility"] = "CloneFacility",
	["Elite Tank Base"] = "EliteTankBase",
	["Transport Pad"] = "TransportPad",
	["Fireworks Barrel"] = "FireworksBarrel",
	["Ferris Wheel"] = "FerrisWheel",
	["Player Statue"] = "PlayerStatue",
	ConstructionSpecial = "ConstructionSpecial",
	CloneFacilityV2 = "CloneFacilityV2",
	["Builders Hub"] = "BuildersHub",
	UpgradedWorkshop = "UpgradedWorkshop",
}

local sellableResourceNames = {
	"Wheat",
	"Books",
	"Iron",
	"Cement",
	"Flour",
	"Coal",
	"Oil",
	"Gold",
	"Stable Uran",
	"Dark Matter",
	"Corn",
	"UranOre",
	"Research",
	"QuantumCore",
	"AlienEssence",
	"Carrots",
	"Diamonds",
	"Robo Head",
	"Coin Bag",
	"Wood",
	"Data Cube",
	"Antimatter",
	"Supernova",
	"GammaRay",
}

local regularBuildingItemNames = {}
for _, categoryItems in ipairs({
	houseItemNames,
	militaryItemNames,
	farmItemNames,
	specialItemNames,
	decorItemNames,
}) do
	for _, itemName in ipairs(categoryItems) do
		table.insert(regularBuildingItemNames, itemName)
	end
end

local attackPriorityNames = {
	"Skip",
	"Laboratory1",
	"Laboratory2",
	"Laboratory3",
	"Laboratory4",
	"Laboratory5",
	"Laboratory6",
	"Bandit1",
	"Bandit2",
	"Bandit3",
	"Bandit4",
	"Bandit5",
	"Bandit6",
	"Town",
	"Wooden1",
	"Wooden2",
	"Wooden3",
	"Wooden4",
	"Wooden5",
	"Wooden6",
	"MilitaryBase1",
	"MilitaryBase2",
	"MilitaryBase3",
	"MilitaryBase4",
	"MilitaryBase5",
	"MilitaryBase6",
	"WaterRig1",
	"WaterRig2",
	"WaterRig3",
	"WaterRig4",
	"WaterRig5",
	"WaterRig6",
	"RaidEvent",
}

local raidPriorityNames = {
	"Skip",
	"KingOfTheHillBase",
	"ToxicKingOfTheHillBase",
	"RiotBase",
	"CargoBase",
	"MeteorCargo",
	"MeteorGems",
	"BeastBreach",
	"Invaded",
	"Hacker",
}

local kingOfHillLocations = {
	{ name = "KoH Location 1", x = -370.9, y = 6.88, z = -212.4 },
	{ name = "KoH Location 2", x = 71.5, y = 6.78, z = -356.5 },
	{ name = "KoH Location 3", x = 287.5, y = 6.78, z = -139.5 },
	{ name = "KoH Location 4", x = 281.5, y = 6.78, z = 158.5 },
	{ name = "KoH Location 5", x = -317.5, y = 6.78, z = 180.5 },
}

local shopEntryByDisplayName = {
	ApartmentBuilding = { item = "ApartmentBuilding", shop = "House" },
	FarmHouse = { item = "FarmHouse", shop = "House" },
	SmallHouse = { item = "SmallHouse", shop = "House" },
	House = { item = "House", shop = "House" },
	Villa = { item = "Villa", shop = "House" },
	ModernBlock = { item = "ModernBlock", shop = "House" },
	Skyscraper = { item = "Skyscraper", shop = "House" },
	HelixTower = { item = "HelixTower", shop = "House" },
	TheManor = { item = "TheManor", shop = "House" },
	Hotel = { item = "Hotel", shop = "House" },
	["Giant Skyscraper"] = { item = "Giant Skyscraper", shop = "House" },
	TwinTurboTower = { item = "TwinTurboTower", shop = "House" },
	GrandHotel = { item = "GrandHotel", shop = "House" },
	BorderTower = { item = "BorderTower", shop = "Military" },
	Barracks = { item = "Barracks", shop = "Military" },
	SniperTower = { item = "SniperTower", shop = "Military" },
	Barracks2 = { item = "Barracks2", shop = "Military" },
	TankBase = { item = "TankBase", shop = "Military" },
	HeliPad = { item = "HeliPad", shop = "Military" },
	SpecialForce = { item = "SpecialForce", shop = "Military" },
	MissleHangar = { item = "MissleHangar", shop = "Military" },
	Hangar = { item = "Hangar", shop = "Military" },
	BigTankBase = { item = "BigTankBase", shop = "Military" },
	BigHangar = { item = "BigHangar", shop = "Military" },
	MissleLauncher = { item = "MissleLauncher", shop = "Military" },
	MilitaryHospital = { item = "MilitaryHospital", shop = "Military" },
	GeneralsBase = { item = "GeneralsBase", shop = "Military" },
	["Air Base"] = { item = "Air Base", shop = "Military" },
	["Artillery Depot"] = { item = "Artillery Depot", shop = "Military" },
	["Rocket Bunker"] = { item = "Rocket Bunker", shop = "Military" },
	MechStation = { item = "MechStation", shop = "Military" },
	SpiderBase = { item = "SpiderBase", shop = "Military" },
	BioRocket = { item = "BioRocket", shop = "Military" },
	AirFortress = { item = "AirFortress", shop = "Military" },
	Pentagon = { item = "Pentagon", shop = "Military" },
	["Sci-Fi Tank Hangar"] = { item = "SciFiTankHangar", shop = "Military" },
	["Nuclear Warhead"] = { item = "RedRocket", shop = "Military" },
	BlackHawkSpawner = { item = "BlackHawkSpawner", shop = "Military" },
	HomarSpawner = { item = "HomarSpawner", shop = "Military" },
	RocketTankSpawner = { item = "RocketTankSpawner", shop = "Military" },
	HealerSpawner = { item = "HealerSpawner", shop = "Military" },
	PlasmaRocket = { item = "PlasmaRocket", shop = "Military" },
	PlasmaHangar = { item = "PlasmaHangar", shop = "Military" },
	FarmWheat = { item = "FarmWheat", shop = "Farm" },
	FarmCorn = { item = "FarmCorn", shop = "Farm" },
	WoodPlant = { item = "WoodPlant", shop = "Farm" },
	Windmill = { item = "Windmill", shop = "Farm" },
	FarmCarrots = { item = "FarmCarrots", shop = "Farm" },
	Library = { item = "Library", shop = "Farm" },
	OilAmerica = { item = "OilAmerica", shop = "Farm" },
	CaveIron = { item = "CaveIron", shop = "Farm" },
	CementPlant = { item = "CementPlant", shop = "Farm" },
	CaveGold = { item = "CaveGold", shop = "Farm" },
	Bank = { item = "Bank", shop = "Farm" },
	Labs = { item = "Labs", shop = "Farm" },
	CaveDiamond = { item = "CaveDiamond", shop = "Farm" },
	CaveUran = { item = "CaveUran", shop = "Farm" },
	NuclearReactor = { item = "NuclearReactor", shop = "Farm" },
	["Data Center"] = { item = "Data Center", shop = "Farm" },
	["Blackhole Generator"] = { item = "Blackhole Generator", shop = "Farm" },
	Area51Lab = { item = "Area51Lab", shop = "Farm" },
	AntimatterReactor = { item = "AntimatterReactor", shop = "Farm" },
	CaveCoal = { item = "CaveCoal", shop = "Farm" },
	TreeFarm = { item = "TreeFarm", shop = "Farm" },
	QuantumCoreGenerator = { item = "QuantumCoreGenerator", shop = "Farm" },
	SupernovaAccelerator = { item = "SupernovaAccelerator", shop = "Farm" },
	GammaRayGenerator = { item = "GammaRayGenerator", shop = "Farm" },
	["Mega Drill"] = { item = "Mega Drill", shop = "Farm" },
	["Robo Lab"] = { item = "RoboLab", shop = "Farm" },
	Workshop = { item = "Workshop", shop = "Decor" },
	["Storage Center"] = { item = "Storage Center", shop = "Decor" },
	["Worker Statue"] = { item = "Worker Statue", shop = "Decor" },
	["Soldier Statue"] = { item = "Soldier Statue", shop = "Decor" },
	Grass = { item = "Grass", shop = "Decor" },
	Road2 = { item = "Road2", shop = "Decor" },
	Rocks = { item = "Rocks", shop = "Decor" },
	Road1 = { item = "Road1", shop = "Decor" },
	Road3 = { item = "Road3", shop = "Decor" },
	StreetLamp = { item = "StreetLamp", shop = "Decor" },
	PineTree = { item = "PineTree", shop = "Decor" },
	Lamp = { item = "Lamp", shop = "Decor" },
	Tree = { item = "Tree", shop = "Decor" },
	Flowers = { item = "Flowers", shop = "Decor" },
	Bench = { item = "Bench", shop = "Decor" },
	SalutingStatue = { item = "SalutingStatue", shop = "Decor" },
	Statue = { item = "Statue", shop = "Decor" },
	Fountain = { item = "Fountain", shop = "Decor" },
	ClansHub = { item = "ClansHub", shop = "Decor" },
	["Worker Statue V2"] = { item = "BetterWorkerStatue", shop = "Decor" },
	["Mech Statue"] = { item = "MechStatue", shop = "Decor" },
	Vault = { item = "Vault", shop = "Decor" },
	TrafficLights = { item = "TrafficLights", shop = "Decor" },
	RoadWithCar = { item = "RoadWithCar", shop = "Decor" },
	Roundabout = { item = "Roundabout", shop = "Decor" },
	["T-INTERSECTION"] = { item = "T-INTERSECTION", shop = "Decor" },
	["CROSS INTERSECTION"] = { item = "CROSS INTERSECTION", shop = "Decor" },
	FullParking = { item = "FullParking", shop = "Decor" },
	EmptyParking = { item = "EmptyParking", shop = "Decor" },
	Wall = { item = "Wall", shop = "Decor" },
	Water = { item = "Water", shop = "Decor" },
	Sidewalk = { item = "Sidewalk", shop = "Decor" },
	GeneralResidence = { item = "GeneralResidence", shop = "Decor" },
	ShoppingCenter = { item = "ShoppingCenter", shop = "Decor" },
	CommandCenter = { item = "CommandCenter", shop = "Decor" },
	BuilderControl = { item = "BuilderControl", shop = "Decor" },
}

local unsellableToolNames = {
	Hammer = true,
}

Config.QuestDifficultyByName = questDifficultyByName
Config.QuestNames = questNames
Config.UpgradeNames = upgradeNames
Config.HouseItemNames = houseItemNames
Config.MilitaryItemNames = militaryItemNames
Config.FarmItemNames = farmItemNames
Config.SpecialItemNames = specialItemNames
Config.DecorItemNames = decorItemNames
Config.BlackMarketItemNames = blackMarketItemNames
Config.BlackMarketItemIdByName = blackMarketItemIdByName
Config.SellableResourceNames = sellableResourceNames
Config.RegularBuildingItemNames = regularBuildingItemNames
Config.AttackPriorityNames = attackPriorityNames
Config.RaidPriorityNames = raidPriorityNames
Config.KingOfHillLocations = kingOfHillLocations
Config.ShopEntryByDisplayName = shopEntryByDisplayName
Config.AutoRemoveCollectItemNames = autoRemoveCollectItemNames
Config.CollectExcludedBuildingNames = collectExcludedBuildingNames
Config.UnsellableToolNames = unsellableToolNames

-- ============================================================================
-- Shared collection and selection helpers
-- ============================================================================

local function applyPerformanceSettings()
	local cullingDistance = State.perfNpcCullingDistance or 150
	local lowPerformanceMode = State.perfLowPerformanceMode or false

	fireDataRemote({ { value = cullingDistance, key = "NPC Culling Distance", attribute = false }, "\r" })
	task.wait(0.1)
	fireDataRemote({ { value = lowPerformanceMode, key = "Low Performance Mode", attribute = false }, "\r" })
end

-- Obsidian multiselect values can be represented either as
-- `{ Name = true }` maps or as ordinary string arrays.
local function normalizeSelection(selection)
	local normalized = {}

	if type(selection) == "table" then
		local isBooleanMap = false
		for key, value in pairs(selection) do
			if type(key) == "string" and value == true then
				isBooleanMap = true
				break
			end
		end

		if isBooleanMap then
			for key, value in pairs(selection) do
				if type(key) == "string" and value == true then
					table.insert(normalized, key)
				end
			end
		else
			for _, value in ipairs(selection) do
				table.insert(normalized, value)
			end
		end
	elseif type(selection) == "string" then
		table.insert(normalized, selection)
	end

	return normalized
end

GameApi.applyPerformanceSettings = applyPerformanceSettings
GameApi.normalizeSelection = normalizeSelection
Automation.Collection.removeWorldCollectItems = removeWorldCollectItems

-- ============================================================================
-- Shop purchasing and building sales
-- ============================================================================

local function getPlayerProducerState()
	if not ClientData or not ClientData.playerProducer then
		return nil
	end

	local succeeded, producerState = pcall(function()
		return ClientData.playerProducer:getState()
	end)
	if not succeeded or type(producerState) ~= "table" then
		return nil
	end

	return producerState.player
end

local function buyShopEntry(itemId, shopName)
	local payload = {
		item = itemId,
		shop = shopName,
	}

	if fireBridge("BuyFromShop", payload) then
		return
	end

	primeBridge("BuyFromShop")
	task.wait(0.1)
	fireBridge("BuyFromShop", {
		item = itemId,
		shop = shopName,
	})
end

local function buySelectedItems(selectedItems)
	if type(selectedItems) ~= "table" or not next(selectedItems) then
		return
	end

	local purchaseDelay = State.autoBuyDelay or 0.3

	-- Obsidian's multiselect uses item names as keys, so this deliberately
	-- iterates keys rather than array values.
	for itemName in pairs(selectedItems) do
		if type(itemName) == "string" then
			local blackMarketItemId = blackMarketItemIdByName[itemName]
			if blackMarketItemId then
				buyShopEntry(blackMarketItemId, "BlackMarket")
			else
				local shopEntry = shopEntryByDisplayName[itemName]
				if shopEntry then
					buyShopEntry(shopEntry.item, shopEntry.shop)
				end
			end

			task.wait(purchaseDelay)
		end
	end
end

local function buyAllAvailableItems()
	local purchaseDelay = State.autoBuyDelay or 0.3
	local shopNames = { "House", "Military", "Farm", "Decor" }

	for _, shopName in ipairs(shopNames) do
		local playerProducerState = getPlayerProducerState()
		local shopStocks = playerProducerState and playerProducerState.shopsStock
		local stock = (shopStocks and shopStocks[shopName] and shopStocks[shopName].stock) or {}

		for itemId, amount in pairs(stock) do
			if amount and amount > 0 then
				buyShopEntry(itemId, shopName)
				task.wait(purchaseDelay)
			end
		end
	end

	for _, displayName in ipairs(blackMarketItemNames) do
		local itemId = blackMarketItemIdByName[displayName]
		if itemId then
			buyShopEntry(itemId, "BlackMarket")
			task.wait(purchaseDelay)
		end
	end
end

local function sellBuilding(building)
	primeBridge("SellBuilding")
	task.wait(0.1)
	pcall(function()
		DataRemoteEvent:FireServer({ building, "O" })
	end)
end

local function sellSelectedBuildings()
	local selectedBuildings = State.selectedSellBuildingItem
	if type(selectedBuildings) ~= "table" or #selectedBuildings == 0 then
		return
	end

	local sellAll = false
	for _, buildingName in ipairs(selectedBuildings) do
		if buildingName == "Any" then
			sellAll = true
			break
		end
	end

	local buildingsToSell = sellAll and regularBuildingItemNames or selectedBuildings
	local sellDelay = State.autoSellBuildingDelay or 0.5

	for _, building in ipairs(buildingsToSell) do
		sellBuilding(building)
		task.wait(sellDelay)
	end
end

Automation.Economy.buySelectedItems = buySelectedItems
Automation.Economy.buyAllAvailableItems = buyAllAvailableItems
Automation.Buildings.sellBuilding = sellBuilding
Automation.Buildings.sellSelectedBuildings = sellSelectedBuildings

-- ============================================================================
-- Public-server discovery
-- ============================================================================

local function fetchPublicServerPage()
	local succeeded, response = pcall(function()
		return game:HttpGet(
			"https://games.roblox.com/v1/games/"
				.. game.PlaceId
				.. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
		)
	end)

	if not succeeded or type(response) ~= "string" or response == "" then
		return false, nil
	end

	local decodeSucceeded, serverPage = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSucceeded or type(serverPage) ~= "table" or type(serverPage.data) ~= "table" then
		return false, nil
	end

	return true, serverPage
end

local function hopToRandomServer()
	local succeeded, serverPage = fetchPublicServerPage()
	if not succeeded then
		return
	end

	local candidateIds = {}
	for _, server in pairs(serverPage.data) do
		if server.playing < server.maxPlayers and server.id ~= game.JobId then
			table.insert(candidateIds, server.id)
		end
	end

	if #candidateIds > 0 then
		local serverId = candidateIds[math.random(#candidateIds)]
		TeleportService:TeleportToPlaceInstance(game.PlaceId, serverId, LocalPlayer)
	end
end

local function hopToLeastPopulatedServer()
	local succeeded, serverPage = fetchPublicServerPage()
	if not succeeded then
		return
	end

	local candidates = {}
	for _, server in pairs(serverPage.data) do
		if server.playing < server.maxPlayers and server.id ~= game.JobId then
			table.insert(candidates, {
				id = server.id,
				players = server.playing,
			})
		end
	end

	if #candidates > 0 then
		table.sort(candidates, function(left, right)
			return left.players < right.players
		end)

		TeleportService:TeleportToPlaceInstance(game.PlaceId, candidates[1].id, LocalPlayer)
	end
end

Automation.Servers.hopToRandomServer = hopToRandomServer
Automation.Servers.hopToLeastPopulatedServer = hopToLeastPopulatedServer

-- ============================================================================
-- Building placement
-- ============================================================================

local function placeBuilding(modelName, modelCFrame)
	local payload = {
		modelName = modelName,
		modelCFrame = modelCFrame,
	}

	if fireBridge("PlaceBuilding", payload) then
		return
	end

	primeBridge("PlaceBuilding")
	task.wait(0.15)
	fireDataRemote({
		{
			modelName = modelName,
			modelCFrame = modelCFrame,
		},
		"7",
	})
end

Automation.Buildings.placeBuilding = placeBuilding

-- ============================================================================
-- Plot and NPC discovery
-- ============================================================================

local function normalizePlayerPlotModel(plotModel)
	if not plotModel then
		return nil, nil
	end

	if plotModel.Name == "Plot" then
		return plotModel.Parent, plotModel
	end

	local plot = plotModel:FindFirstChild("Plot")
	if plot then
		return plotModel, plot
	end

	return plotModel.Parent, plotModel
end

local function findLocalPlayerPlot()
	local militaryMap = Workspace:FindFirstChild("MilitaryMap")
	local playerPlots = militaryMap and militaryMap:FindFirstChild("PlayerPlots")
	if not playerPlots then
		return nil, nil
	end

	if GetPlotModel then
		local succeeded, plotModel = pcall(function()
			return GetPlotModel(LocalPlayer)
		end)
		if succeeded and plotModel and plotModel:IsDescendantOf(playerPlots) then
			return normalizePlayerPlotModel(plotModel)
		end
	end

	local playerPlotTag = LocalPlayer.Name .. "-Plot"
	for _, taggedPlot in ipairs(CollectionService:GetTagged(playerPlotTag)) do
		if taggedPlot:IsDescendantOf(playerPlots) then
			return normalizePlayerPlotModel(taggedPlot)
		end
	end

	for _, plotContainer in ipairs(playerPlots:GetChildren()) do
		local plot = plotContainer:FindFirstChild("Plot")
		local ownerName = plotContainer:GetAttribute("Owner") or (plot and plot:GetAttribute("Owner"))
		if ownerName == LocalPlayer.Name then
			return plotContainer, plot
		end
	end

	return nil, nil
end

local function findPlayerPlotContainer()
	local plotContainer = findLocalPlayerPlot()
	return plotContainer
end

local function findPlayerPlot()
	local _, plot = findLocalPlayerPlot()
	return plot
end

local function findLivingRiotNpc()
	local localNpcs = Workspace:FindFirstChild("LocalNpcs")
	if not localNpcs then
		return nil
	end

	for _, npc in ipairs(localNpcs:GetChildren()) do
		if npc:IsA("Model") and npc:FindFirstChild("RiotShield", true) then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health > 0 then
				return npc
			end
		end
	end

	return nil
end

local function findLivingFallenGeneral()
	local localNpcs = Workspace:FindFirstChild("LocalNpcs")
	if not localNpcs then
		return nil
	end

	for _, npc in ipairs(localNpcs:GetChildren()) do
		if npc:IsA("Model") and npc.Name:find("FallenGeneral") then
			local humanoid = npc:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health > 0 then
				return npc
			end
		end
	end

	return nil
end

GameApi.findPlayerPlotContainer = findPlayerPlotContainer
GameApi.findPlayerPlot = findPlayerPlot
GameApi.findLivingRiotNpc = findLivingRiotNpc
GameApi.findLivingFallenGeneral = findLivingFallenGeneral

-- ============================================================================
-- Resource collection
-- ============================================================================

local function isCollectPrompt(prompt)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		return false
	end

	local actionText = prompt.ActionText or ""
	local lowerActionText = actionText:lower()

	if lowerActionText:find("skip") then
		return false
	end

	if prompt.ObjectText == "Collect!" or actionText:match("x%d+") then
		return true
	end

	local parent = prompt.Parent
	if not parent then
		return false
	end

	local building
	if parent:IsA("Model") then
		building = parent
	elseif parent.Parent and parent.Parent:IsA("Model") then
		building = parent.Parent
	end

	if not building or not building.Parent or building.Parent.Name ~= "Buildings" then
		return false
	end

	return not lowerActionText:find("unclaim")
		and not lowerActionText:find("upgrade")
		and not lowerActionText:find("send")
end

local function getCollectItemName(prompt)
	local actionText = prompt.ActionText
	if actionText then
		local itemName = actionText:match("x%d+ (.+)")
		if itemName then
			return itemName
		end
	end

	local parent = prompt.Parent
	if not parent then
		return nil
	end

	if parent:IsA("Model") then
		return parent.Name
	end

	local model = parent.Parent
	if model and model:IsA("Model") then
		return model.Name
	end

	return nil
end

local function getCollectibleItemNames()
	local itemNames = {}
	local seenNames = {}
	local plot = findPlayerPlot()
	if not plot then
		return itemNames
	end

	local buildings = plot:FindFirstChild("Buildings")
	if not buildings then
		return itemNames
	end

	for _, descendant in ipairs(buildings:GetDescendants()) do
		if isCollectPrompt(descendant) then
			local itemName = getCollectItemName(descendant)
			if itemName and not seenNames[itemName] and not collectExcludedBuildingNames[itemName] then
				seenNames[itemName] = true
				table.insert(itemNames, itemName)
			end
		end
	end

	return itemNames
end

local function collectSelectedItems()
	if not State.autoCollectRunning then
		return
	end

	local plot = findPlayerPlot()
	if not plot then
		return
	end

	local buildings = plot:FindFirstChild("Buildings")
	if not buildings then
		return
	end

	local selectedItems = State.selectedCollectItems
	local collectEverything = false

	for _, selectedItem in ipairs(selectedItems) do
		if selectedItem == "Any" then
			collectEverything = true
			break
		end
	end

	collectEverything = collectEverything or not selectedItems or #selectedItems == 0

	for _, descendant in ipairs(buildings:GetDescendants()) do
		if not State.autoCollectRunning then
			break
		end

		if isCollectPrompt(descendant) then
			local itemName = getCollectItemName(descendant)
			if itemName and not collectExcludedBuildingNames[itemName] then
				if collectEverything then
					fireproximityprompt(descendant)
					task.wait(0.1)
				else
					for _, selectedItem in ipairs(selectedItems) do
						if selectedItem == itemName then
							fireproximityprompt(descendant)
							task.wait(0.1)
							break
						end
					end
				end
			end
		end
	end
end

GameApi.isCollectPrompt = isCollectPrompt
GameApi.getCollectItemName = getCollectItemName
GameApi.getCollectibleItemNames = getCollectibleItemNames
Automation.Collection.collectSelectedItems = collectSelectedItems

-- ============================================================================
-- Player state and plot geometry
-- ============================================================================

local function findFirstBasePart(instance)
	if not instance then
		return nil
	end

	if instance:IsA("BasePart") then
		return instance
	end

	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function getPlayerPlotBasePart()
	if GetPlotModel then
		local succeeded, plotModel = pcall(function()
			return GetPlotModel(LocalPlayer)
		end)

		if succeeded and plotModel then
			local plot = plotModel:FindFirstChild("Plot") or plotModel
			local basePart = findFirstBasePart(plot)
			if basePart then
				return basePart
			end
		end
	end

	return findFirstBasePart(findPlayerPlot())
end

local function getPlayerState()
	if not ClientData or not ClientData.playerProducer then
		return nil
	end

	local succeeded, playerState = pcall(function()
		return ClientData.playerProducer:getState().player
	end)

	if not succeeded then
		return nil
	end

	return playerState
end

-- Deliberately returns both values produced by string.gsub, matching the
-- original helper. Callers in this script consume only the normalized string.
local function normalizeName(value)
	local lowerName = (value or ""):lower()
	return lowerName:gsub("%s+", "")
end

local function prependAny(values)
	local result = { "Any" }
	for _, value in ipairs(values) do
		table.insert(result, value)
	end

	return result
end

local function prependAnyAndNone(values)
	local result = { "Any", "None" }
	for _, value in ipairs(values) do
		table.insert(result, value)
	end

	return result
end

GameApi.getPlayerPlotBasePart = getPlayerPlotBasePart
GameApi.getPlayerState = getPlayerState
GameApi.normalizeName = normalizeName
GameApi.prependAny = prependAny
GameApi.prependAnyAndNone = prependAnyAndNone

-- The interface section updates this with the next auto-sell interval.
local nextMarketUpdateAt = nil

-- ============================================================================
-- Market filtering and resource sales
-- ============================================================================

local function getMarketSkillPriceBoost()
	if type(GetSkillsData) ~= "function" then
		return 0
	end

	local succeeded, skillsData = pcall(GetSkillsData, LocalPlayer)
	if not succeeded or type(skillsData) ~= "table" then
		return 0
	end

	return (tonumber(skillsData.marketPrice) or 0) / 100
end

local function getAdjustedMarketMultiplier(gameState, resourceId, stockMultiplier)
	local multiplier = (tonumber(stockMultiplier) or 1) + getMarketSkillPriceBoost()
	local nuclearBoost = gameState.nuclearMarketBoosts and gameState.nuclearMarketBoosts[resourceId]
	if type(nuclearBoost) == "number" then
		multiplier += nuclearBoost
	end

	multiplier += (tonumber(State.marketBonusPercent) or 0) / 100
	return multiplier, type(nuclearBoost) == "number" and nuclearBoost ~= 0
end

local function getMarketEligibleItems()
	local eligibleItems = {}
	if not ClientData or not ResourcesConfig then
		return eligibleItems
	end

	local succeeded, gameState = pcall(function()
		return ClientData.gameProducer:getState()
	end)
	if not succeeded or not gameState then
		return eligibleItems
	end

	local market = gameState.market
	if not market or not market.stock then
		return eligibleItems
	end

	local minimumPercent = tonumber(State.autoSellMinPercent) or 0
	local marketCondition = State.autoSellMarketCondition or "Price Up"

	for resourceId, priceMultiplier in pairs(market.stock) do
		local resource = ResourcesConfig[resourceId]
		if resource and resource.Name and resource.Price and not resource.dontDisplayInMarket then
			local adjustedMultiplier = getAdjustedMarketMultiplier(gameState, resourceId, priceMultiplier)
			local priceChangePercent = math.round((adjustedMultiplier - 1) * 100)
			local meetsCondition = (marketCondition == "Price Up" and priceChangePercent >= minimumPercent)
				or (marketCondition == "Price Down" and priceChangePercent <= -minimumPercent)

			if meetsCondition then
				local displayName = tostring(resource.Name)
				local rawId = tostring(resourceId)

				eligibleItems[displayName] = true
				eligibleItems[rawId] = true
				eligibleItems[normalizeName(displayName)] = true
				eligibleItems[normalizeName(rawId)] = true
			end
		end
	end

	return eligibleItems
end

local function sellSelectedResources(includeMarketEligibleItems)
	local character = LocalPlayer.Character
	if not character then
		return
	end

	local selectedItems = State.selectedSellItems
	local includesAny = false
	for _, itemName in ipairs(selectedItems) do
		if itemName == "Any" then
			includesAny = true
			break
		end
	end

	local selectionRequired = type(selectedItems) == "table" and #selectedItems > 0 and not includesAny
	local selectedLookup = {}
	if selectionRequired then
		for _, itemName in ipairs(selectedItems) do
			selectedLookup[itemName] = true
			selectedLookup[normalizeName(itemName)] = true
		end
	end

	local marketEligibleLookup = {}
	local hasMarketEligibleItems = false
	if includeMarketEligibleItems then
		marketEligibleLookup = getMarketEligibleItems()
		hasMarketEligibleItems = next(marketEligibleLookup) ~= nil
	end

	local function shouldSell(itemName)
		if unsellableToolNames[itemName] then
			return false
		end

		local normalizedItemName = normalizeName(itemName)

		if selectionRequired and not selectedLookup[itemName] and not selectedLookup[normalizedItemName] then
			return false
		end

		if includeMarketEligibleItems then
			if not hasMarketEligibleItems then
				return false
			end

			if not marketEligibleLookup[itemName] and not marketEligibleLookup[normalizedItemName] then
				return false
			end
		end

		return true
	end

	local equippedTool = character:FindFirstChildOfClass("Tool")
	if equippedTool and shouldSell(equippedTool.Name) then
		pcall(function()
			SellSingularItemBridge:Fire()
		end)
		task.wait(0.25)
	end

	-- Snapshot names before moving tools. Retaining duplicate names lets the
	-- loop sell multiple copies with the same display name.
	local backpackToolNames = {}
	for _, child in ipairs(LocalPlayer.Backpack:GetChildren()) do
		if child:IsA("Tool") and shouldSell(child.Name) then
			table.insert(backpackToolNames, child.Name)
		end
	end

	for _, toolName in ipairs(backpackToolNames) do
		local tool = LocalPlayer.Backpack:FindFirstChild(toolName)
		if tool and shouldSell(tool.Name) then
			tool.Parent = character
			task.wait(0.25)

			local equipped = character:FindFirstChild(toolName)
			if equipped and equipped:IsA("Tool") then
				pcall(function()
					SellSingularItemBridge:Fire()
				end)
				task.wait(0.25)
			end
		end
	end
end

Automation.Economy.getMarketEligibleItems = getMarketEligibleItems
Automation.Economy.sellSelectedResources = sellSelectedResources

-- ============================================================================
-- Combat, raids, movement, and progression
-- ============================================================================
-- This section contains the game-facing combat helpers and the player-side
-- utilities consumed by the interface workers defined in the next section.

-- --------------------------------------------------------------------------
-- Weather and raid discovery
-- --------------------------------------------------------------------------

local function isOwnedByLocalPlayer(target)
	if not target then
		return false
	end

	local parent = target.Parent
	local owner = target:GetAttribute("Owner") or (parent and parent:GetAttribute("Owner"))
	if owner == nil then
		return false
	end

	return tostring(owner) == LocalPlayer.Name or tonumber(owner) == LocalPlayer.UserId
end

local function isWeatherActive(weatherName)
	local success, isActive = pcall(function()
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then
			return false
		end

		local mainUi = playerGui:FindFirstChild("MainUI")
		if not mainUi then
			return false
		end

		local hud = mainUi:FindFirstChild("HUD")
		if not hud then
			return false
		end

		local currencyUi = hud:FindFirstChild("CurrencyUI")
		if not currencyUi then
			return false
		end

		local weatherContainer = currencyUi:FindFirstChild("Weather")
		if not weatherContainer then
			return false
		end

		return weatherContainer:FindFirstChild("Active_" .. weatherName) ~= nil
	end)

	return success and isActive or false
end

local function isBeastBreachActive()
	local success, isActive = pcall(function()
		return Workspace:GetAttribute("BeastBreachActive")
	end)

	return success and isActive == true
end

local function getBeastHealth()
	local success, health = pcall(function()
		return Workspace:GetAttribute("BeastHP")
	end)

	if success and health then
		return health
	end

	return 100
end

local function getMilitaryTown()
	local town
	pcall(function()
		town = Workspace.MilitaryMap.Object.MilitaryTown.Town
	end)
	return town
end

local raidArmySettingByName = {
	KingOfTheHillBase = "raidArmyIndex1",
	ToxicKingOfTheHillBase = "raidArmyIndex2",
	RiotBase = "raidArmyIndex3",
	CargoBase = "raidArmyIndex4",
	BeastBreach = "raidArmyIndex5",
	MeteorCargo = "raidArmyIndex6",
	MeteorGems = "raidArmyIndex7",
	Invaded = "raidArmyIndex8",
	Hacker = "raidArmyIndex9",
}

-- Rebuilt on every scan so attackHighestPriorityRaid can recover the logical
-- raid name from the concrete capture-point instance selected by this function.
local raidNameByTarget = {}

local function getAvailableRaidTargets()
	local orderedTargets = {}
	local specialObjects

	pcall(function()
		specialObjects = Workspace.MilitaryMap.Object.Special
	end)

	if not specialObjects then
		return orderedTargets
	end

	local priorityOrder = {
		getgenv().raidPriority1 or "KingOfTheHillBase",
		getgenv().raidPriority2 or "ToxicKingOfTheHillBase",
		getgenv().raidPriority3 or "RiotBase",
		getgenv().raidPriority4 or "CargoBase",
		getgenv().raidPriority5 or "BeastBreach",
		getgenv().raidPriority6 or "MeteorCargo",
		getgenv().raidPriority7 or "MeteorGems",
		getgenv().raidPriority8 or "Invaded",
		getgenv().raidPriority9 or "Hacker",
	}

	local targetByRaidName = {}

	local kingOfTheHill = specialObjects:FindFirstChild("KingOfTheHillBase")
	if kingOfTheHill and not isOwnedByLocalPlayer(kingOfTheHill) then
		targetByRaidName.KingOfTheHillBase = kingOfTheHill
	end

	local toxicKingOfTheHill = specialObjects:FindFirstChild("ToxicKingOfTheHillBase")
	if toxicKingOfTheHill and not isOwnedByLocalPlayer(toxicKingOfTheHill) then
		targetByRaidName.ToxicKingOfTheHillBase = toxicKingOfTheHill
	end

	local riotBase
	pcall(function()
		riotBase = Workspace.MilitaryMap.Object.Special.RiotBase
	end)
	if not riotBase then
		pcall(function()
			riotBase = Workspace.MilitaryMap.Object.RiotBase
		end)
	end
	if riotBase and not isOwnedByLocalPlayer(riotBase) then
		targetByRaidName.RiotBase = riotBase
	end

	local cargoBase = specialObjects:FindFirstChild("CargoBase")
	if cargoBase and not isOwnedByLocalPlayer(cargoBase) then
		targetByRaidName.CargoBase = cargoBase
	end

	local meteorGemsBase = specialObjects:FindFirstChild("MeteorBase")
	if meteorGemsBase and not isOwnedByLocalPlayer(meteorGemsBase) then
		targetByRaidName.MeteorGems = meteorGemsBase
	end

	local meteorCargoBase = specialObjects:FindFirstChild("MeteorCaseBase")
	if meteorCargoBase and not isOwnedByLocalPlayer(meteorCargoBase) then
		targetByRaidName.MeteorCargo = meteorCargoBase
	end

	if isBeastBreachActive() then
		local town = getMilitaryTown()
		if town then
			targetByRaidName.BeastBreach = town
		end
	end

	if isWeatherActive("Invasion") then
		local success, fallenGeneral = pcall(findLivingFallenGeneral)
		if success and fallenGeneral then
			local town = getMilitaryTown()
			if town then
				targetByRaidName.Invaded = town
			end
		end
	end

	local hackerBase = specialObjects:FindFirstChild("HackerBase")
	if hackerBase and not isOwnedByLocalPlayer(hackerBase) then
		targetByRaidName.Hacker = hackerBase
	end

	raidNameByTarget = {}

	-- User-selected priorities are consumed first. Removing a consumed entry
	-- prevents duplicate targets if a raid name appears more than once.
	for _, raidName in ipairs(priorityOrder) do
		local target = targetByRaidName[raidName]
		if target then
			table.insert(orderedTargets, target)
			raidNameByTarget[target] = raidName
			targetByRaidName[raidName] = nil
		end
	end

	-- Preserve the original unordered fallback for available raids that were
	-- omitted from the configured priority list.
	for raidName, target in pairs(targetByRaidName) do
		table.insert(orderedTargets, target)
		raidNameByTarget[target] = raidName
	end

	return orderedTargets
end

local function findCapturePoint(targetName)
	if not targetName then
		return nil
	end

	local success, capturePoints = pcall(function()
		return CollectionService:GetTagged("CapturePoint")
	end)
	if not success or not capturePoints then
		return nil
	end

	for _, capturePoint in ipairs(capturePoints) do
		if capturePoint.Name == targetName then
			return capturePoint
		end

		local parent = capturePoint.Parent
		if parent and parent.Name == targetName then
			return capturePoint
		end

		local grandparent = parent and parent.Parent
		if grandparent and grandparent.Name == targetName then
			return capturePoint
		end
	end

	return nil
end

-- --------------------------------------------------------------------------
-- Attack dispatch
-- --------------------------------------------------------------------------

local function deployForcesToTarget(target, armyIndex, forceType)
	armyIndex = armyIndex or 1
	forceType = forceType or "Any"

	if not target then
		return
	end

	if forceType == "Any" or forceType == "Rocket" then
		local sentThroughBridge = fireBridge("SendRocketsToPoint", {
			capturePoint = target,
		})

		if not sentThroughBridge then
			pcall(function()
				ReplicatedStorage._GetBridgeFunction:InvokeServer("SendRocketsToPoint")
			end)
			task.wait(0.3)
			pcall(function()
				DataRemoteEvent:FireServer({ { capturePoint = target }, "\r" })
			end)
		end

		task.wait(0.25)
	end

	if forceType == "Any" or forceType == "Army" then
		local sentThroughBridge = fireBridge("SendTroopsToPoint", {
			armyIndex = armyIndex,
			capturePoint = target,
		})

		if not sentThroughBridge then
			pcall(function()
				ReplicatedStorage._GetBridgeFunction:InvokeServer("SendTroopsToPoint")
			end)
			task.wait(0.3)
			pcall(function()
				DataRemoteEvent:FireServer({
					{ armyIndex = armyIndex, capturePoint = target },
					"\r",
				})
			end)
		end
	end
end

local function attackHighestPriorityRaid(defaultArmyIndex, forceType)
	local raidTargets = getAvailableRaidTargets()
	local target = raidTargets[1]
	if not target then
		return
	end

	local raidName = raidNameByTarget[target]
	local armySettingName = raidName and raidArmySettingByName[raidName]
	local configuredArmyIndex = armySettingName and getgenv()[armySettingName]
	local armyIndex = configuredArmyIndex or defaultArmyIndex

	deployForcesToTarget(target, armyIndex, forceType)
end

local function attackTarget(targetName, armyIndex, forceType)
	if not targetName or targetName == "Skip" then
		return
	end

	if targetName == "RaidEvent" then
		attackHighestPriorityRaid(armyIndex, forceType)
		return
	end

	local target = findCapturePoint(targetName)
	if target and isOwnedByLocalPlayer(target) then
		return
	end

	if not target then
		local targetCategory = targetName:match("^%a+")
		local targetNumber = targetName:match("%d+") or ""

		if targetCategory == "Laboratory" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.Laboratory["Laboratory" .. targetNumber]
			end)
		elseif targetCategory == "Bandit" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.Bandit["Garnison" .. targetNumber]
			end)
		elseif targetCategory == "Town" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.MilitaryTown.Town
			end)
		elseif targetCategory == "Wooden" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.Wooden["Garnison" .. targetNumber]
			end)
		elseif targetCategory == "MilitaryBase" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.MilitaryBase["MilitaryBase" .. targetNumber]
			end)
		elseif targetCategory == "WaterRig" then
			pcall(function()
				target = Workspace.MilitaryMap.Object.WaterRigs["WaterRig" .. targetNumber]
			end)
		end

		if target and isOwnedByLocalPlayer(target) then
			return
		end
	end

	deployForcesToTarget(target, armyIndex, forceType)
end

-- --------------------------------------------------------------------------
-- Flight and movement
-- --------------------------------------------------------------------------

local function disconnectGlobalConnection(key)
	local environment = getgenv()
	local connection = environment[key]
	if connection then
		connection:Disconnect()
		environment[key] = nil
	end
end

local function destroyGlobalInstance(key)
	local environment = getgenv()
	local instance = environment[key]
	if instance then
		instance:Destroy()
		environment[key] = nil
	end
end

local function stopFlying()
	getgenv().MISC_FLYING = false

	disconnectGlobalConnection("miscFlyKeyDown")
	disconnectGlobalConnection("miscFlyKeyUp")
	disconnectGlobalConnection("miscFlyHB")
	disconnectGlobalConnection("miscFlyDied")
	destroyGlobalInstance("miscFlyGyro")
	destroyGlobalInstance("miscFlyVel")

	local character = LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.PlatformStand = false
		end
	end

	pcall(function()
		Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	end)
end

local function startFlying()
	if getgenv().MISC_FLYING then
		stopFlying()
	end

	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		while runtimeActive and not character:FindFirstChildOfClass("Humanoid") do
			task.wait()
		end
		humanoid = character:FindFirstChildOfClass("Humanoid")
	end
	if not runtimeActive or not humanoid then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local movement = {
		forward = 0,
		backward = 0,
		left = 0,
		right = 0,
		up = 0,
		down = 0,
	}

	local environment = getgenv()
	environment.miscFlyGyro = Instance.new("BodyGyro")
	environment.miscFlyGyro.P = 90000
	environment.miscFlyGyro.MaxTorque = Vector3.new(9000000000, 9000000000, 9000000000)
	environment.miscFlyGyro.CFrame = rootPart.CFrame
	environment.miscFlyGyro.Parent = rootPart

	environment.miscFlyVel = Instance.new("BodyVelocity")
	environment.miscFlyVel.MaxForce = Vector3.new(9000000000, 9000000000, 9000000000)
	environment.miscFlyVel.Velocity = Vector3.new(0, 0, 0)
	environment.miscFlyVel.Parent = rootPart

	environment.MISC_FLYING = true
	humanoid.PlatformStand = true

	environment.miscFlyKeyDown = UserInputService.InputBegan:Connect(function(input, wasProcessed)
		if wasProcessed then
			return
		end

		local keyCode = input.KeyCode
		if keyCode == Enum.KeyCode.W then
			movement.forward = 1
		elseif keyCode == Enum.KeyCode.S then
			movement.backward = -1
		elseif keyCode == Enum.KeyCode.A then
			movement.left = -1
		elseif keyCode == Enum.KeyCode.D then
			movement.right = 1
		elseif keyCode == Enum.KeyCode.E then
			movement.up = 1
		elseif keyCode == Enum.KeyCode.Q then
			movement.down = -1
		end

		pcall(function()
			Workspace.CurrentCamera.CameraType = Enum.CameraType.Track
		end)
	end)

	environment.miscFlyKeyUp = UserInputService.InputEnded:Connect(function(input, wasProcessed)
		if wasProcessed then
			return
		end

		local keyCode = input.KeyCode
		if keyCode == Enum.KeyCode.W then
			movement.forward = 0
		elseif keyCode == Enum.KeyCode.S then
			movement.backward = 0
		elseif keyCode == Enum.KeyCode.A then
			movement.left = 0
		elseif keyCode == Enum.KeyCode.D then
			movement.right = 0
		elseif keyCode == Enum.KeyCode.E then
			movement.up = 0
		elseif keyCode == Enum.KeyCode.Q then
			movement.down = 0
		end
	end)

	environment.miscFlyHB = RunService.Heartbeat:Connect(function()
		if not getgenv().MISC_FLYING then
			local heartbeatConnection = getgenv().miscFlyHB
			if heartbeatConnection then
				heartbeatConnection:Disconnect()
			end
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		local horizontal = movement.left + movement.right
		local forward = movement.forward + movement.backward
		local vertical = movement.up + movement.down
		local isMoving = horizontal ~= 0 or forward ~= 0 or vertical ~= 0
		local speed = (isMoving and getgenv().miscFlySpeed) or 0

		local direction = camera.CFrame.LookVector * forward
			+ camera.CFrame.RightVector * horizontal
			+ camera.CFrame.UpVector * vertical

		getgenv().miscFlyVel.Velocity = direction * speed
		getgenv().miscFlyGyro.CFrame = camera.CFrame
	end)

	environment.miscFlyDied = humanoid.Died:Connect(function()
		stopFlying()
	end)
end

-- --------------------------------------------------------------------------
-- Notifications, teleport re-execution, and anti-AFK
-- --------------------------------------------------------------------------

local function notify(message)
	if getgenv().disableNotifications then
		return
	end

	pcall(function()
		Library:Notify(message)
	end)
end

local function queueReExecutionOnTeleport()
	if not getgenv().autoReconnectEnabled and not getgenv().autoReExecEnabled then
		return
	end

	pcall(function()
		local reExecutionSource =
			'loadstring(game:HttpGet("https://raw.githubusercontent.com/LynX99-9/komtolmmek2script/refs/heads/main/CyraaHub.lua", true))()'

		if queue_on_teleport then
			queue_on_teleport(reExecutionSource)
		elseif syn and syn.queue_on_teleport then
			syn.queue_on_teleport(reExecutionSource)
		elseif fluxus and fluxus.queue_on_teleport then
			fluxus.queue_on_teleport(reExecutionSource)
		end
	end)
end

local function enableAntiAfk()
	local existingConnection = State.miscAntiAfkConn
	if existingConnection and existingConnection.Connected then
		return
	end
	State.miscAntiAfkConn = nil

	if getconnections and not State._antiAfkDefaultsProcessed then
		State._antiAfkDefaultsProcessed = true
		State._antiAfkDisabledConnections = {}
		pcall(function()
			for _, connection in pairs(getconnections(LocalPlayer.Idled)) do
				if connection.Disable then
					connection:Disable()
					table.insert(State._antiAfkDisabledConnections, connection)
				end
			end
		end)
	end

	if not State.miscAntiAfkConn then
		State.miscAntiAfkConn = trackRuntimeConnection(LocalPlayer.Idled:Connect(function()
			if State.miscAntiAfkEnabled and runtimeActive then
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end
		end))
	end
end

local function disableAntiAfk()
	if State.miscAntiAfkConn then
		pcall(function()
			State.miscAntiAfkConn:Disconnect()
		end)
		State.miscAntiAfkConn = nil
	end

	for _, connection in ipairs(State._antiAfkDisabledConnections or {}) do
		pcall(function()
			if connection.Enable then
				connection:Enable()
			end
		end)
	end
	State._antiAfkDisabledConnections = nil
	State._antiAfkDefaultsProcessed = nil
end

-- --------------------------------------------------------------------------
-- Battle Pass and quest automation
-- --------------------------------------------------------------------------

local function claimBattlePassRewards()
	local track = getgenv().autoBPTrack or "Free"

	for stage = 1, 50 do
		pcall(function()
			DataRemoteEvent:FireServer({ { stage = stage, track = track }, "@" })
		end)
		task.wait(0.2)
	end

	pcall(function()
		ReplicatedStorage._GetBridgeFunction:InvokeServer("ClaimBPReward")
	end)
end

local function collectBattlePassPickups()
	-- The original payload collects remotely without moving the character.
	-- Prime the lazily-created bridge first, then preserve that behavior.
	primeBridge("CollectBPPickup")
	local collectPickupBridge = getCachedBridge("CollectBPPickup")
	if not collectPickupBridge then
		warn("[MiniWar] CollectBPPickup bridge is unavailable")
		return 0
	end

	local sent = 0
	for _, pickup in ipairs(Workspace:GetDescendants()) do
		if pickup.Name == "BATTLEPASS_POINT_PICKUP" then
			local pickupId = pickup:GetAttribute("PickupId")
			if pickupId and fireBridge("CollectBPPickup", pickupId) then
				sent += 1
				task.wait(0.1)
			end
		end
	end

	return sent
end

local function getClaimableQuests()
	if not ClientData or not ClientData.playerProducer then
		return nil
	end

	local success, playerState = pcall(function()
		return ClientData.playerProducer:getState().player
	end)
	if not success or not playerState then
		return nil
	end

	local questData = playerState.questData
	local quests = questData and questData.activeQuests

	if type(quests) ~= "table" then
		return nil
	end

	local claimableQuests = {}
	for questName, liveQuest in pairs(quests) do
		local questConfig = QuestsConfig and QuestsConfig[questName]
		local difficulty = (questConfig and questConfig.difficulty) or questDifficultyByName[questName]
		if difficulty then
			questDifficultyByName[questName] = tostring(difficulty):lower()
			local isQuestTable = type(liveQuest) == "table"
			local progress = isQuestTable and (liveQuest.progress or liveQuest.amount or liveQuest.value)
			progress = progress or liveQuest

			local goal = (questConfig and questConfig.max)
				or (isQuestTable and (liveQuest.max or liveQuest.goal) or nil)
			local claimed = (isQuestTable and (liveQuest.claimed or liveQuest.completed)) or false

			if not claimed and type(progress) == "number" and type(goal) == "number" and progress >= goal then
				table.insert(claimableQuests, questName)
			end
		end
	end

	return claimableQuests
end

local function claimSelectedQuests()
	local selectedDifficulties = getgenv().selectedQuestDifficulty
	local acceptsAnyDifficulty = false

	for _, difficulty in ipairs(selectedDifficulties) do
		if difficulty == "Any" then
			acceptsAnyDifficulty = true
			break
		end
	end

	local selectedDifficultyLookup = {}
	if not acceptsAnyDifficulty and #selectedDifficulties > 0 then
		for _, difficulty in ipairs(selectedDifficulties) do
			selectedDifficultyLookup[difficulty:lower()] = true
		end
	end

	local claimableQuests = getClaimableQuests()
	local questsToClaim = {}

	if not claimableQuests then
		return
	end

	for _, questName in ipairs(claimableQuests) do
		local difficulty = questDifficultyByName[questName]
		if
			difficulty
			and (acceptsAnyDifficulty or #selectedDifficulties == 0 or selectedDifficultyLookup[difficulty])
		then
			table.insert(questsToClaim, questName)
		end
	end

	for _, questName in ipairs(questsToClaim) do
		fireBridge("TryToCompleteQuest", questName)
		task.wait(0.3)
	end
end

-- Mutable UI caches shared with buildInterface in the next section.
local isRefreshingCollectList = false
local cachedCollectItemNames = {}
local uiRefs = {}

-- Public module surface. Local aliases above remain the compatibility contract
-- for the reconstructed UI workers, while these tables provide maintainable
-- entry points for future game updates.
GameApi.isOwnedByLocalPlayer = isOwnedByLocalPlayer
GameApi.isWeatherActive = isWeatherActive
GameApi.isBeastBreachActive = isBeastBreachActive
GameApi.getBeastHealth = getBeastHealth
GameApi.getMilitaryTown = getMilitaryTown
GameApi.getAvailableRaidTargets = getAvailableRaidTargets
GameApi.findCapturePoint = findCapturePoint
GameApi.deployForcesToTarget = deployForcesToTarget

Automation.Combat.deployForcesToTarget = deployForcesToTarget
Automation.Combat.attackHighestPriorityRaid = attackHighestPriorityRaid
Automation.Combat.attackTarget = attackTarget

Automation.Movement = Automation.Movement or {}
Automation.Movement.startFlying = startFlying
Automation.Movement.stopFlying = stopFlying

Automation.Servers.queueReExecutionOnTeleport = queueReExecutionOnTeleport

Automation.Utilities = Automation.Utilities or {}
Automation.Utilities.enableAntiAfk = enableAntiAfk

Automation.Progression.claimBattlePassRewards = claimBattlePassRewards
Automation.Progression.collectBattlePassPickups = collectBattlePassPickups
Automation.Progression.getClaimableQuests = getClaimableQuests
Automation.Progression.claimSelectedQuests = claimSelectedQuests

UI.notify = notify
UI.refs = uiRefs

--[[
	UI shell and Home/Farm feature composition.

	This fragment intentionally defines builders without invoking them. The final
	assembly calls createInterfaceShell(), then buildHomeFarmUi(), followed by the
	Shop/Teleport/Misc and Server/Settings builders. Keeping construction ordered
	this way preserves Obsidian option registration and autoload behavior.
]]

UI.refs = uiRefs

local function createInterfaceShell()
	uiRefs.Window = Library:CreateWindow({
		Title = "Cyraa Hub",
		Footer = "Mini War v2.0.4",
		Icon = 111485823583751,
		NotifySide = "Right",
		ShowCustomCursor = true,
		Center = true,
		AutoShow = true,
	})

	uiRefs.Tabs = {
		Home = uiRefs.Window:AddTab("Home", "house"),
		Farm = uiRefs.Window:AddTab("Auto Farm", "swords"),
		Shop = uiRefs.Window:AddTab("Shop", "shopping-cart"),
		Teleport = uiRefs.Window:AddTab("Teleport", "map-pin"),
		Misc = uiRefs.Window:AddTab("Misc", "settings"),
		Server = uiRefs.Window:AddTab("Server", "server"),
		Settings = uiRefs.Window:AddTab("Settings", "wrench"),
	}
end

local function spawnFlaggedWorker(flagName, interval, callback)
	task.spawn(function()
		while runtimeActive and getgenv()[flagName] do
			pcall(callback)
			local delay = interval
			if type(interval) == "function" then
				delay = interval()
			end
			task.wait(delay)
		end
	end)
end

local function containsValue(values, expected)
	for _, value in ipairs(values) do
		if value == expected then
			return true
		end
	end
	return false
end

local function buildHomeFarmUi()
	-- Home: game status and project links ------------------------------------
	local gameInformationGroup = uiRefs.Tabs.Home:AddLeftGroupbox("Game Information", "info")
	uiRefs.GameTimeLabel = gameInformationGroup:AddLabel("Game Time: 0h 0m 0s")
	uiRefs.FpsLabel = gameInformationGroup:AddLabel("FPS: 0")
	uiRefs.PingLabel = gameInformationGroup:AddLabel("Ping: 0ms")
	gameInformationGroup:AddDivider()
	gameInformationGroup:AddLabel("Cyraa Hub v2.0.4")
	gameInformationGroup:AddLabel("Mini War", true)
	uiRefs.playerInfoLabel = gameInformationGroup:AddLabel("Player Info: Loading...")

	task.spawn(function()
		local textLabel = uiRefs.playerInfoLabel.Label or uiRefs.playerInfoLabel.TextLabel
		if textLabel then
			textLabel.Size = UDim2.new(1, -10, 0, 50)
			textLabel.TextWrapped = true
			textLabel.TextScaled = false
			textLabel.TextXAlignment = Enum.TextXAlignment.Left
			textLabel.TextYAlignment = Enum.TextYAlignment.Top
		end
	end)

	local socialLinksGroup = uiRefs.Tabs.Home:AddRightGroupbox("Social Links", "link")
	socialLinksGroup:AddButton({
		Text = "Copy Discord Link",
		Func = function()
			setclipboard("https://discord.gg/Ggrqtyn9RW")
			notify("Discord link copied!")
		end,
	})
	socialLinksGroup:AddButton({
		Text = "Copy TikTok Link",
		Func = function()
			setclipboard("https://www.tiktok.com/@komtolmmek2script")
			notify("TikTok link copied!")
		end,
	})
	socialLinksGroup:AddButton({
		Text = "Copy Donate Link",
		Func = function()
			setclipboard("https://sociabuzz.com/cyraaaja/tribe")
			notify("Donate link copied!")
		end,
	})

	-- Farm: collectible automation ------------------------------------------
	local autoCollectGroup = uiRefs.Tabs.Farm:AddLeftGroupbox("Auto Collect", "boxes")
	autoCollectGroup:AddSlider("CollectInterval", {
		Text = "Collect Interval",
		Default = 1,
		Min = 0.5,
		Max = 10,
		Rounding = 1,
		Callback = function(seconds)
			getgenv().autoCollectInterval = seconds
		end,
	})
	uiRefs.collectItemDropdown = autoCollectGroup:AddDropdown("CollectItems", {
		Values = { "Any" },
		Default = {},
		Text = "Select Items",
		Multi = true,
		Callback = function(selection)
			getgenv().selectedCollectItems = normalizeSelection(selection)
		end,
	})
	autoCollectGroup:AddButton({
		Text = "Refresh Item List",
		Func = function()
			if isRefreshingCollectList then
				return
			end
			isRefreshingCollectList = true

			task.spawn(function()
				local itemNames = getCollectibleItemNames()
				table.sort(itemNames)

				local previousNames = {}
				for _, itemName in ipairs(cachedCollectItemNames) do
					previousNames[itemName] = true
				end

				local unchanged = #itemNames == #cachedCollectItemNames
				if unchanged then
					for _, itemName in ipairs(itemNames) do
						if not previousNames[itemName] then
							unchanged = false
							break
						end
					end
				end

				if unchanged and #itemNames > 0 then
					notify("No changes in items")
					isRefreshingCollectList = false
					return
				end

				cachedCollectItemNames = itemNames
				pcall(function()
					local dropdownValues = { "Any" }
					for _, itemName in ipairs(itemNames) do
						table.insert(dropdownValues, itemName)
					end
					uiRefs.collectItemDropdown:SetValues(dropdownValues)
					uiRefs.collectItemDropdown:SetValue({})
					getgenv().selectedCollectItems = {}
				end)

				if #itemNames == 0 then
					pcall(function()
						uiRefs.collectItemDropdown:SetValues({ "Any", "No items found" })
						uiRefs.collectItemDropdown:SetValue({})
					end)
					notify("No items found in your plot")
				else
					notify("Found " .. #itemNames .. " collectible items (ClansHub excluded)")
				end

				task.wait(1)
				isRefreshingCollectList = false
			end)
		end,
	})
	autoCollectGroup:AddToggle("AutoCollect", {
		Text = "Auto Collect",
		Default = false,
		Callback = function(enabled)
			getgenv().autoCollectRunning = enabled
			if enabled then
				notify("Auto Collect enabled")
				spawnFlaggedWorker("autoCollectRunning", function()
					return getgenv().autoCollectInterval
				end, collectSelectedItems)
			end
		end,
	})

	-- Farm: Battle Pass and quest claims ------------------------------------
	local battlePassGroup = uiRefs.Tabs.Farm:AddLeftGroupbox("Battlepass", "star")
	battlePassGroup:AddDropdown("BPTrack", {
		Values = { "Free", "Premium" },
		Default = "Free",
		Text = "Track",
		Callback = function(trackName)
			getgenv().autoBPTrack = trackName
		end,
	})
	battlePassGroup:AddToggle("AutoClaimBP", {
		Text = "Auto Claim BP Rewards",
		Default = false,
		Callback = function(enabled)
			getgenv().autoBPClaimRunning = enabled
			if enabled then
				notify("Auto Claim BP Rewards enabled")
				spawnFlaggedWorker("autoBPClaimRunning", 10, claimBattlePassRewards)
			end
		end,
	})
	battlePassGroup:AddToggle("AutoCollectBPCoins", {
		Text = "Auto Collect BP Tickets",
		Default = false,
		Callback = function(enabled)
			getgenv().autoBPCoinsRunning = enabled
			if enabled then
				notify("Auto Collect BP Tickets enabled")
				spawnFlaggedWorker("autoBPCoinsRunning", 5, collectBattlePassPickups)
			end
		end,
	})
	battlePassGroup:AddButton({
		Text = "Claim All BP Now",
		Func = function()
			task.spawn(function()
				pcall(claimBattlePassRewards)
				notify("Claimed all BP rewards")
			end)
		end,
	})
	battlePassGroup:AddButton({
		Text = "Collect BP Tickets Now",
		Func = function()
			task.spawn(function()
				local succeeded, collectedOrError = pcall(collectBattlePassPickups)
				if not succeeded then
					notify("BP Ticket collection failed: " .. tostring(collectedOrError))
				elseif collectedOrError > 0 then
					notify("Sent collect requests for " .. collectedOrError .. " BP Ticket(s)")
				else
					notify("No BP Tickets found")
				end
			end)
		end,
	})
	battlePassGroup:AddDivider()
	battlePassGroup:AddDropdown("QuestDifficulty", {
		Values = { "Any", "Easy", "Medium", "Hard", "Insane" },
		Default = { "Any" },
		Text = "Quest Difficulty Filter",
		Multi = true,
		Callback = function(selection)
			getgenv().selectedQuestDifficulty = normalizeSelection(selection)
		end,
	})
	battlePassGroup:AddToggle("AutoClaimQuest", {
		Text = "Auto Claim Quest",
		Default = false,
		Callback = function(enabled)
			getgenv().autoClaimQuestRunning = enabled
			if enabled then
				notify("Auto Claim Quest enabled")
				spawnFlaggedWorker("autoClaimQuestRunning", 10, claimSelectedQuests)
			end
		end,
	})
	battlePassGroup:AddButton({
		Text = "Claim Quests Now",
		Func = function()
			task.spawn(function()
				pcall(claimSelectedQuests)
				notify("Quest claim attempted")
			end)
		end,
	})

	-- Farm: live market display ---------------------------------------------
	uiRefs.marketHolder, uiRefs.marketContainer = Library:AddDraggableMenu("Market Prices")
	uiRefs.marketHolder.Visible = false
	uiRefs.marketContainer.Size = UDim2.new(0, 310, 0, 390)
	uiRefs.marketContainer.AutomaticSize = Enum.AutomaticSize.None

	uiRefs.marketLabel = Instance.new("TextLabel")
	uiRefs.marketLabel.Text = "Loading market data..."
	uiRefs.marketLabel.Size = UDim2.new(0, 300, 0, 355)
	uiRefs.marketLabel.Position = UDim2.new(0, 5, 0, 5)
	uiRefs.marketLabel.BackgroundTransparency = 1
	uiRefs.marketLabel.TextColor3 = Color3.new(1, 1, 1)
	uiRefs.marketLabel.TextXAlignment = Enum.TextXAlignment.Left
	uiRefs.marketLabel.TextYAlignment = Enum.TextYAlignment.Top
	uiRefs.marketLabel.TextWrapped = true
	uiRefs.marketLabel.Font = Enum.Font.SourceSans
	uiRefs.marketLabel.TextSize = 15
	uiRefs.marketLabel.ZIndex = 11
	uiRefs.marketLabel.Parent = uiRefs.marketContainer

	uiRefs.marketTimerLabel = Instance.new("TextLabel")
	uiRefs.marketTimerLabel.Text = "Next Price Update: Calculating..."
	uiRefs.marketTimerLabel.Size = UDim2.new(0, 300, 0, 22)
	uiRefs.marketTimerLabel.Position = UDim2.new(0, 5, 0, 362)
	uiRefs.marketTimerLabel.BackgroundTransparency = 1
	uiRefs.marketTimerLabel.TextColor3 = Color3.new(0.7, 0.7, 0.7)
	uiRefs.marketTimerLabel.TextXAlignment = Enum.TextXAlignment.Left
	uiRefs.marketTimerLabel.ZIndex = 11
	uiRefs.marketTimerLabel.Font = Enum.Font.SourceSans
	uiRefs.marketTimerLabel.TextSize = 15
	uiRefs.marketTimerLabel.Parent = uiRefs.marketContainer

	local function formatMarketDisplay()
		if not ClientData or not ResourcesConfig then
			return "Waiting for game data..."
		end

		local stateReadSucceeded, gameState = pcall(function()
			return ClientData.gameProducer:getState()
		end)
		if not stateReadSucceeded or not gameState or not gameState.market then
			return "Market not found"
		end

		local market = gameState.market
		nextMarketUpdateAt = market.nextInterval

		local displayEntries = {}
		for resourceId, stockMultiplier in pairs(market.stock) do
			local resource = ResourcesConfig[resourceId]
			if resource and not resource.dontDisplayInMarket then
				local multiplier, nuclearBoosted =
					getAdjustedMarketMultiplier(gameState, resourceId, stockMultiplier)

				local salePrice = math.round(resource.Price * multiplier) * 2
				local percentChange = math.round((multiplier - 1) * 100)
				local direction = if percentChange > 0 then "↑" elseif percentChange < 0 then "↓" else "→"
				local prefix = nuclearBoosted and "☢ " or ""
				table.insert(displayEntries, {
					value = percentChange,
					text = prefix
						.. direction
						.. " "
						.. resource.Name
						.. " | "
						.. (percentChange > 0 and "+" or "")
						.. percentChange
						.. "% | "
						.. salePrice
						.. "$",
				})
			end
		end

		table.sort(displayEntries, function(left, right)
			return left.value > right.value
		end)
		if #displayEntries == 0 then
			return "No market items found..."
		end

		local lines = {}
		for _, entry in ipairs(displayEntries) do
			table.insert(lines, entry.text)
		end
		return table.concat(lines, "\n")
	end

	local function refreshMarketDisplay()
		pcall(function()
			uiRefs.marketLabel.Text = formatMarketDisplay()
		end)
	end

	task.spawn(function()
		while runtimeActive and not ClientData do
			task.wait(0.5)
		end
		if not runtimeActive then
			return
		end
		pcall(function()
			ClientData.gameProducer:subscribe(function(state)
				return state.market
			end, refreshMarketDisplay)
		end)
		pcall(function()
			ClientData.gameProducer:subscribe(function(state)
				return state.nuclearMarketBoosts
			end, refreshMarketDisplay)
		end)
		pcall(function()
			ClientData.playerProducer:subscribe(function(state)
				return state.player and state.player.skills
			end, refreshMarketDisplay)
		end)
		refreshMarketDisplay()
	end)

	task.spawn(function()
		while runtimeActive do
			task.wait(1)
			pcall(function()
				if not nextMarketUpdateAt then
					uiRefs.marketTimerLabel.Text = "Next Price Update: Calculating..."
					return
				end
				local remainingSeconds = math.max(0, nextMarketUpdateAt - Workspace:GetServerTimeNow())
				local minutes = math.floor(remainingSeconds / 60)
				local seconds = math.floor(remainingSeconds % 60)
				uiRefs.marketTimerLabel.Text = "Next Price Update: " .. minutes .. "m " .. seconds .. "s"
			end)
		end
	end)

	local marketDisplayGroup = uiRefs.Tabs.Farm:AddRightGroupbox("Market Display", "chart")
	marketDisplayGroup:AddToggle("ShowMarket", {
		Text = "Show Market Prices",
		Default = false,
		Callback = function(visible)
			getgenv().showMarketMenu = visible
			uiRefs.marketHolder.Visible = visible
			notify(visible and "Market window opened" or "Market window closed")
		end,
	})
	marketDisplayGroup:AddButton({
		Text = "Refresh Market Data",
		Func = function()
			refreshMarketDisplay()
			notify("Market data refreshed")
		end,
	})
	marketDisplayGroup:AddSlider("MarketBonusPercent", {
		Text = "Sell Bonus % Calibration",
		Default = 0,
		Min = -20,
		Max = 20,
		Rounding = 0,
		Callback = function(percent)
			getgenv().marketBonusPercent = percent
			refreshMarketDisplay()
		end,
	})

	-- Farm: resource selling -------------------------------------------------
	local autoSellGroup = uiRefs.Tabs.Farm:AddRightGroupbox("Auto Sell", "coins")
	autoSellGroup:AddSlider("SellInterval", {
		Text = "Sell Interval",
		Default = 10,
		Min = 1,
		Max = 60,
		Rounding = 0,
		Callback = function(seconds)
			getgenv().autoSellInterval = seconds
		end,
	})
	autoSellGroup:AddSlider("SellMinPercent", {
		Text = "Min Price Percent",
		Default = 0,
		Min = 0,
		Max = 100,
		Rounding = 0,
		Callback = function(percent)
			getgenv().autoSellMinPercent = percent
		end,
	})
	autoSellGroup:AddDropdown("SellMarketCondition", {
		Values = { "Price Up", "Price Down" },
		Default = "Price Up",
		Text = "Market Condition",
		Callback = function(condition)
			getgenv().autoSellMarketCondition = condition
		end,
	})
	uiRefs.sellItemsDropdown = autoSellGroup:AddDropdown("SellItems", {
		Values = prependAny(sellableResourceNames),
		Default = {},
		Text = "Select Items to Sell",
		Multi = true,
		Callback = function(selection)
			getgenv().selectedSellItems = normalizeSelection(selection)
		end,
	})
	autoSellGroup:AddToggle("AutoSell", {
		Text = "Auto Sell",
		Default = false,
		Callback = function(enabled)
			getgenv().autoSellRunning = enabled
			if enabled then
				notify("Auto Sell enabled")
				spawnFlaggedWorker("autoSellRunning", function()
					return getgenv().autoSellInterval
				end, function()
					sellSelectedResources(false)
				end)
			end
		end,
	})
	autoSellGroup:AddToggle("AutoSellMarket", {
		Text = "Auto Sell by Market",
		Default = false,
		Callback = function(enabled)
			getgenv().autoSellByMarketRunning = enabled
			if enabled then
				notify("Market Sell enabled")
				spawnFlaggedWorker("autoSellByMarketRunning", function()
					return getgenv().autoSellInterval
				end, function()
					sellSelectedResources(true)
				end)
			end
		end,
	})
	autoSellGroup:AddButton({
		Text = "Sell All Now",
		Func = function()
			pcall(function()
				sellSelectedResources(false)
			end)
			notify("Sold all items")
		end,
	})

	-- Farm: research and clan upgrades --------------------------------------
	local autoUpgradeGroup = uiRefs.Tabs.Farm:AddRightGroupbox("Auto Upgrade Research", "arrow-up")

	local skillDropdownValues = { "None", "Any" }
	for _, skillName in ipairs(upgradeNames) do
		table.insert(skillDropdownValues, skillName)
	end
	uiRefs.statsDropdown = autoUpgradeGroup:AddDropdown("UpgradeStats", {
		Values = skillDropdownValues,
		Default = {},
		Text = "Select Skills",
		Multi = true,
		Callback = function(selection)
			getgenv().selectedUpgradeStat = normalizeSelection(selection)
		end,
	})

	local fallbackClanUpgradeNames = {
		"Start",
		"CashBoost1",
		"BiggerClan",
		"BuildingSpeed1",
		"CashBoost2",
		"VehicleHealth1",
		"BuildingSpeed2",
		"CashBoost3",
		"BetterManagement",
		"BuildingSpeed3",
		"CashBoost4",
		"ReserchSpeed1",
		"BuildingSpeed4",
		"CashBoost5",
		"ReserchSpeed2",
		"ClanBuilders",
		"Civilians1",
		"ConquerLimit1",
		"BuildingSpeed5",
		"CashBoost6",
		"VehicleHealth2",
		"ClanBuilders2",
		"Civilians2",
		"VehicleDamage1",
		"BuildingSpeed6",
	}
	local clanUpgradeNames = {}
	if ClanUpgradeTreeConfig then
		for nodeName in pairs(ClanUpgradeTreeConfig.Nodes) do
			table.insert(clanUpgradeNames, nodeName)
		end
		table.sort(clanUpgradeNames)
	else
		clanUpgradeNames = fallbackClanUpgradeNames
	end

	local clanDropdownValues = { "None", "Any" }
	for _, nodeName in ipairs(clanUpgradeNames) do
		table.insert(clanDropdownValues, nodeName)
	end
	uiRefs.clanUpgradeDropdown = autoUpgradeGroup:AddDropdown("ClanUpgrades", {
		Values = clanDropdownValues,
		Default = {},
		Text = "Select Clan Upgrades",
		Multi = true,
		Callback = function(selection)
			getgenv().selectedClanUpgrades = normalizeSelection(selection)
		end,
	})

	local function runAutoUpgrade()
		local playerState = getPlayerState()
		if not playerState then
			return
		end

		local skillState = playerState.skills
		local availableMoney = tonumber(playerState.money) or 0
		local selectedSkills = getgenv().selectedUpgradeStat
		local upgradeAnySkill = containsValue(selectedSkills, "Any")
		local filterSkills = not upgradeAnySkill and #selectedSkills > 0
		local selectedSkillSet = {}
		if filterSkills then
			for _, skillName in ipairs(selectedSkills) do
				selectedSkillSet[skillName] = true
			end
		end

		if
			skillState
			and not (skillState.currentlyUnlockingSkills and next(skillState.currentlyUnlockingSkills))
		then
			for skillName, canUnlock in pairs(skillState.skillsThatCanBeUnlocked or {}) do
				if canUnlock and (not filterSkills or selectedSkillSet[skillName]) then
					local skillConfig = SkillsConfig and SkillsConfig[skillName]
					if skillConfig and availableMoney >= (skillConfig.Cost or 0) then
						fireBridge("TryToBuySkill", skillName)
						task.wait(0.5)
					end
				end
			end
		end

		fireBridge("ClanGetResearch")
		local clanResearchData = latestClanResearchData
		if type(clanResearchData) ~= "table" then
			return
		end

		local selectedClanNodes = getgenv().selectedClanUpgrades
		local upgradeAnyClanNode = containsValue(selectedClanNodes, "Any")
		local filterClanNodes = not upgradeAnyClanNode and #selectedClanNodes > 0
		local selectedClanNodeSet = {}
		if filterClanNodes then
			for _, nodeName in ipairs(selectedClanNodes) do
				selectedClanNodeSet[nodeName] = true
			end
		end

		local clanNodes = ClanUpgradeTreeConfig and ClanUpgradeTreeConfig.Nodes
		if not clanNodes then
			return
		end

		local availableNodeSet = {}
		for key, value in pairs(clanResearchData.availableNodes or {}) do
			local nodeName = type(key) == "number" and value or key
			if type(nodeName) == "string" and value ~= false then
				availableNodeSet[nodeName] = true
			end
		end

		local activeNodeSet = {}
		for _, activeResearch in pairs(clanResearchData.active or {}) do
			if type(activeResearch) == "table" and type(activeResearch.node_id) == "string" then
				activeNodeSet[activeResearch.node_id] = true
			end
		end

		local completedNodeSet = clanResearchData.completedSet or {}
		local clanTrophies = tonumber(clanResearchData.clanTrophies) or 0
		for nodeName, nodeConfig in pairs(clanNodes) do
			if
				(not filterClanNodes or selectedClanNodeSet[nodeName])
				and availableNodeSet[nodeName]
				and not activeNodeSet[nodeName]
				and not completedNodeSet[nodeName]
				and clanTrophies >= (tonumber(nodeConfig.TrophiesRequired) or 0)
			then
				if fireBridge("ClanStartResearch", { node_id = nodeName }) then
					task.delay(0.5, function()
						if runtimeActive then
							fireBridge("ClanGetResearch")
						end
					end)
					break
				end
			end
		end
	end

	autoUpgradeGroup:AddToggle("AutoUpgradeStats", {
		Text = "Auto Upgrade Research",
		Default = false,
		Callback = function(enabled)
			getgenv().autoUpgradeStatsRunning = enabled
			if enabled then
				notify("Auto Upgrade Research enabled")
				spawnFlaggedWorker("autoUpgradeStatsRunning", 4, runAutoUpgrade)
			end
		end,
	})

	-- Farm: raid monitor and general attack rotation ------------------------
	local autoAttackGroup = uiRefs.Tabs.Farm:AddLeftGroupbox("Auto Attack", "crosshair")
	uiRefs.raidStatusLabel = autoAttackGroup:AddLabel("Raid Status: Checking...")

	task.spawn(function()
		while runtimeActive do
			task.wait(2)
			pcall(function()
				local raidTargets = getAvailableRaidTargets()
				if isBeastBreachActive() then
					local otherRaidNames = {}
					if #raidTargets > 1 then
						for _, target in ipairs(raidTargets) do
							if raidNameByTarget[target] ~= "BeastBreach" then
								table.insert(otherRaidNames, target.Name)
							end
						end
					end
					local additionalRaids = if #otherRaidNames > 0
						then " | Also: " .. table.concat(otherRaidNames, ", ")
						else ""
					uiRefs.raidStatusLabel:SetText(
						"Raid Status: Beast Breach Active | HP " .. tostring(getBeastHealth()) .. "%" .. additionalRaids
					)
					return
				end

				if #raidTargets > 0 then
					local raidNames = {}
					for _, target in ipairs(raidTargets) do
						table.insert(raidNames, target.Name)
					end
					uiRefs.raidStatusLabel:SetText("Raid Status: ACTIVE | " .. table.concat(raidNames, ", "))
					return
				end

				local riotBoss = findLivingRiotNpc()
				local fallenGeneral = findLivingFallenGeneral()
				if riotBoss and isWeatherActive("Rebellion") then
					uiRefs.raidStatusLabel:SetText("Raid Status: Riot Boss Active | " .. riotBoss.Name)
				elseif fallenGeneral and isWeatherActive("Invasion") then
					uiRefs.raidStatusLabel:SetText("Raid Status: Fallen General Boss Active | " .. fallenGeneral.Name)
				else
					uiRefs.raidStatusLabel:SetText("Raid Status: No raid event active.")
				end
			end)
		end
	end)

	autoAttackGroup:AddDropdown("AttackMode", {
		Values = { "Any", "Army", "Rocket" },
		Default = "Any",
		Text = "Attack Mode",
		Callback = function(mode)
			getgenv().attackMode = mode
		end,
	})
	autoAttackGroup:AddSlider("AttackDelay", {
		Text = "Attack Delay",
		Default = 5,
		Min = 1,
		Max = 30,
		Rounding = 0,
		Callback = function(seconds)
			getgenv().autoAttackDelay = seconds
		end,
	})
	autoAttackGroup:AddSlider("AttackSwitchTime", {
		Text = "Switch Time (seconds)",
		Default = 900,
		Min = 30,
		Max = 3600,
		Rounding = 0,
		Callback = function(seconds)
			getgenv().autoAttackSwitchTime = seconds
		end,
	})

	autoAttackGroup:AddDropdown("AttackP1", {
		Values = attackPriorityNames,
		Default = "Laboratory1",
		Text = "Priority 1",
		Callback = function(targetName)
			getgenv().attackPriority1 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP1", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 1",
		Callback = function(index)
			getgenv().attackArmyIndex1 = tonumber(index)
		end,
	})
	autoAttackGroup:AddDropdown("AttackP2", {
		Values = attackPriorityNames,
		Default = "Laboratory2",
		Text = "Priority 2",
		Callback = function(targetName)
			getgenv().attackPriority2 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP2", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 2",
		Callback = function(index)
			getgenv().attackArmyIndex2 = tonumber(index)
		end,
	})
	autoAttackGroup:AddDropdown("AttackP3", {
		Values = attackPriorityNames,
		Default = "Laboratory3",
		Text = "Priority 3",
		Callback = function(targetName)
			getgenv().attackPriority3 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP3", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 3",
		Callback = function(index)
			getgenv().attackArmyIndex3 = tonumber(index)
		end,
	})
	autoAttackGroup:AddDropdown("AttackP4", {
		Values = attackPriorityNames,
		Default = "Laboratory4",
		Text = "Priority 4",
		Callback = function(targetName)
			getgenv().attackPriority4 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP4", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 4",
		Callback = function(index)
			getgenv().attackArmyIndex4 = tonumber(index)
		end,
	})
	autoAttackGroup:AddDropdown("AttackP5", {
		Values = attackPriorityNames,
		Default = "Laboratory5",
		Text = "Priority 5",
		Callback = function(targetName)
			getgenv().attackPriority5 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP5", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 5",
		Callback = function(index)
			getgenv().attackArmyIndex5 = tonumber(index)
		end,
	})
	autoAttackGroup:AddDropdown("AttackP6", {
		Values = attackPriorityNames,
		Default = "Laboratory6",
		Text = "Priority 6",
		Callback = function(targetName)
			getgenv().attackPriority6 = targetName
		end,
	})
	autoAttackGroup:AddDropdown("ArmyIndexP6", {
		Values = { "1", "2", "3", "4", "5", "6" },
		Default = "1",
		Text = "Army Index 6",
		Callback = function(index)
			getgenv().attackArmyIndex6 = tonumber(index)
		end,
	})

	autoAttackGroup:AddToggle("AutoAttack", {
		Text = "Auto Attack",
		Default = false,
		Callback = function(enabled)
			getgenv().autoAttackRunning = enabled
			if not enabled then
				return
			end
			notify("Auto Attack enabled")

			task.spawn(function()
				local prioritySettingNames = {
					"attackPriority1",
					"attackPriority2",
					"attackPriority3",
					"attackPriority4",
					"attackPriority5",
					"attackPriority6",
				}
				local armySettingNames = {
					"attackArmyIndex1",
					"attackArmyIndex2",
					"attackArmyIndex3",
					"attackArmyIndex4",
					"attackArmyIndex5",
					"attackArmyIndex6",
				}
				local currentPriority = 1
				local lastPrioritySwitch = tick()

				while runtimeActive and getgenv().autoAttackRunning do
					local cycleSucceeded = pcall(function()
						local attackMode = getgenv().attackMode or "Any"
						local raidTargets = getAvailableRaidTargets()
						local riotBoss = findLivingRiotNpc()
						local fallenGeneral = findLivingFallenGeneral()
						local handledRaid = false

						if isBeastBreachActive() then
							local militaryTown = getMilitaryTown()
							if militaryTown then
								deployForcesToTarget(militaryTown, getgenv().raidArmyIndex5 or 1, attackMode)
								handledRaid = true
							end
						end

						-- MoonVeil's source performed this dispatch independently
						-- of Beast Breach, so one cycle may submit both actions.
						if #raidTargets > 0 then
							local armyIndex = getgenv()[armySettingNames[currentPriority]] or 1
							attackHighestPriorityRaid(armyIndex, attackMode)
							handledRaid = true
						elseif riotBoss and isWeatherActive("Rebellion") then
							local armyIndex = getgenv()[armySettingNames[currentPriority]] or 1
							deployForcesToTarget(riotBoss, armyIndex, attackMode)
							handledRaid = true
						elseif fallenGeneral and isWeatherActive("Invasion") then
							local militaryTown = getMilitaryTown()
							if militaryTown then
								local armyIndex = getgenv()[armySettingNames[currentPriority]] or 1
								deployForcesToTarget(militaryTown, armyIndex, attackMode)
								handledRaid = true
							end
						end

						if not handledRaid then
							local targetName = getgenv()[prioritySettingNames[currentPriority]]
							if targetName and targetName ~= "Skip" and targetName ~= "RaidEvent" then
								local armyIndex = getgenv()[armySettingNames[currentPriority]] or 1
								attackTarget(targetName, armyIndex, attackMode)
							end
						end
					end)
					if not cycleSucceeded then
						task.wait(1)
					end

					task.wait(getgenv().autoAttackDelay)
					if tick() - lastPrioritySwitch >= getgenv().autoAttackSwitchTime then
						lastPrioritySwitch = tick()
						currentPriority = (currentPriority % 6) + 1
						local targetName = getgenv()[prioritySettingNames[currentPriority]] or "Skip"
						notify(
							"Attack switched to Priority " .. currentPriority .. ": " .. targetName,
							3,
							"Green",
							"Auto Attack",
							"Switched"
						)
					end
				end
			end)
		end,
	})

	-- Farm: raid-specific priority policy -----------------------------------
	local raidPriorityGroup = uiRefs.Tabs.Farm:AddRightGroupbox("Raid Settings Priority", "flag")
	local armyIndexValues = { "1", "2", "3", "4", "5", "6" }

	raidPriorityGroup:AddDropdown("RaidP1", {
		Values = raidPriorityNames,
		Default = "KingOfTheHillBase",
		Text = "Raid Priority 1",
		Callback = function(targetName)
			getgenv().raidPriority1 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy1", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 1",
		Callback = function(index)
			getgenv().raidArmyIndex1 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP2", {
		Values = raidPriorityNames,
		Default = "ToxicKingOfTheHillBase",
		Text = "Raid Priority 2",
		Callback = function(targetName)
			getgenv().raidPriority2 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy2", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 2",
		Callback = function(index)
			getgenv().raidArmyIndex2 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP3", {
		Values = raidPriorityNames,
		Default = "RiotBase",
		Text = "Raid Priority 3",
		Callback = function(targetName)
			getgenv().raidPriority3 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy3", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 3",
		Callback = function(index)
			getgenv().raidArmyIndex3 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP4", {
		Values = raidPriorityNames,
		Default = "CargoBase",
		Text = "Raid Priority 4",
		Callback = function(targetName)
			getgenv().raidPriority4 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy4", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 4",
		Callback = function(index)
			getgenv().raidArmyIndex4 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP5", {
		Values = raidPriorityNames,
		Default = "BeastBreach",
		Text = "Raid Priority 5",
		Callback = function(targetName)
			getgenv().raidPriority5 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy5", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 5",
		Callback = function(index)
			getgenv().raidArmyIndex5 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP6", {
		Values = raidPriorityNames,
		Default = "MeteorCargo",
		Text = "Raid Priority 6",
		Callback = function(targetName)
			getgenv().raidPriority6 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy6", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 6",
		Callback = function(index)
			getgenv().raidArmyIndex6 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP7", {
		Values = raidPriorityNames,
		Default = "MeteorGems",
		Text = "Raid Priority 7",
		Callback = function(targetName)
			getgenv().raidPriority7 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy7", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 7",
		Callback = function(index)
			getgenv().raidArmyIndex7 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP8", {
		Values = raidPriorityNames,
		Default = "Invaded",
		Text = "Raid Priority 8",
		Callback = function(targetName)
			getgenv().raidPriority8 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy8", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 8",
		Callback = function(index)
			getgenv().raidArmyIndex8 = tonumber(index)
		end,
	})
	raidPriorityGroup:AddDropdown("RaidP9", {
		Values = raidPriorityNames,
		Default = "Hacker",
		Text = "Raid Priority 9",
		Callback = function(targetName)
			getgenv().raidPriority9 = targetName
		end,
	})
	raidPriorityGroup:AddDropdown("RaidArmy9", {
		Values = armyIndexValues,
		Default = "1",
		Text = "Army Index 9",
		Callback = function(index)
			getgenv().raidArmyIndex9 = tonumber(index)
		end,
	})

	-- Farm: mastery deployment ----------------------------------------------
	local masteryArmyGroup = uiRefs.Tabs.Farm:AddRightGroupbox("Mastery Army", "crosshair")

	local function findCapturePointByName(targetName)
		for _, capturePoint in ipairs(CollectionService:GetTagged("CapturePoint")) do
			if capturePoint.Name == targetName then
				return capturePoint
			end
		end
		return nil
	end

	local function findFirstEnemyCapturePoint()
		for _, capturePoint in ipairs(CollectionService:GetTagged("CapturePoint")) do
			if not isOwnedByLocalPlayer(capturePoint) then
				return capturePoint
			end
		end
		return nil
	end

	uiRefs.capturePointDropdown = masteryArmyGroup:AddDropdown("CapturePointTarget", {
		Values = { "Any", "RaidEvent" },
		Default = "Any",
		Text = "Target Capture Point",
		Callback = function(targetName)
			if targetName == "Any" then
				getgenv().masterArmyTarget = nil
			elseif targetName == "RaidEvent" then
				getgenv().masterArmyTarget = "RaidEvent"
			else
				local capturePoint = findCapturePointByName(targetName)
				if capturePoint then
					getgenv().masterArmyTarget = capturePoint
				end
			end
		end,
	})

	local function refreshCapturePointTargets()
		pcall(function()
			local enemyCapturePointNames = {}
			for _, capturePoint in ipairs(CollectionService:GetTagged("CapturePoint")) do
				if not isOwnedByLocalPlayer(capturePoint) then
					table.insert(enemyCapturePointNames, capturePoint.Name)
				end
			end

			local dropdownValues = { "Any", "RaidEvent" }
			for _, capturePointName in ipairs(enemyCapturePointNames) do
				table.insert(dropdownValues, capturePointName)
			end
			uiRefs.capturePointDropdown:SetValues(dropdownValues)

			local selectedTarget = getgenv().masterArmyTarget
			if selectedTarget == "RaidEvent" then
				uiRefs.capturePointDropdown:SetValue("RaidEvent")
			elseif
				selectedTarget
				and typeof(selectedTarget) == "Instance"
				and selectedTarget.Parent
				and selectedTarget.Name
				and containsValue(enemyCapturePointNames, selectedTarget.Name)
			then
				uiRefs.capturePointDropdown:SetValue(selectedTarget.Name)
			else
				uiRefs.capturePointDropdown:SetValue("Any")
				getgenv().masterArmyTarget = nil
			end
		end)
	end

	task.spawn(function()
		task.wait(3)
		refreshCapturePointTargets()
	end)
	task.spawn(function()
		while runtimeActive do
			task.wait(5)
			refreshCapturePointTargets()
		end
	end)

	masteryArmyGroup:AddDropdown("MasteryArmyIndex", {
		Values = { "1", "2", "3", "4", "5", "6", "Any" },
		Default = "1",
		Text = "Army Index",
		Callback = function(index)
			getgenv().masterArmyIndex = index == "Any" and "Any" or tonumber(index)
		end,
	})
	masteryArmyGroup:AddToggle("MasteryDeploy", {
		Text = "Auto Deploy Troops",
		Default = false,
		Callback = function(enabled)
			getgenv().masterArmyDeploy = enabled
			if enabled then
				notify("Mastery Deploy enabled")
			end
		end,
	})
	masteryArmyGroup:AddToggle("MasteryRockets", {
		Text = "Auto Rockets",
		Default = false,
		Callback = function(enabled)
			getgenv().masterArmyRockets = enabled
			if enabled then
				notify("Mastery Rockets enabled")
			end
		end,
	})
	masteryArmyGroup:AddButton({
		Text = "Refresh Capture Points",
		Func = function()
			refreshCapturePointTargets()
			notify("Refreshed capture points")
		end,
	})

	local function selectMasteryTarget()
		if isBeastBreachActive() then
			return getMilitaryTown()
		end

		local raidTargets = getAvailableRaidTargets()
		if #raidTargets > 0 then
			return raidTargets[1]
		end

		local selectedTarget = getgenv().masterArmyTarget
		if not selectedTarget or selectedTarget == "Any" then
			return findFirstEnemyCapturePoint()
		end
		return selectedTarget
	end

	task.spawn(function()
		while runtimeActive do
			if getgenv().masterArmyDeploy then
				local target = selectMasteryTarget()
				if target then
					local selectedArmyIndex = getgenv().masterArmyIndex
					if selectedArmyIndex == "Any" then
						for armyIndex = 1, 10 do
							deployForcesToTarget(target, armyIndex, "Army")
							task.wait(0.05)
						end
					else
						deployForcesToTarget(target, selectedArmyIndex, "Army")
					end
				end
			end
			task.wait(0.5)
		end
	end)

	task.spawn(function()
		while runtimeActive do
			if getgenv().masterArmyRockets then
				local target = selectMasteryTarget()
				if target then
					deployForcesToTarget(target, 1, "Rocket")
				end
			end
			task.wait(3)
		end
	end)

	-- Home player data is updated after all Farm controls are registered.
	task.spawn(function()
		while runtimeActive do
			pcall(function()
				local playerState = getPlayerState()
				if playerState then
					uiRefs.playerInfoLabel:SetText(
						string.format(
							"Cash: $%s\nGems: %s",
							tostring(playerState.money or 0),
							tostring(playerState.gems or 0)
						)
					)
				else
					uiRefs.playerInfoLabel:SetText("Player info not available")
				end
			end)
			task.wait(2)
		end
	end)
end

UI.createInterfaceShell = createInterfaceShell
UI.buildHomeFarmUi = buildHomeFarmUi

-- ============================================================================
-- Shop, teleport, and miscellaneous interface sections
-- ============================================================================

-- This builder is called by the final interface assembler after the shared
-- window/tabs and Home/Farm controls exist. It intentionally does not call
-- itself so the startup section retains control of initialization order.
local function buildShopTeleportMiscUi()
	-- ========================================================================
	-- Shop status and manual panels
	-- ========================================================================

	local shopControls = uiRefs.Tabs.Shop:AddLeftGroupbox("Shop Controls", "store")
	shopControls:AddDivider()
	uiRefs.shopRestockLabel = shopControls:AddLabel("Shop Restock: Loading...")
	uiRefs.blackMarketTimerLabelShop = shopControls:AddLabel("Black Market: Loading...")

	task.spawn(function()
		while runtimeActive do
			task.wait(1)

			pcall(function()
				local restockTimer = LocalPlayer.PlayerGui.MainUI.Fullscreen.BuyUI.Topbar.RestockTimer
				uiRefs.shopRestockLabel:SetText("Shop Restock: " .. restockTimer.Text)
			end)

			pcall(function()
				local blackMarketTimer = Workspace.BlackMarket.Main.Other.Part.BillboardGui.BlackMarketTimer
				uiRefs.blackMarketTimerLabelShop:SetText("Black Market: " .. blackMarketTimer.Text)
			end)
		end
	end)

	shopControls:AddButton({
		Text = "Open Shop",
		Func = function()
			pcall(function()
				LocalPlayer.PlayerGui.MainUI.Fullscreen.BuyUI.Visible = true
			end)
			notify("Shop opened!")
		end,
	})

	shopControls:AddButton({
		Text = "Open Black Market",
		Func = function()
			pcall(function()
				LocalPlayer.PlayerGui.MainUI.Fullscreen.BlackMarketUI.Visible = true
			end)
			notify("Black Market opened!")
		end,
	})

	shopControls:AddButton({
		Text = "Open Quests",
		Func = function()
			pcall(function()
				LocalPlayer.PlayerGui.MainUI.Fullscreen.QuestsUI.Visible = true
			end)
			notify("Quests opened!")
		end,
	})

	local houseGroup = uiRefs.Tabs.Shop:AddLeftGroupbox("House Buildings", "home")
	houseGroup:AddDropdown("HouseItems", {
		Values = prependAnyAndNone(houseItemNames),
		Default = {},
		Text = "Select Houses",
		Multi = true,
		Callback = function(selection)
			State.selectedHouseItem = normalizeSelection(selection)
		end,
	})

	local militaryGroup = uiRefs.Tabs.Shop:AddRightGroupbox("Military Buildings", "shield")
	militaryGroup:AddDropdown("MilItems", {
		Values = prependAnyAndNone(militaryItemNames),
		Default = {},
		Text = "Select Military",
		Multi = true,
		Callback = function(selection)
			State.selectedMilItem = normalizeSelection(selection)
		end,
	})

	local farmGroup = uiRefs.Tabs.Shop:AddLeftGroupbox("Farm Buildings", "wheat")
	farmGroup:AddDropdown("FarmItems", {
		Values = prependAnyAndNone(farmItemNames),
		Default = {},
		Text = "Select Farm",
		Multi = true,
		Callback = function(selection)
			State.selectedFarmItem = normalizeSelection(selection)
		end,
	})

	local specialDecorGroup = uiRefs.Tabs.Shop:AddRightGroupbox("Special & Decor", "star")
	specialDecorGroup:AddDropdown("SpecialItems", {
		Values = prependAnyAndNone(specialItemNames),
		Default = {},
		Text = "Select Special",
		Multi = true,
		Callback = function(selection)
			State.selectedSpecialItem = normalizeSelection(selection)
		end,
	})
	specialDecorGroup:AddDropdown("DecorItems", {
		Values = prependAnyAndNone(decorItemNames),
		Default = {},
		Text = "Select Decor",
		Multi = true,
		Callback = function(selection)
			State.selectedDecorItem = normalizeSelection(selection)
		end,
	})

	local blackMarketGroup = uiRefs.Tabs.Shop:AddLeftGroupbox("Black Market", "skull")
	blackMarketGroup:AddDropdown("BMItems", {
		Values = prependAnyAndNone(blackMarketItemNames),
		Default = {},
		Text = "Select Black Market",
		Multi = true,
		Callback = function(selection)
			State.selectedBlackMarketItem = normalizeSelection(selection)
		end,
	})

	-- ========================================================================
	-- Automated purchasing and building placement
	-- ========================================================================

	local purchaseGroup = uiRefs.Tabs.Shop:AddRightGroupbox("Auto Buy & Place", "cart")

	local function collectSelectedShopItems()
		local selectedItems = {}

		local function appendSelectedCategory(selection, allCategoryItems)
			if not selection or #selection == 0 then
				return
			end

			for _, itemName in ipairs(selection) do
				if itemName == "None" then
					return
				end
			end

			local includesAny = false
			for _, itemName in ipairs(selection) do
				if itemName == "Any" then
					includesAny = true
					break
				end
			end

			local itemsToAppend = includesAny and allCategoryItems or selection
			for _, itemName in ipairs(itemsToAppend) do
				selectedItems[itemName] = true
			end
		end

		appendSelectedCategory(State.selectedHouseItem, houseItemNames)
		appendSelectedCategory(State.selectedMilItem, militaryItemNames)
		appendSelectedCategory(State.selectedFarmItem, farmItemNames)
		appendSelectedCategory(State.selectedSpecialItem, specialItemNames)
		appendSelectedCategory(State.selectedDecorItem, decorItemNames)
		appendSelectedCategory(State.selectedBlackMarketItem, blackMarketItemNames)

		return selectedItems
	end

	purchaseGroup:AddSlider("BuySpeed", {
		Text = "Buy Delay (seconds)",
		Default = 0.3,
		Min = 0.1,
		Max = 2,
		Rounding = 1,
		Callback = function(value)
			State.autoBuyDelay = value
		end,
	})

	purchaseGroup:AddDivider()
	purchaseGroup:AddToggle("AutoBuySelect", {
		Text = "Auto Buy Selected",
		Default = false,
		Callback = function(enabled)
			State.autoBuyRunning = enabled
			if enabled then
				notify("Auto Buy Selected enabled")
				task.spawn(function()
					while runtimeActive and State.autoBuyRunning do
						local selectedItems = collectSelectedShopItems()
						pcall(function()
							buySelectedItems(selectedItems)
						end)
						task.wait(2)
					end
				end)
			end
		end,
	})

	purchaseGroup:AddToggle("AutoBuyAll", {
		Text = "Auto Buy All",
		Default = false,
		Callback = function(enabled)
			State.autoBuyAllRunning = enabled
			if enabled then
				notify("Auto Buy All enabled")
				task.spawn(function()
					while runtimeActive and State.autoBuyAllRunning do
						pcall(buyAllAvailableItems)
						task.wait(2)
					end
				end)
			end
		end,
	})

	purchaseGroup:AddDivider()
	purchaseGroup:AddButton({
		Text = "Buy Selected Once",
		Func = function()
			local selectedItems = collectSelectedShopItems()
			if not next(selectedItems) then
				notify("No items selected!")
				return
			end

			pcall(function()
				buySelectedItems(selectedItems)
			end)
			notify("Bought selected items")
		end,
	})

	purchaseGroup:AddButton({
		Text = "Buy All Now",
		Func = function()
			pcall(buyAllAvailableItems)
			notify("Bought all available items")
		end,
	})

	purchaseGroup:AddDivider()
	purchaseGroup:AddSlider("PlaceInterval", {
		Text = "Place Interval",
		Default = 1,
		Min = 0.5,
		Max = 10,
		Rounding = 1,
		Callback = function(value)
			State.autoPlaceInterval = value
		end,
	})

	local function findBestBuildableItem()
		local playerState = getPlayerState()
		if not playerState or not playerState.backpack or not BuildingsConfig then
			return nil
		end

		local bestItemName
		local bestPrice = -math.huge

		for itemName, itemState in pairs(playerState.backpack) do
			local amount
			if type(itemState) == "table" then
				amount = itemState.amount or 0
			else
				amount = itemState or 0
			end

			if amount > 0 then
				local building = BuildingsConfig[itemName]
				local price = (building and building.Price) or 0
				if price > bestPrice then
					bestPrice = price
					bestItemName = itemName
				end
			end
		end

		return bestItemName
	end

	local function findPlacementCFrame(modelName)
		local plotBase = getPlayerPlotBasePart()
		if not plotBase or not Grid or not Objects then
			return nil
		end

		local objectModel = Objects:FindFirstChild(modelName)
		if not objectModel then
			return nil
		end

		local grid = Grid.new(plotBase, objectModel)
		local foundCFrame

		if grid.preview and grid.preview:FindFirstChild("Hitbox") then
			local halfWidth = math.floor(plotBase.Size.X / 2)
			local halfDepth = math.floor(plotBase.Size.Z / 2)
			local attempts = 0

			for x = -halfWidth, halfWidth, 2 do
				for z = -halfDepth, halfDepth, 2 do
					for rotation = 0, 3 do
						grid.rotation = rotation
						local candidate = grid:CalculatePosition(plotBase.CFrame * Vector3.new(x, 0, z))

						if candidate then
							attempts += 1
							if grid:ValidatePlacement(LocalPlayer, candidate) then
								foundCFrame = candidate
								break
							end
						end
					end

					if foundCFrame then
						break
					end

					if attempts % 200 == 0 then
						task.wait()
					end
				end

				if foundCFrame then
					break
				end
			end
		end

		pcall(function()
			grid:Destroy()
		end)

		return foundCFrame
	end

	local function placeBestBuildingOnce()
		local modelName = findBestBuildableItem()
		if not modelName then
			notify("No buildable items in backpack")
			return false
		end

		local modelCFrame = findPlacementCFrame(modelName)
		if not modelCFrame then
			notify("No valid placement spot for " .. modelName)
			return false
		end

		placeBuilding(modelName, modelCFrame)
		notify("Placed " .. modelName)
		return true
	end

	purchaseGroup:AddButton({
		Text = "Place Best Once",
		Func = function()
			task.spawn(placeBestBuildingOnce)
		end,
	})

	purchaseGroup:AddToggle("AutoPlace", {
		Text = "Auto Place Best",
		Default = false,
		Callback = function(enabled)
			State.autoPlaceBuildingRunning = enabled
			if enabled then
				notify("Auto Place Best enabled")
				task.spawn(function()
					while runtimeActive and State.autoPlaceBuildingRunning do
						pcall(placeBestBuildingOnce)
						task.wait(State.autoPlaceInterval)
					end
				end)
			end
		end,
	})

	-- ========================================================================
	-- Building sales and plot expansion
	-- ========================================================================

	local buildingSalesGroup = uiRefs.Tabs.Shop:AddLeftGroupbox("Sell Buildings", "dollar-sign")
	buildingSalesGroup:AddDropdown("SellBuildingItems", {
		Values = prependAny(regularBuildingItemNames),
		Default = {},
		Text = "Select Buildings to Sell",
		Multi = true,
		Callback = function(selection)
			State.selectedSellBuildingItem = normalizeSelection(selection)
		end,
	})
	buildingSalesGroup:AddSlider("SellBuildingDelay", {
		Text = "Sell Delay (seconds)",
		Default = 0.5,
		Min = 0.1,
		Max = 3,
		Rounding = 1,
		Callback = function(value)
			State.autoSellBuildingDelay = value
		end,
	})
	buildingSalesGroup:AddToggle("AutoSellBuilding", {
		Text = "Auto Sell Buildings",
		Default = false,
		Callback = function(enabled)
			State.autoSellBuildingRunning = enabled
			if enabled then
				notify("Auto Sell Buildings enabled")
				task.spawn(function()
					while runtimeActive and State.autoSellBuildingRunning do
						pcall(sellSelectedBuildings)
						task.wait(2)
					end
				end)
			end
		end,
	})
	buildingSalesGroup:AddButton({
		Text = "Sell Selected Once",
		Func = function()
			if type(State.selectedSellBuildingItem) ~= "table" or #State.selectedSellBuildingItem == 0 then
				notify("No buildings selected!")
				return
			end

			task.spawn(sellSelectedBuildings)
			notify("Selling selected buildings")
		end,
	})

	local plotPurchaseGroup = uiRefs.Tabs.Shop:AddRightGroupbox("Buy Plot", "grid")
	local plotSlotNames = {}
	for slotIndex = 1, 52 do
		plotSlotNames[slotIndex] = tostring(slotIndex)
	end

	uiRefs.plotSlotDropdown = plotPurchaseGroup:AddDropdown("PlotSlots", {
		Values = prependAny(plotSlotNames),
		Default = {},
		Text = "Select Plot Slots",
		Multi = true,
		Callback = function(selection)
			State.selectedPlotSlots = normalizeSelection(selection)
		end,
	})

	local function buySelectedPlotSlots()
		local plotContainer = findPlayerPlotContainer()
		if not plotContainer then
			notify("Could not find your plot!")
			return
		end

		local plot = plotContainer:FindFirstChild("Plot")
		if not plot then
			notify("Plot object not found!")
			return
		end

		local expandPlot = plot:FindFirstChild("ExpandPlot")
		if not expandPlot then
			notify("ExpandPlot not found!")
			return
		end

		local selectedSlots = State.selectedPlotSlots
		local includesAny = false
		for _, slotName in ipairs(selectedSlots) do
			if slotName == "Any" then
				includesAny = true
				break
			end
		end

		local filterSelection = not includesAny and type(selectedSlots) == "table" and #selectedSlots > 0
		local selectedLookup = {}
		if filterSelection then
			for _, slotName in ipairs(selectedSlots) do
				selectedLookup[tostring(slotName)] = true
			end
		end

		local purchasedCount = 0
		for _, slotGroup in ipairs(expandPlot:GetChildren()) do
			if not filterSelection or selectedLookup[slotGroup.Name] then
				for _, slotModel in ipairs(slotGroup:GetChildren()) do
					local plotPart = slotModel:FindFirstChild("PlotPart")
					if plotPart then
						local prompt = plotPart:FindFirstChildOfClass("ProximityPrompt")
						if prompt then
							pcall(function()
								fireproximityprompt(prompt)
							end)
							purchasedCount += 1
							task.wait(0.1)
						end
					end
				end
			end
		end

		notify("Bought " .. purchasedCount .. " plot slot(s)!")
	end

	plotPurchaseGroup:AddButton({
		Text = "Buy Plots Once",
		Func = function()
			task.spawn(buySelectedPlotSlots)
		end,
	})
	plotPurchaseGroup:AddToggle("AutoBuyPlot", {
		Text = "Auto Buy Plot",
		Default = false,
		Callback = function(enabled)
			State.autoBuyPlotRunning = enabled
			if enabled then
				notify("Auto Buy Plot enabled")
				task.spawn(function()
					while runtimeActive and State.autoBuyPlotRunning do
						pcall(buySelectedPlotSlots)
						task.wait(1)
					end
				end)
			else
				notify("Auto Buy Plot disabled")
			end
		end,
	})

	-- ========================================================================
	-- Teleport controls
	-- ========================================================================

	local kingOfHillGroup = uiRefs.Tabs.Teleport:AddLeftGroupbox("KoH Locations", "flag")
	for _, location in ipairs(kingOfHillLocations) do
		kingOfHillGroup:AddButton({
			Text = location.name,
			Func = function()
				teleportToCFrame(CFrame.new(location.x, location.y, location.z))
				notify("Teleported to " .. location.name)
			end,
		})
	end

	local playerTeleportGroup = uiRefs.Tabs.Teleport:AddRightGroupbox("Player Teleport", "user")
	local playerNames = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			table.insert(playerNames, player.Name)
		end
	end

	uiRefs.playerTPDropdown = playerTeleportGroup:AddDropdown("TPPlayer", {
		Values = playerNames,
		Default = playerNames[1],
		Text = "Select Player",
		Callback = function() end,
	})

	playerTeleportGroup:AddButton({
		Text = "Teleport to Player",
		Func = function()
			local playerName = Options.TPPlayer.Value
			if not playerName then
				return
			end

			local player = Players:FindFirstChild(playerName)
			if not player or not player.Character then
				notify("Player not found")
				return
			end

			teleportToCFrame(player.Character:GetPivot())
			notify("Teleported to " .. playerName)
		end,
	})

	trackRuntimeConnection(Players.PlayerAdded:Connect(function(player)
		if player ~= LocalPlayer then
			table.insert(playerNames, player.Name)
			pcall(function()
				uiRefs.playerTPDropdown:SetValues(playerNames)
			end)
		end
	end))

	trackRuntimeConnection(Players.PlayerRemoving:Connect(function(player)
		for index, playerName in ipairs(playerNames) do
			if playerName == player.Name then
				table.remove(playerNames, index)
				break
			end
		end

		pcall(function()
			uiRefs.playerTPDropdown:SetValues(playerNames)
		end)
	end))

	local coordinateGroup = uiRefs.Tabs.Teleport:AddLeftGroupbox("Coordinate Teleport", "compass")
	coordinateGroup:AddSlider("CoordX", {
		Text = "X Position",
		Default = 0,
		Min = -2000,
		Max = 2000,
		Rounding = 1,
		Callback = function() end,
	})
	coordinateGroup:AddSlider("CoordY", {
		Text = "Y Position",
		Default = 10,
		Min = -500,
		Max = 1000,
		Rounding = 1,
		Callback = function() end,
	})
	coordinateGroup:AddSlider("CoordZ", {
		Text = "Z Position",
		Default = 0,
		Min = -2000,
		Max = 2000,
		Rounding = 1,
		Callback = function() end,
	})
	coordinateGroup:AddButton({
		Text = "Teleport to Coordinates",
		Func = function()
			local x = Options.CoordX.Value
			local y = Options.CoordY.Value
			local z = Options.CoordZ.Value

			teleportToCFrame(CFrame.new(x, y, z))
			notify("Teleported to " .. math.floor(x) .. ", " .. math.floor(y) .. ", " .. math.floor(z))
		end,
	})

	-- ========================================================================
	-- Movement and utility controls
	-- ========================================================================

	local movementGroup = uiRefs.Tabs.Misc:AddLeftGroupbox("Movement", "run")
	movementGroup:AddToggle("FlyToggle", {
		Text = "Fly (WASD + Q/E)",
		Default = false,
		Callback = function(enabled)
			State.miscFlyEnabled = enabled
			if enabled then
				startFlying()
				notify("Fly enabled")
			else
				stopFlying()
				notify("Fly disabled")
			end
		end,
	})
	movementGroup:AddSlider("FlySpeed", {
		Text = "Fly Speed",
		Default = 50,
		Min = 10,
		Max = 500,
		Rounding = 0,
		Callback = function(value)
			State.miscFlySpeed = value
		end,
	})
	movementGroup:AddToggle("InfJump", {
		Text = "Infinite Jump",
		Default = false,
		Callback = function(enabled)
			State.miscInfJumpEnabled = enabled
			if enabled then
				State.miscInfJumpConn = trackRuntimeConnection(UserInputService.JumpRequest:Connect(function()
					if State.miscInfJumpEnabled then
						pcall(function()
							local character = LocalPlayer.Character
							local humanoid = character and character:FindFirstChildOfClass("Humanoid")
							if humanoid then
								humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
							end
						end)
					end
				end))
				notify("Infinite Jump enabled")
			elseif State.miscInfJumpConn then
				State.miscInfJumpConn:Disconnect()
				State.miscInfJumpConn = nil
			end
		end,
	})
	movementGroup:AddToggle("NoClip", {
		Text = "No Clip",
		Default = false,
		Callback = function(enabled)
			setNoClipEnabled(enabled)
		end,
	})

	local speedGroup = uiRefs.Tabs.Misc:AddLeftGroupbox("Speed", "gauge")
	speedGroup:AddSlider("WalkSpeed", {
		Text = "Walk Speed",
		Default = 16,
		Min = 16,
		Max = 500,
		Rounding = 0,
		Callback = function(value)
			local character = LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = value
			end
		end,
	})

	local utilityGroup = uiRefs.Tabs.Misc:AddRightGroupbox("Utility", "zap")
	State.miscAntiAfkConn = nil
	utilityGroup:AddToggle("AntiAFK", {
		Text = "Anti AFK",
		Default = false,
		Callback = function(enabled)
			State.miscAntiAfkEnabled = enabled
			if enabled then
				notify("Anti AFK enabled")
				enableAntiAfk()
			else
				disableAntiAfk()
				notify("Anti AFK disabled")
			end
		end,
	})

	State.miscAutoJumpEnabled = false
	local autoJumpTask = nil

	utilityGroup:AddToggle("AutoJump", {
		Text = "Auto Jump to prevent getting kick",
		Default = false,
		Callback = function(enabled)
			State.miscAutoJumpEnabled = enabled
			if enabled then
				notify("Auto Jump enabled")
				if not autoJumpTask or autoJumpTask.Cancelled then
					autoJumpTask = task.spawn(function()
						while runtimeActive and State.miscAutoJumpEnabled do
							local character = LocalPlayer.Character
							local humanoid = character and character:FindFirstChildOfClass("Humanoid")
							if humanoid and humanoid.Health > 0 then
								humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
							end

							task.wait(math.random(8, 18))
						end
					end)
				end
			else
				notify("Auto Jump disabled")
				if autoJumpTask then
					task.cancel(autoJumpTask)
					autoJumpTask = nil
				end
			end
		end,
	})

	utilityGroup:AddToggle("DisableNotifs", {
		Text = "Disable Notifications",
		Default = false,
		Callback = function(enabled)
			State.disableNotifications = enabled
		end,
	})

	utilityGroup:AddToggle("BlockPopups", {
		Text = "Block In-Game Popups",
		Default = false,
		Callback = function(enabled)
			State.BlockNotif = enabled
			if not enabled then
				return
			end

			local function purgeAndBlockNotifications(container)
				for _, notification in ipairs(container:GetChildren()) do
					if State.BlockNotif then
						pcall(function()
							notification:Destroy()
						end)
					end
				end

				trackRuntimeConnection(container.ChildAdded:Connect(function(notification)
					if not State.BlockNotif then
						return
					end

					task.wait(0.02)
					pcall(function()
						notification:Destroy()
					end)
				end))
			end

			local playerGui = LocalPlayer:WaitForChild("PlayerGui", 10)

			task.spawn(function()
				local notificationContainer = playerGui
					and playerGui:FindFirstChild("Notifs")
					and playerGui.Notifs:FindFirstChild("Frame")
					and playerGui.Notifs.Frame:FindFirstChild("NotificationsUI")

				if notificationContainer then
					purgeAndBlockNotifications(notificationContainer)
				end
			end)

			task.spawn(function()
				local notificationContainer = playerGui
					and playerGui:FindFirstChild("OldUI")
					and playerGui.OldUI:FindFirstChild("HUD")
					and playerGui.OldUI.HUD:FindFirstChild("Notifications")

				if notificationContainer then
					purgeAndBlockNotifications(notificationContainer)
				end
			end)
		end,
	})

	-- ========================================================================
	-- Performance controls
	-- ========================================================================

	local performanceGroup = uiRefs.Tabs.Misc:AddLeftGroupbox("Performance", "gauge")
	performanceGroup:AddSlider("NpcCullDist", {
		Text = "NPC Cull Distance",
		Default = 150,
		Min = 50,
		Max = 1000,
		Rounding = 0,
		Callback = function(value)
			State.perfNpcCullingDistance = value
		end,
	})
	performanceGroup:AddToggle("LowPerfMode", {
		Text = "Low Performance Mode",
		Default = false,
		Callback = function(enabled)
			State.perfLowPerformanceMode = enabled
		end,
	})
	performanceGroup:AddButton({
		Text = "Apply Performance Settings",
		Func = function()
			applyPerformanceSettings()
			notify("Performance settings applied")
		end,
	})

	local blackScreenGui
	local blackScreenFrame

	performanceGroup:AddToggle("BlackScreen", {
		Text = "Black Screen",
		Default = false,
		Callback = function(enabled)
			pcall(function()
				if not blackScreenGui or not blackScreenGui.Parent then
					local guiParent = CoreGui
					local succeeded, hiddenUi = pcall(function()
						return gethui and gethui()
					end)
					if succeeded and hiddenUi then
						guiParent = hiddenUi
					end

					blackScreenGui = Instance.new("ScreenGui")
					blackScreenGui.Name = "CyraaHubBlackScreen"
					blackScreenGui.ResetOnSpawn = false
					blackScreenGui.IgnoreGuiInset = true
					blackScreenGui.DisplayOrder = 999
					blackScreenGui.Parent = guiParent
					uiRefs.blackScreenGui = blackScreenGui

					blackScreenFrame = Instance.new("Frame")
					blackScreenFrame.Size = UDim2.new(1, 0, 1, 0)
					blackScreenFrame.Position = UDim2.new(0, 0, 0, 0)
					blackScreenFrame.BackgroundColor3 = Color3.new(0, 0, 0)
					blackScreenFrame.BackgroundTransparency = 0
					blackScreenFrame.BorderSizePixel = 0
					blackScreenFrame.ZIndex = 999
					blackScreenFrame.Visible = false
					blackScreenFrame.Parent = blackScreenGui
				end

				blackScreenFrame.Visible = enabled
			end)
		end,
	})

	performanceGroup:AddToggle("Disable3DRender", {
		Text = "Disable 3D Rendering",
		Default = false,
		Callback = function(enabled)
			pcall(function()
				RunService:Set3dRenderingEnabled(not enabled)
			end)
		end,
	})

	performanceGroup:AddToggle("RemoveFog", {
		Text = "Remove Fog",
		Default = false,
		Callback = function(enabled)
			pcall(function()
				setFogRemoved(enabled)
			end)
		end,
	})

	performanceGroup:AddToggle("AutoRemoveCollectItems", {
		Text = "Auto Remove Collect Items",
		Default = false,
		Callback = function(enabled)
			autoRemoveCollectItemsEnabled = enabled
			if enabled then
				notify("Auto Remove Collect Items enabled")
				task.spawn(function()
					while runtimeActive and autoRemoveCollectItemsEnabled do
						pcall(removeWorldCollectItems)
						task.wait(0.1)
					end
				end)
			else
				notify("Auto Remove Collect Items disabled")
			end
		end,
	})

	-- ========================================================================
	-- Reversible anti-lag mode
	-- ========================================================================

	local antiLagGroup = uiRefs.Tabs.Misc:AddLeftGroupbox("Anti Lag", "cpu")
	antiLagGroup:AddToggle("AntiLag", {
		Text = "Anti Lag (Reduces graphics)",
		Default = false,
		Callback = function(enabled)
			pcall(function()
				local lighting = game:GetService("Lighting")
				local terrain = Workspace:FindFirstChildWhichIsA("Terrain")

				if not enabled then
					local snapshot = State._perfSnapshot
					if not snapshot then
						return
					end

					if terrain and snapshot.terrain then
						terrain.WaterWaveSize = snapshot.terrain.waveSize
						terrain.WaterWaveSpeed = snapshot.terrain.waveSpeed
						terrain.WaterReflectance = snapshot.terrain.reflectance
						terrain.WaterTransparency = snapshot.terrain.transparency
					end

					lighting.GlobalShadows = snapshot.globalShadows
					lighting.FogEnd = snapshot.fogEnd
					lighting.FogStart = snapshot.fogStart
					settings().Rendering.QualityLevel = snapshot.qualityLevel

					for _, savedPart in ipairs(snapshot.parts) do
						pcall(function()
							savedPart.part.CastShadow = savedPart.castShadow
							savedPart.part.Material = savedPart.material
							savedPart.part.Reflectance = savedPart.reflectance
							savedPart.part.BackSurface = savedPart.back
							savedPart.part.BottomSurface = savedPart.bottom
							savedPart.part.FrontSurface = savedPart.front
							savedPart.part.LeftSurface = savedPart.left
							savedPart.part.RightSurface = savedPart.right
							savedPart.part.TopSurface = savedPart.top
						end)
					end

					for _, savedDecal in ipairs(snapshot.decals) do
						pcall(function()
							savedDecal.decal.Transparency = savedDecal.trans
							savedDecal.decal.Texture = savedDecal.tex
						end)
					end

					for _, savedParticle in ipairs(snapshot.particles) do
						pcall(function()
							savedParticle.obj.Lifetime = savedParticle.lifetime
						end)
					end

					for _, savedPostEffect in ipairs(snapshot.postEffects) do
						pcall(function()
							savedPostEffect.obj.Enabled = savedPostEffect.enabled
						end)
					end

					if State._perfDescConn then
						State._perfDescConn:Disconnect()
						State._perfDescConn = nil
					end
					State._perfSnapshot = nil
					return
				end

				local snapshot = {
					globalShadows = lighting.GlobalShadows,
					fogEnd = lighting.FogEnd,
					fogStart = lighting.FogStart,
					qualityLevel = settings().Rendering.QualityLevel,
					terrain = terrain and {
						waveSize = terrain.WaterWaveSize,
						waveSpeed = terrain.WaterWaveSpeed,
						reflectance = terrain.WaterReflectance,
						transparency = terrain.WaterTransparency,
					} or nil,
					parts = {},
					decals = {},
					particles = {},
					postEffects = {},
				}
				State._perfSnapshot = snapshot

				if terrain then
					terrain.WaterWaveSize = 0
					terrain.WaterWaveSpeed = 0
					terrain.WaterReflectance = 0
					terrain.WaterTransparency = 1
				end

				lighting.GlobalShadows = false
				lighting.FogEnd = 9000000000
				lighting.FogStart = 9000000000
				settings().Rendering.QualityLevel = 1

				for _, descendant in pairs(game:GetDescendants()) do
					if descendant:IsA("BasePart") then
						table.insert(snapshot.parts, {
							part = descendant,
							castShadow = descendant.CastShadow,
							material = descendant.Material,
							reflectance = descendant.Reflectance,
							back = descendant.BackSurface,
							bottom = descendant.BottomSurface,
							front = descendant.FrontSurface,
							left = descendant.LeftSurface,
							right = descendant.RightSurface,
							top = descendant.TopSurface,
						})

						descendant.CastShadow = false
						descendant.Material = Enum.Material.Plastic
						descendant.Reflectance = 0
						descendant.BackSurface = Enum.SurfaceType.SmoothNoOutlines
						descendant.BottomSurface = Enum.SurfaceType.SmoothNoOutlines
						descendant.FrontSurface = Enum.SurfaceType.SmoothNoOutlines
						descendant.LeftSurface = Enum.SurfaceType.SmoothNoOutlines
						descendant.RightSurface = Enum.SurfaceType.SmoothNoOutlines
						descendant.TopSurface = Enum.SurfaceType.SmoothNoOutlines
					elseif descendant:IsA("Decal") then
						table.insert(snapshot.decals, {
							decal = descendant,
							trans = descendant.Transparency,
							tex = descendant.Texture,
						})
						descendant.Transparency = 1
						descendant.Texture = ""
					elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") then
						table.insert(snapshot.particles, {
							obj = descendant,
							lifetime = descendant.Lifetime,
						})
						descendant.Lifetime = NumberRange.new(0)
					end
				end

				for _, descendant in pairs(lighting:GetDescendants()) do
					if descendant:IsA("PostEffect") then
						table.insert(snapshot.postEffects, {
							obj = descendant,
							enabled = descendant.Enabled,
						})
						descendant.Enabled = false
					end
				end

				if not State._perfDescConn then
					State._perfDescConn = trackRuntimeConnection(Workspace.DescendantAdded:Connect(function(descendant)
						task.spawn(function()
							if
								descendant:IsA("ForceField")
								or descendant:IsA("Sparkles")
								or descendant:IsA("Smoke")
								or descendant:IsA("Fire")
								or descendant:IsA("Beam")
							then
								task.wait()
								descendant:Destroy()
							elseif descendant:IsA("BasePart") then
								descendant.CastShadow = false
							end
						end)
					end))
				end
			end)
		end,
	})

	-- ========================================================================
	-- Plot visibility and no-clip enforcement
	-- ========================================================================

	local hiddenBuildingParts = {}
	antiLagGroup:AddToggle("HideOtherBuildings", {
		Text = "Hide Other Plots Buildings",
		Default = false,
		Callback = function(enabled)
			if not enabled then
				for _, savedPart in ipairs(hiddenBuildingParts) do
					pcall(function()
						savedPart.part.Transparency = savedPart.trans
						savedPart.part.CanCollide = savedPart.collide
					end)
				end
				hiddenBuildingParts = {}
				return
			end

			local militaryMap = Workspace:FindFirstChild("MilitaryMap")
			local playerPlots = militaryMap and militaryMap:FindFirstChild("PlayerPlots")
			if not playerPlots then
				return
			end

			local ownPlotContainer = findPlayerPlotContainer()
			hiddenBuildingParts = {}

			for _, plotContainer in ipairs(playerPlots:GetChildren()) do
				if plotContainer ~= ownPlotContainer then
					local plot = plotContainer:FindFirstChild("Plot")
					local buildings = plot and plot:FindFirstChild("Buildings")
					if buildings then
						for _, descendant in ipairs(buildings:GetDescendants()) do
							if descendant:IsA("BasePart") then
								table.insert(hiddenBuildingParts, {
									part = descendant,
									trans = descendant.Transparency,
									collide = descendant.CanCollide,
								})
								descendant.Transparency = 1
								descendant.CanCollide = false
							end
						end
					end
				end
			end
		end,
	})

	trackRuntimeConnection(RunService.Stepped:Connect(function()
		pcall(enforceNoClip)
	end))
end

UI.buildShopTeleportMiscUi = buildShopTeleportMiscUi

-- ============================================================================
-- Server/settings interface and runtime startup
-- ============================================================================
-- Integration contract:
--   1. createInterfaceShell() creates uiRefs.Window and uiRefs.Tabs.
--   2. buildHomeFarmUi() builds the Home and Farm tabs.
--   3. buildShopTeleportMiscUi() builds Shop, Teleport, and Misc and stores
--      its optional blackout ScreenGui in uiRefs.blackScreenGui.
--   4. This fragment builds Server and Settings, then starts runtime workers.

local SERVER_HISTORY_FILE = "server-hop-temp.json"

-- --------------------------------------------------------------------------
-- Reconnect controller
-- --------------------------------------------------------------------------

local function createReconnectController(statusLabel)
	local controller = {
		placeId = game.PlaceId,
		visitedServerIds = {},
		cursor = "",
		currentUtcHour = os.date("!*t").hour,
		backupServerId = nil,
		isReconnecting = false,
		statusLabel = statusLabel,
	}

	pcall(function()
		controller.visitedServerIds = HttpService:JSONDecode(readfile(SERVER_HISTORY_FILE))
	end)

	-- This intentionally matches the original recovery condition. A read error
	-- leaves the initially empty table intact; decoded non-tables are replaced.
	if not controller.visitedServerIds or type(controller.visitedServerIds) ~= "table" then
		controller.visitedServerIds = { controller.currentUtcHour }
		pcall(function()
			writefile(SERVER_HISTORY_FILE, HttpService:JSONEncode(controller.visitedServerIds))
		end)
	end

	function controller:fetchReconnectCandidate()
		local url = "https://games.roblox.com/v1/games/" .. self.placeId .. "/servers/Public?sortOrder=Asc&limit=100"
		if self.cursor ~= "" then
			url = url .. "&cursor=" .. self.cursor
		end

		local requestSucceeded, responseBody = pcall(function()
			return game:HttpGet(url)
		end)
		if not requestSucceeded or type(responseBody) ~= "string" or responseBody == "" then
			return nil
		end

		local decodeSucceeded, response = pcall(function()
			return HttpService:JSONDecode(responseBody)
		end)
		if not decodeSucceeded or type(response) ~= "table" or type(response.data) ~= "table" then
			return nil
		end

		if response.nextPageCursor and response.nextPageCursor ~= "null" and response.nextPageCursor ~= nil then
			self.cursor = response.nextPageCursor
		end

		for _, server in pairs(response.data) do
			if tonumber(server.maxPlayers) > tonumber(server.playing) then
				local serverId = tostring(server.id)
				if serverId ~= game.JobId then
					local isUnvisited = true
					for _, visitedServerId in pairs(self.visitedServerIds) do
						if serverId == tostring(visitedServerId) then
							isUnvisited = false
							break
						end
					end

					if isUnvisited then
						return serverId
					end
				end
			end
		end

		return nil
	end

	function controller:refreshBackupServer()
		local candidate = self:fetchReconnectCandidate()
		if not candidate then
			self.cursor = ""
			candidate = self:fetchReconnectCandidate()
		end

		if not candidate then
			self.backupServerId = nil
			return false
		end

		self.backupServerId = candidate
		return true
	end

	function controller:reconnectToBackupServer()
		if self.isReconnecting then
			return false
		end

		if not self.backupServerId and not self:refreshBackupServer() then
			self.statusLabel:SetText("Status: No backup server available")
			return false
		end

		self.isReconnecting = true
		table.insert(self.visitedServerIds, self.backupServerId)
		pcall(function()
			writefile(SERVER_HISTORY_FILE, HttpService:JSONEncode(self.visitedServerIds))
		end)

		queueReExecutionOnTeleport()
		local teleportStarted = pcall(function()
			TeleportService:TeleportToPlaceInstance(self.placeId, self.backupServerId, LocalPlayer)
		end)
		if not teleportStarted then
			self.isReconnecting = false
			self.statusLabel:SetText("Status: Teleport failed - retrying")
			return false
		end
		return true
	end

	function controller:startMonitor()
		self:refreshBackupServer()

		-- Keep a fresh backup server ready while reconnect is enabled.
		task.spawn(function()
			while runtimeActive and not self.isReconnecting do
				if getgenv().autoReconnectEnabled then
					if not self:refreshBackupServer() and not self.backupServerId then
						while
							runtimeActive
							and not self.backupServerId
							and not self.isReconnecting
							and getgenv().autoReconnectEnabled
						do
							task.wait(1)
							self:refreshBackupServer()
						end
					else
						task.wait(3)
					end
				else
					task.wait(1)
				end
			end
		end)

		-- Roblox displays network and kick failures below this prompt overlay.
		task.spawn(function()
			local promptGui = CoreGui:FindFirstChild("RobloxPromptGui")
			local promptOverlay = promptGui and promptGui:FindFirstChild("promptOverlay")

			local function findPromptOverlay()
				local currentPromptGui = CoreGui:FindFirstChild("RobloxPromptGui")
				if not currentPromptGui then
					return nil
				end
				return currentPromptGui:FindFirstChild("promptOverlay")
			end

			if not promptOverlay then
				while runtimeActive and not findPromptOverlay() and not self.isReconnecting do
					task.wait(0.5)
				end
				promptOverlay = findPromptOverlay()
			end

			if promptOverlay then
				trackRuntimeConnection(promptOverlay.ChildAdded:Connect(function(child)
					if child.Name == "ErrorPrompt" and not self.isReconnecting and getgenv().autoReconnectEnabled then
						self.statusLabel:SetText("Status: Kicked - Reconnecting...")
						self:reconnectToBackupServer()
					end
				end))
			end
		end)

		-- A removed LocalPlayer is another executor-visible disconnect signal.
		task.spawn(function()
			while runtimeActive and not self.isReconnecting do
				if getgenv().autoReconnectEnabled then
					if not LocalPlayer:IsDescendantOf(game) then
						self.statusLabel:SetText("Status: Disconnected - Reconnecting...")
						self:reconnectToBackupServer()
						return
					end
					task.wait(1)
				else
					task.wait(1)
				end
			end
		end)

		-- Surface controller state without coupling the monitor loops to the UI.
		task.spawn(function()
			while runtimeActive and not self.isReconnecting do
				if self.backupServerId and getgenv().autoReconnectEnabled then
					self.statusLabel:SetText("Status: Standby | Backup: " .. self.backupServerId:sub(1, 8) .. "...")
				elseif getgenv().autoReconnectEnabled then
					self.statusLabel:SetText("Status: Searching for backup server...")
				else
					self.statusLabel:SetText("Status: Disabled")
				end
				task.wait(2)
			end
		end)
	end

	return controller
end

-- --------------------------------------------------------------------------
-- Weather server search
-- --------------------------------------------------------------------------

local function hopToRandomPublicServerForWeather()
	local requestFunction = (syn and syn.request) or http_request or httprequest or request
	if not requestFunction then
		return
	end

	local publicServerIds = {}
	local cursor = ""

	while runtimeActive do
		local requestSucceeded, response = pcall(function()
			return requestFunction({
				Url = string.format(
					"https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Desc&limit=100&cursor=%s",
					game.PlaceId,
					cursor
				),
				Method = "GET",
			})
		end)
		if not requestSucceeded or type(response) ~= "table" or type(response.Body) ~= "string" then
			break
		end

		local decodeSucceeded, page = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if not decodeSucceeded or type(page) ~= "table" or type(page.data) ~= "table" then
			break
		end

		for _, server in pairs(page.data or {}) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				table.insert(publicServerIds, server.id)
			end
		end

		cursor = page.nextPageCursor or ""
		if cursor == "" or #publicServerIds >= 30 then
			break
		end
	end

	if #publicServerIds > 0 then
		queueReExecutionOnTeleport()
		local serverId = publicServerIds[math.random(1, #publicServerIds)]
		TeleportService:TeleportToPlaceInstance(game.PlaceId, serverId)
	end
end

local function startWeatherHopWorker()
	task.spawn(function()
		while runtimeActive and getgenv().weatherHopRunning do
			task.wait(3)
			if not getgenv().weatherHopRunning then
				break
			end

			local targetWeather = getgenv().weatherHopTarget or "Storm"
			local isTargetActive
			if targetWeather == "BeastBreach" then
				isTargetActive = isBeastBreachActive()
			else
				isTargetActive = isWeatherActive(targetWeather)
			end

			if isTargetActive then
				uiRefs.weatherStatusLabel:SetText("Status: Found " .. targetWeather)
			else
				uiRefs.weatherStatusLabel:SetText("Status: Hopping server...")
				hopToRandomPublicServerForWeather()
				task.wait(8)
			end
		end

		uiRefs.weatherStatusLabel:SetText("Status: Idle")
	end)
end

-- --------------------------------------------------------------------------
-- Server and settings tabs
-- --------------------------------------------------------------------------

local function buildServerSettingsUi()
	local serverHopGroup = uiRefs.Tabs.Server:AddLeftGroupbox("Server Hop", "shuffle")
	serverHopGroup:AddToggle("AutoHop", {
		Text = "Auto Server Hop",
		Default = false,
		Callback = function(enabled)
			getgenv().autoHopEnabled = enabled
			if enabled then
				notify("Auto Hop enabled")
				task.spawn(function()
					while runtimeActive and getgenv().autoHopEnabled do
						queueReExecutionOnTeleport()
						hopToRandomServer()
						task.wait(getgenv().autoHopInterval * 60)
					end
				end)
			end
		end,
	})

	serverHopGroup:AddSlider("HopInterval", {
		Text = "Hop Interval (min)",
		Default = 5,
		Min = 1,
		Max = 30,
		Rounding = 0,
		Callback = function(intervalMinutes)
			getgenv().autoHopInterval = intervalMinutes
		end,
	})

	serverHopGroup:AddButton({
		Text = "Hop to Random Server",
		Func = function()
			queueReExecutionOnTeleport()
			hopToRandomServer()
			notify("Hopping to random server...")
		end,
	})

	serverHopGroup:AddButton({
		Text = "Hop to Least Players",
		Func = function()
			queueReExecutionOnTeleport()
			hopToLeastPopulatedServer()
			notify("Hopping to least populated server...")
		end,
	})

	local managementGroup = uiRefs.Tabs.Server:AddRightGroupbox("Management", "refresh")
	uiRefs.serverIdLabel = managementGroup:AddLabel("Server ID: " .. game.JobId)
	task.spawn(function()
		while runtimeActive do
			task.wait(1)
			pcall(function()
				uiRefs.serverIdLabel:SetText("Server ID: " .. game.JobId)
			end)
		end
	end)

	managementGroup:AddButton({
		Text = "Copy Server ID",
		Func = function()
			setclipboard(game.JobId)
			notify("Server ID copied!")
		end,
	})

	managementGroup:AddDivider()

	managementGroup:AddButton({
		Text = "Rejoin Server",
		Func = function()
			queueReExecutionOnTeleport()
			TeleportService:Teleport(game.PlaceId, LocalPlayer)
			notify("Rejoining server...")
		end,
	})

	managementGroup:AddButton({
		Text = "Switch to Random Server",
		Func = function()
			queueReExecutionOnTeleport()
			hopToRandomServer()
			notify("Switching to random server...")
		end,
	})

	managementGroup:AddButton({
		Text = "Switch to Least Players",
		Func = function()
			queueReExecutionOnTeleport()
			hopToLeastPopulatedServer()
			notify("Switching to least populated server...")
		end,
	})

	managementGroup:AddDivider()

	managementGroup:AddInput("JoinServer", {
		Text = "Join Server by ID",
		Default = "",
		Callback = function(serverId)
			if serverId and serverId ~= "" then
				queueReExecutionOnTeleport()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, serverId)
			end
		end,
	})

	local reconnectGroup = uiRefs.Tabs.Server:AddLeftGroupbox("Auto Reconnect", "refresh-cw")
	uiRefs.reconnectStatusLabel = reconnectGroup:AddLabel("Status: Idle")
	local reconnectController = createReconnectController(uiRefs.reconnectStatusLabel)

	reconnectGroup:AddToggle("AutoReconnect", {
		Text = "Enable Auto Reconnect",
		Default = false,
		Callback = function(enabled)
			getgenv().autoReconnectEnabled = enabled
			if enabled then
				reconnectController.isReconnecting = false
				reconnectController.cursor = ""
				reconnectController.backupServerId = nil
				notify("Auto Reconnect enabled")
				queueReExecutionOnTeleport()
				reconnectController:startMonitor()
			else
				reconnectController.isReconnecting = true
				uiRefs.reconnectStatusLabel:SetText("Status: Disabled")
				notify("Auto Reconnect disabled")
			end
		end,
	})

	reconnectGroup:AddToggle("AutoReExec", {
		Text = "Auto Re-Execute on Teleport",
		Default = false,
		Callback = function(enabled)
			getgenv().autoReExecEnabled = enabled
			if enabled then
				queueReExecutionOnTeleport()
				notify("Auto Re-Execute enabled")
				return
			end

			if not getgenv().autoReconnectEnabled then
				if queue_on_teleport then
					queue_on_teleport("")
				elseif syn and syn.queue_on_teleport then
					syn.queue_on_teleport("")
				elseif fluxus and fluxus.queue_on_teleport then
					fluxus.queue_on_teleport("")
				end
			end
			notify("Auto Re-Execute disabled")
		end,
	})

	local weatherGroup = uiRefs.Tabs.Server:AddLeftGroupbox("Weather Hopper", "cloud-rain")
	uiRefs.weatherStatusLabel = weatherGroup:AddLabel("Status: Idle")

	weatherGroup:AddDropdown("WeatherTarget", {
		Values = {
			"Storm",
			"NuclearFallout",
			"Rebellion",
			"Invasion",
			"MeteorShower",
			"HackerOverride",
			"BeastBreach",
		},
		Default = "Storm",
		Text = "Target Weather",
		Callback = function(weatherName)
			getgenv().weatherHopTarget = weatherName
		end,
	})
	getgenv().weatherHopTarget = "Storm"

	weatherGroup:AddToggle("WeatherHopToggle", {
		Text = "Auto Hop Weather",
		Default = false,
		Callback = function(enabled)
			getgenv().weatherHopRunning = enabled
			if enabled then
				notify("Weather Hopper enabled")
				startWeatherHopWorker()
			else
				notify("Weather Hopper disabled")
				uiRefs.weatherStatusLabel:SetText("Status: Idle")
			end
		end,
	})

	local menuSettingsGroup = uiRefs.Tabs.Settings:AddLeftGroupbox("Menu Settings", "wrench")
	local isKeybindMenuVisible = false
	pcall(function()
		isKeybindMenuVisible = Library.KeybindFrame.Visible
	end)

	menuSettingsGroup:AddToggle("KeybindMenuOpen", {
		Default = isKeybindMenuVisible,
		Text = "Open Keybind Menu",
		Callback = function(isVisible)
			pcall(function()
				Library.KeybindFrame.Visible = isVisible
			end)
		end,
	})

	menuSettingsGroup:AddToggle("ShowCustomCursor", {
		Text = "Custom Cursor",
		Default = true,
		Callback = function(isVisible)
			pcall(function()
				Library.ShowCustomCursor = isVisible
			end)
		end,
	})

	menuSettingsGroup:AddDropdown("NotificationSide", {
		Values = { "Left", "Right" },
		Default = "Right",
		Text = "Notification Side",
		Callback = function(side)
			pcall(function()
				Library:SetNotifySide(side)
			end)
		end,
	})

	menuSettingsGroup:AddDropdown("DPIScale", {
		Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
		Default = "100%",
		Text = "DPI Scale",
		Callback = function(displayScale)
			pcall(function()
				local numericScale = tonumber((displayScale:gsub("%%", "")))
				Library:SetDPIScale(numericScale)
			end)
		end,
	})

	menuSettingsGroup:AddSlider("UICornerRadius", {
		Text = "Corner Radius",
		Default = Library.CornerRadius or 0,
		Min = 0,
		Max = 20,
		Rounding = 0,
		Callback = function(radius)
			pcall(function()
				uiRefs.Window:SetCornerRadius(radius)
			end)
		end,
	})

	menuSettingsGroup:AddDivider()

	-- Two labels are retained because the source creates two controls here:
	-- the first is display-only and the second owns the key picker.
	menuSettingsGroup:AddLabel("Menu Bind")
	menuSettingsGroup:AddLabel("Menu Bind"):AddKeyPicker("MenuKeybind", {
		Default = "RightShift",
		NoUI = true,
		Text = "Menu Keybind",
	})

	menuSettingsGroup:AddButton({
		Text = "Unload",
		Func = function()
			for _, toggleId in ipairs({
				"FlyToggle",
				"InfJump",
				"NoClip",
				"AntiAFK",
				"BlackScreen",
				"Disable3DRender",
				"AntiLag",
				"RemoveFog",
				"HideOtherBuildings",
			}) do
				pcall(function()
					local toggle = Toggles[toggleId]
					if toggle and toggle.Value then
						toggle:SetValue(false)
					end
				end)
			end

			State.miscFlyEnabled = false
			State.miscInfJumpEnabled = false
			State.miscAntiAfkEnabled = false
			State.miscAutoJumpEnabled = false
			State.miscNoClipEnabled = false
			State.BlockNotif = false
			autoRemoveCollectItemsEnabled = false

			pcall(stopFlying)
			pcall(disableAntiAfk)
			pcall(restoreNoClipCollisions)
			pcall(function()
				setFogRemoved(false)
			end)
			pcall(function()
				RunService:Set3dRenderingEnabled(true)
			end)
			pcall(function()
				local character = LocalPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.WalkSpeed = 16
				end
			end)

			if State.miscInfJumpConn then
				pcall(function()
					State.miscInfJumpConn:Disconnect()
				end)
				State.miscInfJumpConn = nil
			end
			if State._perfDescConn then
				pcall(function()
					State._perfDescConn:Disconnect()
				end)
				State._perfDescConn = nil
			end

			stopRuntimeConnections()

			if uiRefs.mobileToggleGui then
				uiRefs.mobileToggleGui:Destroy()
				uiRefs.mobileToggleGui = nil
			end
			if uiRefs.blackScreenGui then
				uiRefs.blackScreenGui:Destroy()
				uiRefs.blackScreenGui = nil
			end
			pcall(function()
				Library:Unload()
			end)
		end,
	})

	pcall(function()
		Library.ToggleKeybind = Options.MenuKeybind
	end)

	ThemeManager:SetLibrary(Library)
	SaveManager:SetLibrary(Library)
	SaveManager:IgnoreThemeSettings()
	SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
	ThemeManager:SetFolder("CyraaHub/MiniWar")
	SaveManager:SetFolder("CyraaHub/MiniWar")

	pcall(function()
		SaveManager:BuildConfigSection(uiRefs.Tabs.Settings)
	end)
	pcall(function()
		ThemeManager:ApplyToTab(uiRefs.Tabs.Settings)
	end)
	pcall(function()
		SaveManager:LoadAutoloadConfig()
	end)

	Library.Scheme.AccentColor = Color3.fromRGB(0, 255, 33)
	Library:UpdateColorsUsingRegistry()
end

-- --------------------------------------------------------------------------
-- Interface shell orchestration and mobile toggle
-- --------------------------------------------------------------------------

local function buildInterface()
	createInterfaceShell()
	buildHomeFarmUi()
	buildShopTeleportMiscUi()
	buildServerSettingsUi()
end

local function toggleInterface()
	local toggled = pcall(function()
		Library:Toggle()
	end)
	if not toggled then
		toggled = pcall(function()
			Library:ToggleUI()
		end)
	end
	if not toggled then
		toggled = pcall(function()
			Library.Toggled = not Library.Toggled
		end)
	end
	if not toggled then
		toggled = pcall(function()
			uiRefs.Window.Visible = not uiRefs.Window.Visible
		end)
	end
	if not toggled then
		toggled = pcall(function()
			Library.GuiHolder.Visible = not Library.GuiHolder.Visible
		end)
	end
	if not toggled then
		toggled = pcall(function()
			Library.MainFrame.Visible = not Library.MainFrame.Visible
		end)
	end

	if not toggled then
		pcall(function()
			local virtualInputManager = game:GetService("VirtualInputManager")
			local menuKey = Options.MenuKeybind and Options.MenuKeybind.Value
			if menuKey then
				virtualInputManager:SendKeyEvent(true, menuKey, false, game)
				task.wait()
				virtualInputManager:SendKeyEvent(false, menuKey, false, game)
			end
		end)
	end
end

local function createMobileToggleButton()
	local parent = CoreGui
	local success, hiddenUi = pcall(function()
		return gethui and gethui()
	end)
	if success and hiddenUi then
		parent = hiddenUi
	end

	if uiRefs.mobileToggleGui then
		uiRefs.mobileToggleGui:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Cyraa"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 999
	screenGui.Parent = parent
	uiRefs.mobileToggleGui = screenGui

	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 55, 0, 55)
	local viewportSize = Workspace.CurrentCamera.ViewportSize
	button.Position = UDim2.new(0, 10, 0, (viewportSize.Y / 2) - 27.5)
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.ZIndex = 100
	button.Parent = screenGui

	local icon = Instance.new("ImageLabel")
	icon.Image = "rbxassetid://111485823583751"
	icon.Size = UDim2.new(0.7, 0, 0.7, 0)
	icon.Position = UDim2.new(0.15, 0, 0.15, 0)
	icon.BackgroundTransparency = 1
	icon.ZIndex = 101
	icon.Parent = button

	local isDragging = false
	local dragStart = nil
	local startPosition = nil
	local didDrag = false

	trackRuntimeConnection(button.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			isDragging = true
			didDrag = false
			dragStart = input.Position
			startPosition = button.Position
		end
	end))

	trackRuntimeConnection(button.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			isDragging = false
			if not didDrag then
				toggleInterface()
			end
		end
	end))

	trackRuntimeConnection(UserInputService.InputChanged:Connect(function(input)
		if not isDragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		local delta = input.Position - dragStart
		if math.abs(delta.X) > 3 or math.abs(delta.Y) > 3 then
			didDrag = true
		end

		local currentViewportSize = Workspace.CurrentCamera.ViewportSize
		local x = math.clamp(startPosition.X.Offset + delta.X, 0, currentViewportSize.X - 55)
		local y = math.clamp(startPosition.Y.Offset + delta.Y, 0, currentViewportSize.Y - 55)
		button.Position = UDim2.new(0, x, 0, y)
	end))

	return screenGui
end

-- --------------------------------------------------------------------------
-- Background workers and respawn hooks
-- --------------------------------------------------------------------------

local function startStatusWorker()
	task.spawn(function()
		while runtimeActive do
			task.wait(1)
			pcall(function()
				local elapsedSeconds = math.floor(Workspace.DistributedGameTime + 0.5)
				uiRefs.GameTimeLabel:SetText(
					"Game Time: "
						.. math.floor(elapsedSeconds / 3600) % 24
						.. "h "
						.. math.floor(elapsedSeconds / 60) % 60
						.. "m "
						.. elapsedSeconds % 60
						.. "s"
				)
				uiRefs.FpsLabel:SetText("FPS: " .. math.floor(Workspace:GetRealPhysicsFPS()))
				uiRefs.PingLabel:SetText(
					"Ping: " .. game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValueString()
				)
			end)
		end
	end)
end

local function initializeCollectItemDropdown()
	task.spawn(function()
		task.wait(3)
		local itemNames = getCollectibleItemNames()
		cachedCollectItemNames = itemNames

		if #itemNames > 0 then
			pcall(function()
				local dropdownValues = { "Any" }
				for _, itemName in ipairs(itemNames) do
					table.insert(dropdownValues, itemName)
				end
				uiRefs.collectItemDropdown:SetValues(dropdownValues)
				uiRefs.collectItemDropdown:SetValue({})
			end)
		else
			pcall(function()
				uiRefs.collectItemDropdown:SetValues({ "Any", "No items found" })
				uiRefs.collectItemDropdown:SetValue({})
			end)
		end
	end)
end

local function startUpgradeListRefreshWorker()
	task.spawn(function()
		while runtimeActive do
			task.wait(60)
			upgradeNames = getUpgradeNames()
			Config.UpgradeNames = upgradeNames

			pcall(function()
				if uiRefs.statsDropdown then
					local dropdownValues = { "None", "Any" }
					for _, upgradeName in ipairs(upgradeNames) do
						table.insert(dropdownValues, upgradeName)
					end
					uiRefs.statsDropdown:SetValues(dropdownValues)
				end
			end)
		end
	end)
end

local function bindCharacterRespawnHandler()
	trackRuntimeConnection(LocalPlayer.CharacterAdded:Connect(function(newCharacter)
		Character = newCharacter
		newCharacter:WaitForChild("HumanoidRootPart")
		HumanoidRootPart = newCharacter:FindFirstChild("HumanoidRootPart")

		if getgenv().miscFlyEnabled then
			stopFlying()
			task.wait(1)
			if runtimeActive and getgenv().miscFlyEnabled then
				startFlying()
			end
		end

		if getgenv().miscInfJumpEnabled then
			if getgenv().miscInfJumpConn then
				getgenv().miscInfJumpConn:Disconnect()
				getgenv().miscInfJumpConn = nil
			end

			getgenv().miscInfJumpConn = trackRuntimeConnection(UserInputService.JumpRequest:Connect(function()
				if getgenv().miscInfJumpEnabled then
					pcall(function()
						local character = LocalPlayer.Character
						local humanoid = character and character:FindFirstChildOfClass("Humanoid")
						if humanoid then
							humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
						end
					end)
				end
			end))
		end

		if getgenv().miscAntiAfkEnabled then
			pcall(enableAntiAfk)
		end
	end))
end

local function startRuntimeWorkers()
	pcall(createMobileToggleButton)
	startStatusWorker()
	initializeCollectItemDropdown()
	startUpgradeListRefreshWorker()
	bindCharacterRespawnHandler()

	notify("Cyraa Hub loaded successfully!\nMade by cyraajaaaa")
	print("made by komtolmmek2 script")
end

UI.buildServerSettingsUi = buildServerSettingsUi
UI.buildInterface = buildInterface
UI.toggleInterface = toggleInterface
UI.createMobileToggleButton = createMobileToggleButton
UI.startRuntimeWorkers = startRuntimeWorkers

-- Match the original top-level startup order: construct and restore the UI
-- first, then attach mobile controls, workers, and respawn hooks.
buildInterface()
startRuntimeWorkers()
