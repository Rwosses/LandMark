-- Client-side region effects use the local character; they never authorize server gameplay actions.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- Keep region settings outside the runtime so the same detection and effect logic serves every region.
local Config = require(script.Config)
local RegionSystem = {}
-- Module-local state tracks one active region and one UI instance for this client.
local current, connection, gui, panel, title, description
local theme, lightingTween
-- Track every banner tween so a newer transition can cancel all animations belonging to the old banner.
local titleTweens = {}
-- Use sounds as keys so destruction callbacks can remove individual one-shot playback instances.
local sounds = {}
-- Capture only overridden properties, preserving the baseline until the player leaves or stops the system.
local originalLighting = {}
-- A version counter makes delayed banner tasks harmless after another transition or Stop().
local titleVersion = 0
-- A startup token prevents overlapping Start() calls from creating duplicate UI or Heartbeat connections.
local starting

-- Whitelist tweenable lighting values so config metadata and unrelated Lighting properties cannot be applied.
local lightingProperties = {
	Ambient = true, OutdoorAmbient = true, Brightness = true, ClockTime = true,
	FogColor = true, FogStart = true, FogEnd = true, ExposureCompensation = true,
	ColorShift_Top = true, ColorShift_Bottom = true,
}

-- BindableEvents notify other LocalScripts on this client; these events do not replicate to the server.
RegionSystem.Entered = Instance.new("BindableEvent")
RegionSystem.Entered.Name = "Entered"
RegionSystem.Entered.Parent = script
RegionSystem.Exited = Instance.new("BindableEvent")
RegionSystem.Exited.Name = "Exited"
RegionSystem.Exited.Parent = script

-- Fall back only when a key is missing: an explicit false must remain false to disable a feature.
local function option(region, key)
	local value = region[key]
	if value == nil then
		return Config.Defaults[key]
	end
	return value
end

-- Feature settings must be a table; missing Enabled means enabled, while false disables the whole feature.
local function enabled(value)
	return type(value) == "table" and value.Enabled ~= false
end

-- Share label styling between the title and description to keep their layout consistent.
local function createLabel(name, y, height, size, font)
	local label = Instance.new("TextLabel")
	label.Name = name
	-- A transparent label leaves the scene visible behind the region text.
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 20, 0, y)
	-- Reserve equal horizontal padding while allowing the label width to follow its parent.
	label.Size = UDim2.new(1, -40, 0, height)
	label.Font = font
	label.TextSize = size
	label.TextColor3 = Color3.fromRGB(245, 247, 250)
	label.TextStrokeColor3 = Color3.fromRGB(12, 14, 17)
	label.TextStrokeTransparency = 0.5
	-- Wrap long region names and descriptions rather than clipping them to one line.
	label.TextWrapped = true
	label.Text = ""
	label.Parent = panel
	return label
end

