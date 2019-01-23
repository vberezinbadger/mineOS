
local EEPROMProxy, internetProxy, GPUProxy = component.proxy(component.list("eeprom")()), component.proxy(component.list("internet")()), component.proxy(component.list("gpu")())

local repositoryURL = "https://raw.githubusercontent.com/IgorTimofeev/MineOS/master/"
local installerURL = "Installer/"
local EFIURL = "EFI/Minified.lua"

local installerPath = "/MineOS installer/"
local installerPicturesPath = installerPath .. "Installer/Pictures/"
local OSPath = "/"

local screenWidth, screenHeight = GPUProxy.getResolution()

local temporaryFilesystemProxy, selectedFilesystemProxy

--------------------------------------------------------------------------------

local function centrize(width)
	return math.floor(screenWidth / 2 - width / 2)
end

local function centrizedText(y, color, text)
	GPUProxy.fill(1, y, screenWidth, 1, " ")
	GPUProxy.setForeground(color)
	GPUProxy.set(centrize(#text), y, text)
end

local function title()
	local y = math.floor(screenHeight / 2 - 1)
	centrizedText(y, 0x2D2D2D, "MineOS")
	return y + 2
end

local function status(text, needWait)
	centrizedText(title(), 0x878787, text)

	if needWait then
		repeat
			needWait = computer.pullSignal()
		until needWait == "key_down" or needWait == "touch"
	end
end

local function progress(value)
	local width = 26
	local x, y, part = centrize(width), title(), math.ceil(width * value)
	
	GPUProxy.setForeground(0x878787)
	GPUProxy.set(x, y, string.rep("─", part))
	GPUProxy.setForeground(0xC3C3C3)
	GPUProxy.set(x + part, y, string.rep("─", width - part))
end

local function filesystemPath(path)
	return path:match("^(.+%/).") or ""
end

local function filesystemName(path)
	return path:match("%/?([^%/]+%/?)$")
end

local function filesystemHideExtension(path)
	return path:match("(.+)%..+") or path
end

local function rawRequest(url, chunkHandler)
	local internetHandle, reason = internetProxy.request(repositoryURL .. url:gsub("([^%w%-%_%.%~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))

	if internetHandle then
		local chunk, reason
		while true do
			chunk, reason = internetHandle.read(math.huge)	
			
			if chunk then
				chunkHandler(chunk)
			else
				if reason then
					error("Internet request failed: " .. tostring(reason))
				end

				break
			end
		end

		internetHandle.close()
	else
		error("Connection failed: " .. url)
	end
end

local function request(url)
	local data = ""
	
	rawRequest(url, function(chunk)
		data = data .. chunk
	end)

	return data
end

local function download(url, path)
	selectedFilesystemProxy.makeDirectory(filesystemPath(path))

	local fileHandle, reason = selectedFilesystemProxy.open(path, "wb")
	if fileHandle then	
		rawRequest(url, function(chunk)
			selectedFilesystemProxy.write(fileHandle, chunk)
		end)

		selectedFilesystemProxy.close(fileHandle)
	else
		error("File opening failed: " .. tostring(reason))
	end
end

local function deserialize(text)
	local result, reason = load("return " .. text, "=string")
	if result then
		return result()
	else
		error(reason)
	end
end

--------------------------------------------------------------------------------

-- Clearing screen
GPUProxy.setBackground(0xE1E1E1)
GPUProxy.fill(1, 1, screenWidth, screenHeight, " ")

-- Searching for appropriate temporary filesystem for storing libraries, images, etc
for address in component.list("filesystem") do
	local proxy = component.proxy(address)
	if proxy.spaceTotal() >= 2 * 1024 * 1024 then
		temporaryFilesystemProxy, selectedFilesystemProxy = proxy, proxy
		break
	end
end

-- If there's no suitable HDDs found - then meow
if not temporaryFilesystemProxy then
	status("No appropriate filesystem found", true)
	return
end

-- First, we need a big ass file list with localizations, applications, wallpapers
progress(0)
local files = deserialize(request(installerURL .. "Files.cfg"))

-- After that we could download required libraries for installer from it
for i = 1, #files.installerFiles do
	progress(i / #files.installerFiles)
	download(files.installerFiles[i], installerPath .. files.installerFiles[i])
end

-- Initializing simple package system for loading OS libraries
package = {loading = {}, loaded = {}}

function require(module)
	if package.loaded[module] then
		return package.loaded[module]
	elseif package.loading[module] then
		error("already loading " .. module .. ": " .. debug.traceback())
	else
		package.loading[module] = true

		local handle, reason = temporaryFilesystemProxy.open(installerPath .. "Libraries/" .. module .. ".lua", "rb")
		if handle then
			local data, chunk = ""
			repeat
				chunk = temporaryFilesystemProxy.read(handle, math.huge)
				data = data .. (chunk or "")
			until not chunk

			temporaryFilesystemProxy.close(handle)
			
			package.loaded[module] = load(data, "=" .. module)() or true
		else
			error("File opening failed: " .. tostring(reason))
		end

		package.loading[module] = nil

		return package.loaded[module]
	end
end

-- Initializing downloaded libraries
local filesystem = require("Filesystem")
filesystem.setProxy(temporaryFilesystemProxy)

bit32 = bit32 or require("Bit32")
local image = require("Image")
local text = require("Text")
local number = require("Number")
local screen = require("Screen")
local GUI = require("GUI")
local system = require("System")
local paths = require("Paths")

--------------------------------------------------------------------------------

-- Creating out cool UI
local workspace = GUI.workspace()
workspace:addChild(GUI.panel(1, 1, workspace.width, workspace.height, 0x1E1E1E))

-- Main installer window
local window = workspace:addChild(GUI.window(1, 1, 80, 24))
window.localX, window.localY = math.ceil(workspace.width / 2 - window.width / 2), math.ceil(workspace.height / 2 - window.height / 2)
window:addChild(GUI.panel(1, 1, window.width, window.height, 0xE1E1E1))

-- Top menu
local menu = workspace:addChild(GUI.menu(1, 1, workspace.width, 0xF0F0F0, 0x787878, 0x3366CC, 0xE1E1E1))
local installerMenu = menu:addContextMenu("MineOS", 0x2D2D2D)
installerMenu:addItem("Shutdown").onTouch = function()
	computer.shutdown()
end
installerMenu:addItem("Reboot").onTouch = function()
	computer.shutdown(true)
end
installerMenu:addSeparator()
installerMenu:addItem("Exit").onTouch = function()
	workspace:stop()
end

-- Main vertical layout
local layout = window:addChild(GUI.layout(1, 1, window.width, window.height - 2, 1, 1))

local stageButtonsLayout = window:addChild(GUI.layout(1, window.height - 1, window.width, 1, 1, 1))
stageButtonsLayout:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
stageButtonsLayout:setSpacing(1, 1, 3)

local function loadImage(name)
	return image.load(installerPicturesPath .. name .. ".pic")
end

local function newInput(...)
	return GUI.input(1, 1, 26, 1, 0xF0F0F0, 0x787878, 0xC3C3C3, 0xF0F0F0, 0x878787, "", ...)
end

local function newSwitchAndLabel(width, color, text, state)
	return GUI.switchAndLabel(1, 1, width, 6, color, 0xD2D2D2, 0xF0F0F0, 0xA5A5A5, text .. ":", state)
end

local function addTitle(color, text)
	return layout:addChild(GUI.text(1, 1, color, text))
end

local function addImage(before, after, name)
	if before > 0 then
		layout:addChild(GUI.object(1, 1, 1, before))
	end

	local picture = layout:addChild(GUI.image(1, 1, loadImage(name)))
	picture.height = picture.height + after

	return picture
end

local function addStageButton(text)
	local button = stageButtonsLayout:addChild(GUI.adaptiveRoundedButton(1, 1, 2, 0, 0xC3C3C3, 0x878787, 0xA5A5A5, 0x696969, text))
	button.colors.disabled.background = 0xD2D2D2
	button.colors.disabled.text = 0xB4B4B4

	return button
end

local prevButton = addStageButton("<")
local nextButton = addStageButton(">")

local localization
local stage = 1
local stages = {}

local usernameInput = newInput("")
local passwordInput = newInput("", false, "•")
local passwordSubmitInput = newInput("", false, "•")
local passwordMatchText = GUI.text(1, 1, 0xCC0040, "")
local passwordSwitchAndLabel = newSwitchAndLabel(26, 0x66DB80, "", false)

local wallpapersSwitchAndLabel = newSwitchAndLabel(30, 0xFF4980, "", true)
local screensaversSwitchAndLabel = newSwitchAndLabel(30, 0xFFB600, "", true)
local applicationsSwitchAndLabel = newSwitchAndLabel(30, 0x33DB80, "", true)
local localizationsSwitchAndLabel = newSwitchAndLabel(30, 0x33B6FF, "", true)

local acceptSwitchAndLabel = newSwitchAndLabel(30, 0x9949FF, "", false)

local localizationComboBox = GUI.comboBox(1, 1, 22, 1, 0xF0F0F0, 0x969696, 0xD2D2D2, 0xB4B4B4)
for i = 1, #files.localizations do
	localizationComboBox:addItem(filesystemHideExtension(filesystemName(files.localizations[i]))).onTouch = function()
		-- Obtaining localization table
		localization = deserialize(request(installerURL .. files.localizations[i]))

		-- Filling widgets with selected localization data
		usernameInput.placeholderText = localization.username
		passwordInput.placeholderText = localization.password
		passwordSubmitInput.placeholderText = localization.submitPassword
		passwordMatchText.text = localization.passwordsArentEqual
		passwordSwitchAndLabel.label.text = localization.withoutPassword
		wallpapersSwitchAndLabel.label.text = localization.wallpapers
		screensaversSwitchAndLabel.label.text = localization.screensavers
		applicationsSwitchAndLabel.label.text = localization.applications
		localizationsSwitchAndLabel.label.text = localization.languages
		acceptSwitchAndLabel.label.text = localization.accept
	end
end

local function addStage(onTouch)
	table.insert(stages, function()
		layout:removeChildren()
		onTouch()
		workspace:draw()
	end)
end

local function loadStage()
	if stage < 1 then
		stage = 1
	elseif stage > #stages then
		stage = #stages
	end

	stages[stage]()
end

local function checkUserInputs()
	nextButton.disabled = #usernameInput.text == 0 or (not passwordSwitchAndLabel.switch.state and (#passwordInput.text == 0 or #passwordSubmitInput.text == 0 or passwordInput.text ~= passwordSubmitInput.text))
	passwordMatchText.hidden = passwordSwitchAndLabel.switch.state or #passwordInput.text == 0 or #passwordSubmitInput.text == 0 or passwordInput.text == passwordSubmitInput.text
end

local function checkLicense()
	nextButton.disabled = not acceptSwitchAndLabel.switch.state
end

prevButton.onTouch = function()
	stage = stage - 1
	loadStage()
end

nextButton.onTouch = function()
	stage = stage + 1
	loadStage()
end

acceptSwitchAndLabel.switch.onStateChanged = function()
	checkLicense()
	workspace:draw()
end

passwordSwitchAndLabel.switch.onStateChanged = function()
	passwordInput.hidden = passwordSwitchAndLabel.switch.state
	passwordSubmitInput.hidden = passwordSwitchAndLabel.switch.state
	checkUserInputs()

	workspace:draw()
end

usernameInput.onInputFinished = function()
	checkUserInputs()
	workspace:draw()
end

passwordInput.onInputFinished = usernameInput.onInputFinished
passwordSubmitInput.onInputFinished = usernameInput.onInputFinished

-- Localization selection stage
addStage(function()
	prevButton.disabled = true

	addImage(0, 1, "Languages")
	layout:addChild(localizationComboBox)

	workspace:draw()
	localizationComboBox:getItem(1).onTouch()
end)

-- Filesystem selection stage
addStage(function()
	prevButton.disabled = false
	nextButton.disabled = false

	layout:addChild(GUI.object(1, 1, 1, 1))
	addTitle(0x696969, localization.select)
	
	local diskLayout = layout:addChild(GUI.layout(1, 1, layout.width, 11, 1, 1))
	diskLayout:setDirection(1, 1, GUI.DIRECTION_HORIZONTAL)
	diskLayout:setSpacing(1, 1, 0)

	local HDDImage = loadImage("HDD")

	local function select(proxy)
		selectedFilesystemProxy = proxy

		for i = 1, #diskLayout.children do
			diskLayout.children[i].children[1].hidden = diskLayout.children[i].proxy ~= selectedFilesystemProxy
		end
	end

	local function updateDisks()
		local function diskEventHandler(workspace, disk, e1)
			if e1 == "touch" then
				select(disk.proxy)
				workspace:draw()
			end
		end

		local function addDisk(proxy, picture, disabled)
			local disk = diskLayout:addChild(GUI.container(1, 1, 14, diskLayout.height))

			local formatContainer = disk:addChild(GUI.container(1, 1, disk.width, disk.height))
			formatContainer:addChild(GUI.panel(1, 1, formatContainer.width, formatContainer.height, 0xD2D2D2))
			formatContainer:addChild(GUI.button(1, formatContainer.height, formatContainer.width, 1, 0xCC4940, 0xE1E1E1, 0x990000, 0xE1E1E1, localization.erase)).onTouch = function()
				local list, path = proxy.list("/")
				for i = 1, #list do
					path = "/" .. list[i]

					if proxy.address ~= temporaryFilesystemProxy.address or path ~= installerPath then
						proxy.remove(path)
					end
				end

				updateDisks()
			end

			if disabled then
				picture = image.blend(picture, 0xFFFFFF, 0.4)
				disk.disabled = true
			end

			disk:addChild(GUI.image(4, 2, picture))
			disk:addChild(GUI.label(2, 7, disk.width - 2, 1, disabled and 0x969696 or 0x696969, text.limit(proxy.getLabel() or proxy.address, disk.width - 2))):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
			disk:addChild(GUI.progressBar(2, 8, disk.width - 2, disabled and 0xCCDBFF or 0x66B6FF, disabled and 0xD2D2D2 or 0xC3C3C3, disabled and 0xC3C3C3 or 0xA5A5A5, math.floor(proxy.spaceUsed() / proxy.spaceTotal() * 100), true, true, "", "% " .. localization.used))

			disk.eventHandler = diskEventHandler
			disk.proxy = proxy
		end

		diskLayout:removeChildren()
		
		for address in component.list("filesystem") do
			local proxy = component.proxy(address)
			if proxy.spaceTotal() >= 1 * 1024 * 1024 then
				addDisk(
					proxy,
					proxy.spaceTotal() < 1 * 1024 * 1024 and floppyImage or HDDImage,
					proxy.isReadOnly() or proxy.spaceTotal() < 2 * 1024 * 1024
				)
			end
		end

		select(selectedFilesystemProxy)
	end
	
	updateDisks()
end)

-- User profile setup stage
addStage(function()
	checkUserInputs()

	addImage(0, 0, "User")
	addTitle(0x696969, localization.setup)

	layout:addChild(usernameInput)
	layout:addChild(passwordInput)
	layout:addChild(passwordSubmitInput)
	layout:addChild(passwordMatchText)
	layout:addChild(passwordSwitchAndLabel)
end)

-- Downloads customization stage
addStage(function()
	nextButton.disabled = false

	addImage(0, 0, "Settings")
	addTitle(0x696969, localization.customize)

	layout:addChild(wallpapersSwitchAndLabel)
	layout:addChild(screensaversSwitchAndLabel)
	layout:addChild(applicationsSwitchAndLabel)
	layout:addChild(localizationsSwitchAndLabel)
end)

-- License acception stage
addStage(function()
	checkLicense()

	local lines = text.wrap({request(repositoryURL .. "LICENSE")}, layout.width - 2)
	local textBox = layout:addChild(GUI.textBox(1, 1, layout.width, layout.height - 3, 0xF0F0F0, 0x696969, lines, 1, 1, 1))

	layout:addChild(acceptSwitchAndLabel)
end)

-- Downloading stage
addStage(function()
	stageButtonsLayout:removeChildren()
	
	-- Creating user profile
	layout:removeChildren()
	addImage(1, 1, "User")
	addTitle(0x969696, localization.creating)
	workspace:draw()

	-- Switching to selected filesystem proxy for performing system library operations
	
	-- Creating system paths
	filesystem.setProxy(selectedFilesystemProxy)

	paths.create(paths.system)
	local userProperties, userPaths = system.createUser(
		usernameInput.text,
		localizationComboBox:getItem(localizationComboBox.selectedItem).text,
		not passwordSwitchAndLabel.switch.state and passwordInput.text,
		wallpapersSwitchAndLabel.switch.state,
		screensaversSwitchAndLabel.switch.state
	)

	filesystem.setProxy(temporaryFilesystemProxy)

	-- Flashing EEPROM
	layout:removeChildren()
	addImage(1, 1, "EEPROM")
	addTitle(0x969696, localization.flashing)
	workspace:draw()
	
	EEPROMProxy.set(request(EFIURL))
	EEPROMProxy.setLabel("MineOS EFI")
	EEPROMProxy.setData(selectedFilesystemProxy.address)

	-- Downloading files
	layout:removeChildren()
	addImage(3, 2, "Downloading")

	local container = layout:addChild(GUI.container(1, 1, layout.width - 20, 2))
	local progressBar = container:addChild(GUI.progressBar(1, 1, container.width, 0x66B6FF, 0xD2D2D2, 0xA5A5A5, 0, true, false))
	local cyka = container:addChild(GUI.label(1, 2, container.width, 1, 0x969696, "")):setAlignment(GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)

	-- Creating final filelist of things to download
	local downloadList = {}

	local function getData(item)
		if type(item) == "table" then
			return item.path, item.id, item.shortcut
		else
			return item
		end
	end

	local function addToList(state, key)
		if state then
			local path
			for i = 1, #files[key] do
				path = getData(files[key][i])

				if 
					filesystem.extension(path) ~= ".lang" or
					(
						localizationsSwitchAndLabel.switch.state or
						filesystem.hideExtension(filesystem.name(path)) == localizationComboBox:getItem(localizationComboBox.selectedItem).text
					)
				then
					table.insert(downloadList, files[key][i])
				end
			end
		end
	end

	addToList(true, "required")
	addToList(true, "localizations")
	addToList(applicationsSwitchAndLabel.switch.state, "optional")
	addToList(wallpapersSwitchAndLabel.switch.state, "wallpapers")
	addToList(screensaversSwitchAndLabel.switch.state, "screensavers")

	-- Downloading files from created list
	local path, id, shortcut
	for i = 1, #downloadList do
		path, id, shortcut = getData(downloadList[i])

		cyka.text = text.limit(localization.installing .. " \"" .. path .. "\"", container.width, "center")
		workspace:draw()

		-- Download file
		download(path, OSPath .. path)

		-- Create shortcut if possible
		if shortcut then
			filesystem.setProxy(selectedFilesystemProxy)
			
			system.createShortcut(
				userPaths.desktop .. filesystem.hideExtension(filesystem.name(filesystem.path(path))),
				OSPath .. filesystem.path(path)
			)

			filesystem.setProxy(temporaryFilesystemProxy)
		end

		progressBar.value = math.floor(i / #downloadList * 100)
		workspace:draw()
	end

	-- Done info
	layout:removeChildren()
	addImage(1, 1, "Done")
	addTitle(0x969696, localization.installed)
	addStageButton(localization.reboot).onTouch = function()
		computer.shutdown(true)
	end
	workspace:draw()

	-- Removing temporary installer directory
	temporaryFilesystemProxy.remove(installerPath)
end)

--------------------------------------------------------------------------------

loadStage()
workspace:start()