-- Construct the banner once at startup; region changes reuse these instances instead of rebuilding the UI.
local function createUI(playerGui)
	gui = Instance.new("ScreenGui")
	gui.Name = "RegionUI"
	-- Keep the same UI across respawns; character state is handled by detection rather than GUI recreation.
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	-- CanvasGroup lets the whole banner fade together while text and decorative elements also animate separately.
	panel = Instance.new("CanvasGroup")
	panel.Name = "Banner"
	-- Center the banner horizontally, with its top edge controlling the vertical placement.
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.fromScale(0.5, 0.16)
	-- Scale the width with the screen while keeping a predictable height for the decorative layout.
	panel.Size = UDim2.new(0.88, 0, 0, 160)
	panel.BackgroundTransparency = 1
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Parent = gui
	local size = Instance.new("UISizeConstraint")
	-- Cap banner width on large screens so the text and divider do not spread too far apart.
	size.MaxSize = Vector2.new(700, 160)
	size.Parent = panel
	title = createLabel("RegionName", 0, 64, 52, Enum.Font.Garamond)
	title.TextColor3 = Color3.fromRGB(250, 246, 235)
	-- Scale text to the available label bounds; the following constraint limits the usable font-size range.
	title.TextScaled = true
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MinTextSize = 22
	titleSize.MaxTextSize = 52
	titleSize.Parent = title
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.AnchorPoint = Vector2.new(0.5, 0.5)
	divider.Position = UDim2.new(0.5, 0, 0, 82)
	divider.Size = UDim2.new(0.62, 0, 0, 18)
	divider.BackgroundTransparency = 1
	divider.Parent = panel
	local diamond = Instance.new("Frame")
	diamond.Name = "Diamond"
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Size = UDim2.fromOffset(12, 12)
	-- A square rotated 45 degrees supplies the center diamond without requiring an image asset.
	diamond.Rotation = 45
	diamond.BorderSizePixel = 0
	diamond.BackgroundColor3 = Color3.fromRGB(244, 235, 211)
	diamond.Parent = divider
	-- Build mirrored divider lines from the same layout rules instead of maintaining two separate definitions.
	for _, side in { "Left", "Right" } do
		local line = Instance.new("Frame")
		line.Name = side .. "Line"
		local left = side == "Left"
		-- Anchor each line at its inner edge so expanding its width grows outward from the diamond.
		line.AnchorPoint = Vector2.new(left and 1 or 0, 0.5)
		line.Position = UDim2.new(0.5, left and -9 or 9, 0.5, 0)
		line.Size = UDim2.new(0.5, -9, 0, 1)
		line.BorderSizePixel = 0
		line.BackgroundColor3 = diamond.BackgroundColor3
		line.BackgroundTransparency = 0.15
		line.Parent = divider
	end
	description = createLabel("Description", 103, 46, 17, Enum.Font.Gotham)
	description.TextColor3 = Color3.fromRGB(232, 231, 225)
	-- Fit the description independently of the larger title; its own constraint keeps small text readable.
	description.TextScaled = true
	local descriptionSize = Instance.new("UITextSizeConstraint")
	descriptionSize.MinTextSize = 11
	descriptionSize.MaxTextSize = 17
	descriptionSize.Parent = description
	gui.Parent = playerGui
end

-- Cancel before starting another animation so competing tweens cannot fight over the same UI properties.
local function cancelTitleTweens()
	for _, tween in titleTweens do tween:Cancel() end
	table.clear(titleTweens)
end

-- Centralize easing and tracking; optional delay staggers the divider and description behind the title.
local function animateTitle(object, duration, properties, delay)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, 0, false, delay or 0)
	local tween = TweenService:Create(object, info, properties)
	table.insert(titleTweens, tween)
	tween:Play()
end

-- Invalidate suspended banner tasks before hiding the UI, preventing stale tasks from changing a new banner.
local function hideTitle()
	titleVersion += 1
	cancelTitleTweens()
	if panel then
		panel.GroupTransparency = 1
		panel.Visible = false
	end
end

-- Animate entry and exit with one implementation; entering selects settings and reverses the motion direction.
local function showTitle(region, entering, version)
	local settings = option(region, entering and "Intro" or "Outro")
	-- Skip disabled features and discard work whose transition was superseded or whose UI has been destroyed.
	if not enabled(settings) or version ~= titleVersion or not gui then return end
	-- Clamp animation duration to zero or above so instant transitions remain a valid configuration.
	local fade = math.max(Config.FadeTime, 0)
	-- Entry approaches from above and exit moves below, using the same centered resting position.
	local offset = entering and -8 or 8
	local diamond = panel.Divider.Diamond
	local lines = { panel.Divider.LeftLine, panel.Divider.RightLine }
	cancelTitleTweens()
	-- Reset the starting pose because a previous animation may have been interrupted halfway through.
	panel.Position = UDim2.new(0.5, 0, 0.16, offset)
	panel.GroupTransparency = 1
	panel.Visible = true
	title.Position = UDim2.new(0, 20, 0, 12)
	title.TextTransparency = 1
	title.TextStrokeTransparency = 1
	title.Text = option(region, "Name")
	description.Position = UDim2.new(0, 20, 0, 113)
	description.TextTransparency = 1
	description.TextStrokeTransparency = 1
	description.Text = option(region, "Description")
	diamond.Size = UDim2.fromOffset(0, 0)
	diamond.Rotation = entering and -45 or 135
	diamond.BackgroundTransparency = 1
	for _, line in lines do line.Size = UDim2.fromOffset(0, 1) end
	-- Expose the current banner direction as an attribute for local inspection and runtime checks.
	panel:SetAttribute("Direction", entering and "Entering" or "Leaving")
	animateTitle(panel, fade, { Position = UDim2.fromScale(0.5, 0.16), GroupTransparency = 0 })
	animateTitle(title, fade * 0.8, { Position = UDim2.new(0, 20, 0, 0), TextTransparency = 0, TextStrokeTransparency = 0.5 })
	animateTitle(diamond, fade * 0.8, { Size = UDim2.fromOffset(12, 12), Rotation = 45, BackgroundTransparency = 0 })
	for _, line in lines do
		animateTitle(line, fade * 0.8, { Size = UDim2.new(0.5, -9, 0, 1) }, fade * 0.2)
	end
	animateTitle(description, fade * 0.7, { Position = UDim2.new(0, 20, 0, 103), TextTransparency = 0, TextStrokeTransparency = 0.5 }, fade * 0.3)
	-- Hold the banner for the configured duration after opening; this yield can outlive the current transition.
	task.wait(fade + math.max(settings.Duration or 2, 0))
	-- Recheck after yielding: another region transition or Stop() may have invalidated this animation.
	if version ~= titleVersion or not gui then return end
	cancelTitleTweens()
	animateTitle(panel, fade, { Position = UDim2.new(0.5, 0, 0.16, offset), GroupTransparency = 1 })
	animateTitle(title, fade, { Position = UDim2.new(0, 20, 0, 12), TextTransparency = 1, TextStrokeTransparency = 1 })
	animateTitle(description, fade * 0.8, { Position = UDim2.new(0, 20, 0, 113), TextTransparency = 1, TextStrokeTransparency = 1 })
	animateTitle(diamond, fade * 0.8, { Size = UDim2.fromOffset(0, 0), Rotation = entering and -45 or 135, BackgroundTransparency = 1 })
	for _, line in lines do animateTitle(line, fade * 0.7, { Size = UDim2.fromOffset(0, 1) }) end
	task.wait(fade)
	-- Only the task that still owns the current banner may hide it after the closing animation.
	if version == titleVersion and panel then
		cancelTitleTweens()
		panel.Visible = false
	end
end

-- Destroy playback clones on transitions so old one-shots and looping themes do not accumulate.
local function clearSounds()
	for sound in sounds do sound:Destroy() end
	table.clear(sounds)
	if theme then theme:Destroy() end
	theme = nil
end

-- Resolve either an explicit configured asset or an Audio template, then create a client-local playback clone.
local function playSound(settings, regionId, name, looped)
	if not enabled(settings) then return nil end
	local id = tostring(settings.SoundId or "")
	local template
	-- An empty configured ID selects the template path, preserving template properties and child effects.
	if id == "" then
		local audio = script:FindFirstChild("Audio")
		local regionAudio = audio and audio:FindFirstChild(tostring(regionId))
		local defaultAudio = audio and audio:FindFirstChild("Default")
		template = regionAudio and regionAudio:FindFirstChild(name)
		-- Fall back to Default when a region-specific sound is absent, has the wrong class, or has no asset assigned.
		if not template or not template:IsA("Sound") or template.SoundId == "" then
			template = defaultAudio and defaultAudio:FindFirstChild(name)
		end
		if not template or not template:IsA("Sound") then return nil end
		id = template.SoundId
	end
	-- Accept numeric asset IDs and canonical Roblox asset-ID URLs, normalizing both before playback.
	local number = id:match("^%d+$") or id:match("^rbxassetid://(%d+)$")
	-- Allow built-in Roblox sounds as well; asset IDs still require experience permission to play.
	local builtIn = id:match("^rbxasset://sounds/%S+$")
	if (not number and not builtIn) or tonumber(number) == 0 then return nil end
	-- Cloning preserves template effects; explicit IDs instead use a fresh Sound with the configured settings.
	local sound = template and template:Clone() or Instance.new("Sound")
	sound.Name = "Region" .. name
	-- Cleanup must not accidentally trigger another playback when the cloned sound is destroyed.
	sound.PlayOnRemove = false
	sound:Stop()
	-- Always restart at the beginning even if a template contains an old playback position.
	sound.TimePosition = 0
	 sound.SoundId = number and "rbxassetid://" .. number or id
	-- An explicit config volume overrides the template while staying inside the supported volume range.
	if settings.Volume ~= nil then sound.Volume = math.clamp(settings.Volume, 0, 10) end
	sound.Looped = looped
	sound.Parent = SoundService
	-- One-shots clean themselves up; a looping theme remains owned by the active region until transition or Stop().
	if not looped then
		sounds[sound] = true
		sound.Ended:Once(function() sound:Destroy() end)
		-- Remove destroyed sounds from the tracking set so later cleanup does not retain stale references.
		sound.Destroying:Once(function() sounds[sound] = nil end)
		-- Provide a cleanup deadline even when an unavailable or stalled sound never fires Ended.
		Debris:AddItem(sound, 120)
	end
	sound:Play()
	return sound
end

-- Build a target from the saved baseline so properties omitted by the next region can return to their original values.
local function applyLighting(settings)
	if lightingTween then lightingTween:Cancel() end
	-- Clone the baseline rather than mutating it; restoration values must survive successive region overrides.
	local target = table.clone(originalLighting)
	local active = enabled(settings)
	if active then
		for property, value in settings do
			-- Only apply whitelisted properties with matching Roblox value types, avoiding invalid tween targets.
			if lightingProperties[property] and typeof(value) == typeof(Lighting[property]) then
				-- Save each baseline once, before its first override, rather than capturing an intermediate tween value.
				if originalLighting[property] == nil then originalLighting[property] = Lighting[property] end
				target[property] = value
			end
		end
	end
	if next(target) == nil then return end
	local tween = TweenService:Create(Lighting, TweenInfo.new(math.max(Config.LightingTransition, 0)), target)
	lightingTween = tween
	tween.Completed:Once(function(state)
		-- Clear the baseline only after the current restoration tween completes; canceled or superseded tweens must not clear it.
		if state == Enum.PlaybackState.Completed and lightingTween == tween and not active then
			table.clear(originalLighting)
		end
	end)
	tween:Play()
end

-- Coordinate state, notifications and effects in one place so every region change follows the same cleanup order.
local function transition(nextRegion, silent)
	local previous = current
	-- Multiple volumes with one RegionId form one logical region; moving between them must not replay entry effects.
	if previous and nextRegion and previous.id == nextRegion.id then
		current = nextRegion
		return
	end
	-- Staying outside regions produces no repeated exit events; silent invalid-character checks still clear lingering effects.
	if not previous and not nextRegion then
		if silent then
			hideTitle()
			clearSounds()
		end
		return
	end
	current = nextRegion
	hideTitle()
	clearSounds()
	-- Apply the next region settings, or restore the saved baseline when leaving all regions.
	applyLighting(nextRegion and option(nextRegion.config, "Lighting") or false)
	-- Expose the selected region on the UI; nil removes the attribute when no region is active.
	if gui then gui:SetAttribute("CurrentRegion", nextRegion and tostring(nextRegion.id) or nil) end
	if previous then
		if not silent then playSound(option(previous.config, "OutroMusic"), previous.id, "Outro", false) end
		-- Notify listeners with the previous region data after runtime state has already switched to the new selection.
		RegionSystem.Exited:Fire(previous.id, previous.config, previous.part)
	end
	if nextRegion then
		playSound(option(nextRegion.config, "IntroMusic"), nextRegion.id, "Intro", false)
		theme = playSound(option(nextRegion.config, "Theme"), nextRegion.id, "Theme", true)
		-- Provide logical identity, settings and the winning volume so listeners need not repeat the overlap query.
		RegionSystem.Entered:Fire(nextRegion.id, nextRegion.config, nextRegion.part)
	end
	-- Death or an invalid character clears state without presenting an exit banner.
	if silent then return end
	local version = titleVersion
	-- Run banner waits outside the Heartbeat callback so detection continues while animations are showing.
	task.spawn(function()
		if previous then showTitle(previous.config, false, version) end
		if nextRegion then showTitle(nextRegion.config, true, version) end
	end)
end

-- Select one active region from volume overlaps, resolving competition by priority and current-region continuity.
local function findRegion(player, overlap)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- Treat missing, dead or incomplete characters as a silent exit; detection resumes automatically on respawn.
	if not humanoid or humanoid.Health <= 0 or not character:FindFirstChild("HumanoidRootPart") then
		return nil, true
	end
	local folder = workspace:FindFirstChild("Regions")
	if not folder then return nil, false end
	local body = {}
	-- Include direct character body parts only; nested accessory handles and tool parts must not trigger a region.
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then table.insert(body, part) end
	end
	-- Reuse the OverlapParams object but refresh its inclusion filter for the current character.
	overlap.FilterDescendantsInstances = body
	local best, bestPriority
	-- Read descendant volumes so nested folders and runtime additions are supported without a separate cached registry.
	for _, part in folder:GetDescendants() do
		-- Skip containers and explicitly disabled volumes before performing the spatial query.
		if not part:IsA("BasePart") or part:GetAttribute("Enabled") == false then continue end
		-- Query the actual region-part geometry, including rotation; any included body part is sufficient to overlap.
		if #workspace:GetPartsInPart(part, overlap) == 0 then continue end
		-- A shared RegionId groups volumes; otherwise the part itself provides a distinct stable identity.
		local id = part:GetAttribute("RegionId") or part
		-- Unknown region IDs remain usable by falling back to the default configuration.
		local config = Config.Regions[id] or Config.Defaults
		local priority = option(config, "Priority")
		local keepCurrent = current and id == current.id
		-- Higher priority wins; an equal-priority current region prevents flicker while overlapping another volume.
		if not best or priority > bestPriority or (priority == bestPriority and keepCurrent) then
			best = { id = id, part = part, config = config }
			bestPriority = priority
		end
	end
	return best, false
end

-- Start idempotently and guard the PlayerGui wait against a concurrent Stop() or replacement startup.
function RegionSystem.Start()
	-- These visual and audio effects belong on the client, where Players.LocalPlayer and PlayerGui are available.
	assert(RunService:IsClient(), "RegionSystem.Start must run from a LocalScript")
	-- An existing update connection or pending startup means no second detector should be created.
	if connection or starting then return RegionSystem end
	local token = {}
	starting = token
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	-- The PlayerGui wait yields; abort if Stop() or another startup has replaced this token during the wait.
	if starting ~= token then return RegionSystem end
	createUI(playerGui)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	-- Detection needs a yes-or-no overlap result, so requesting at most one matching body part limits returned data.
	overlap.MaxParts = 1
	-- Noncollidable body parts can still participate; overlap filtering uses query eligibility instead of collision eligibility.
	overlap.RespectCanCollide = false
	local elapsed = 0
	-- Accumulate frame time but perform overlap scans only at the configured interval instead of on every frame.
	connection = RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		-- Clamp the minimum interval to keep an accidentally tiny setting from requesting unnecessarily frequent scans.
		if elapsed < math.max(Config.CheckInterval, 0.03) then return end
		elapsed = 0
		local nextRegion, silent = findRegion(player, overlap)
		transition(nextRegion, silent)
	end)
	-- Release the startup guard now that the update connection owns the running system.
	starting = nil
	return RegionSystem
end

-- Expose the selected region without forcing callers to inspect private state or perform another spatial query.
function RegionSystem.GetCurrentRegion()
	if current then return current.id, current.config, current.part end
	return nil
end

-- Release all runtime resources and restore lighting so restarting does not inherit stale effects or connections.
function RegionSystem.Stop()
	-- Invalidate any startup still waiting for PlayerGui before releasing the active runtime resources.
	starting = nil
	-- Disconnect Heartbeat first so cleanup cannot be followed by another detection update.
	if connection then connection:Disconnect() end
	connection = nil
	current = nil
	hideTitle()
	clearSounds()
	if lightingTween then lightingTween:Cancel() end
	lightingTween = nil
	-- Stop restores immediately after canceling the tween, ensuring no partially restored lighting is left behind.
	for property, value in originalLighting do Lighting[property] = value end
	table.clear(originalLighting)
	if gui then gui:Destroy() end
	-- Drop destroyed UI references so delayed banner tasks fail their guards and the next Start() creates fresh instances.
	gui, panel, title, description = nil, nil, nil, nil
end

-- Return the public module API; requiring the module alone does not start region detection.
return RegionSystem
