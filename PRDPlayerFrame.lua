local ADDON_NAME = "PRDPlayerFrame"

local defaults = {
    combatFlash = true,
    statusIcons = true,
    levelText = true,
    nameText = true,
    combatNumbers = true,
    alwaysShowPRD = true,
    hideTargetComboPoints = true,
}

local DB
local settingsCategory
local optionsPanel
local optionCheckboxes = {}

local clickBtn
local overlayFrame
local nameBadge
local nameOuterGlow
local nameText
local stateIcon
local leaderIcon
local roleIcon
local pvpIcon
local raidTargetIcon
local readyCheckIcon
local levelBadge
local levelText
local feedbackText
local setupTicker
local hitFlare = 0
local inEditMode = false
local editModeHooked = false
local nameHooked = false
local fadeHooked = false
local trackedComboObjects = {}

local ROLE_ATLASES = {
    TANK    = { "UI-HUD-UnitFrame-Player-Group-Role-Tank", "roleicon-tiny-tank", "UI-LFG-RoleIcon-Tank-Micro" },
    HEALER  = { "UI-HUD-UnitFrame-Player-Group-Role-Healer", "roleicon-tiny-healer", "UI-LFG-RoleIcon-Healer-Micro" },
    DAMAGER = { "UI-HUD-UnitFrame-Player-Group-Role-Damager", "roleicon-tiny-dps", "UI-LFG-RoleIcon-DPS-Micro" },
}

local ROLE_TEXCOORDS = {
    TANK    = { 0, 19/64, 22/64, 41/64 },
    HEALER  = { 20/64, 39/64, 1/64, 20/64 },
    DAMAGER = { 20/64, 39/64, 22/64, 41/64 },
}

local function SetIconTextureOrAtlas(tex, atlasList, fallbackTexture, l, r, t, b)
    if C_Texture and C_Texture.GetAtlasInfo and atlasList then
        for _, atlas in ipairs(atlasList) do
            if C_Texture.GetAtlasInfo(atlas) then
                tex:SetTexCoord(0, 1, 0, 1)
                tex:SetAtlas(atlas, false)
                return true
            end
        end
    end
    if fallbackTexture then
        tex:SetTexture(fallbackTexture)
        if l and r and t and b then
            tex:SetTexCoord(l, r, t, b)
        else
            tex:SetTexCoord(0, 1, 0, 1)
        end
        return true
    end
    return false
end

local function InitDB()
    if type(PRDPlayerFrameDB) ~= "table" then
        PRDPlayerFrameDB = {}
    end
    for k, v in pairs(defaults) do
        if PRDPlayerFrameDB[k] == nil then
            PRDPlayerFrameDB[k] = v
        end
    end
    DB = PRDPlayerFrameDB
end

local function SafeSetCVar(name, value)
    if InCombatLockdown() then return end
    if C_CVar and C_CVar.SetCVar then
        pcall(C_CVar.SetCVar, name, value)
    elseif SetCVar then
        pcall(SetCVar, name, value)
    end
end

local function ApplyPRDVisibilitySetting()
    if not DB then return end
    if DB.alwaysShowPRD then
        SafeSetCVar("nameplateShowSelf", "1")
        SafeSetCVar("NameplatePersonalShowAlways", "1")
        SafeSetCVar("NameplatePersonalShowInCombat", "1")
        SafeSetCVar("NameplatePersonalShowWithTarget", "1")
    else
        SafeSetCVar("NameplatePersonalShowAlways", "0")
    end
end

local function HideDefaultPlayerFrame()
    if InCombatLockdown() or inEditMode then return end
    if PlayerFrame then
        if UnregisterUnitWatch then
            pcall(UnregisterUnitWatch, PlayerFrame)
        end
        if RegisterStateDriver then
            pcall(RegisterStateDriver, PlayerFrame, "visibility", "hide")
        end
    end
end

local function RestoreDefaultPlayerFrameForEditMode()
    if InCombatLockdown() then return end
    if PlayerFrame and UnregisterStateDriver then
        pcall(UnregisterStateDriver, PlayerFrame, "visibility")
    end
end

local function GetFullCharacterName()
    local firstName = UnitName("player") or ""

    local customFuncs = {
        "UnitLastName",
        "UnitSecondaryName",
        "UnitSecondName",
        "UnitSurname",
        "GetUnitLastName",
        "GetUnitSecondaryName",
    }
    for _, fnName in ipairs(customFuncs) do
        local fn = _G[fnName]
        if type(fn) == "function" then
            local ok, last = pcall(fn, "player")
            if ok and type(last) == "string" and last ~= "" then
                if firstName ~= "" and not string.find(firstName, last, 1, true) then
                    return firstName .. " " .. last
                elseif firstName == "" then
                    return last
                end
            end
        end
    end

    local nameCandidates = {
        PlayerName,
        PlayerFrame and PlayerFrame.name,
        PlayerFrame and PlayerFrame.PlayerFrameContent
            and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain
            and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain.Name,
    }
    for _, fs in ipairs(nameCandidates) do
        if fs and fs.GetText then
            local text = fs:GetText()
            if text and text ~= "" and text ~= UNKNOWN and text ~= "Unknown" then
                if #text > #firstName then
                    return text
                end
            end
        end
    end

    return firstName
end

-- Recursively lock alpha to 0 on TargetFrame combo point frames/regions so even the 1st generated point never flashes
local function SuppressComboObjectRecursive(obj, hide)
    if not obj or type(obj) ~= "table" then return end

    if not obj._prdIsTargetCombo then
        obj._prdIsTargetCombo = true
        table.insert(trackedComboObjects, obj)

        if obj.SetAlpha then
            hooksecurefunc(obj, "SetAlpha", function(self, alpha)
                if DB and DB.hideTargetComboPoints and alpha ~= 0 and not self._prdSuppressingAlpha then
                    self._prdSuppressingAlpha = true
                    self:SetAlpha(0)
                    self._prdSuppressingAlpha = false
                end
            end)
        end

        if obj.HookScript and obj.HasScript and obj:HasScript("OnShow") then
            obj:HookScript("OnShow", function(self)
                if DB and DB.hideTargetComboPoints then
                    if UIFrameFadeRemoveFrame then
                        pcall(UIFrameFadeRemoveFrame, self)
                    end
                    self:SetAlpha(0)
                    if not InCombatLockdown() and self.Hide then
                        self:Hide()
                    end
                end
            end)
        end
    end

    if hide then
        if UIFrameFadeRemoveFrame then
            pcall(UIFrameFadeRemoveFrame, obj)
        end
        if obj.StopAnimating then
            pcall(obj.StopAnimating, obj)
        end
        if obj.SetAlpha then
            obj:SetAlpha(0)
        end
        if not InCombatLockdown() and obj.Hide then
            obj:Hide()
        end
    else
        if obj.SetAlpha then
            obj:SetAlpha(1)
        end
    end

    if obj.GetRegions then
        for _, region in ipairs({ obj:GetRegions() }) do
            SuppressComboObjectRecursive(region, hide)
        end
    end

    if obj.GetChildren then
        for _, child in ipairs({ obj:GetChildren() }) do
            SuppressComboObjectRecursive(child, hide)
        end
    end
end

local function HookFadeFunctionsForCombo()
    if fadeHooked then return end
    if type(UIFrameFadeIn) == "function" then
        hooksecurefunc("UIFrameFadeIn", function(frame)
            if frame and frame._prdIsTargetCombo and DB and DB.hideTargetComboPoints then
                if UIFrameFadeRemoveFrame then
                    pcall(UIFrameFadeRemoveFrame, frame)
                end
                frame:SetAlpha(0)
            end
        end)
    end
    if type(UIFrameFade) == "function" then
        hooksecurefunc("UIFrameFade", function(frame)
            if frame and frame._prdIsTargetCombo and DB and DB.hideTargetComboPoints then
                if UIFrameFadeRemoveFrame then
                    pcall(UIFrameFadeRemoveFrame, frame)
                end
                frame:SetAlpha(0)
            end
        end)
    end
    fadeHooked = true
end

local function UpdateTargetComboPoints()
    if not DB then return end
    local hide = DB.hideTargetComboPoints

    SuppressComboObjectRecursive(ComboFrame, hide)

    for i = 1, 10 do
        local cp = _G["ComboPoint" .. i]
        if cp then
            SuppressComboObjectRecursive(cp, hide)
        end
    end

    if TargetFrame then
        SuppressComboObjectRecursive(TargetFrame.ComboFrame, hide)
        SuppressComboObjectRecursive(TargetFrame.ComboPoints, hide)

        if TargetFrame.GetChildren then
            for _, child in ipairs({ TargetFrame:GetChildren() }) do
                local childName = child:GetName()
                if childName and string.find(childName, "Combo", 1, true) then
                    SuppressComboObjectRecursive(child, hide)
                end
            end
        end
    end

    for _, obj in ipairs(trackedComboObjects) do
        if hide then
            if obj.SetAlpha then
                obj:SetAlpha(0)
            end
        else
            if obj.SetAlpha then
                obj:SetAlpha(1)
            end
        end
    end

    if not hide and not InCombatLockdown() and ComboFrame_Update and ComboFrame then
        pcall(ComboFrame_Update, ComboFrame)
    end
end

local function UpdateNameCombatFrameVisual(inCombat)
    if not nameBadge or not DB then return end

    if DB.combatFlash and inCombat then
        nameBadge:SetBackdropColor(0.14, 0.01, 0.01, 0.65)
        nameBadge:SetBackdropBorderColor(1.0, 0.12, 0.12, 1.0)
        if nameOuterGlow then
            nameOuterGlow:Show()
        end
    else
        nameBadge:SetBackdropColor(0, 0, 0, 0)
        nameBadge:SetBackdropBorderColor(0, 0, 0, 0)
        if nameOuterGlow then
            nameOuterGlow:Hide()
        end
    end
end

local function UpdateIndicators()
    if not overlayFrame or not DB then return end

    local inCombat = UnitAffectingCombat("player")
    local resting = IsResting()

    -- 1. Level Badge in TOP-RIGHT corner
    if DB.levelText then
        local lvl = UnitLevel("player")
        if lvl and lvl > 0 then
            levelText:SetText(lvl)
            local textW = levelText:GetStringWidth() or 14
            levelBadge:SetWidth(math.max(22, textW + 10))
            levelBadge:Show()
        else
            levelBadge:Hide()
        end
    else
        levelBadge:Hide()
    end

    -- 2. Resting ZZZ / Combat Crossed Swords (to the left of the top-right level badge)
    if DB.statusIcons then
        stateIcon:ClearAllPoints()
        if levelBadge:IsShown() then
            stateIcon:SetPoint("RIGHT", levelBadge, "LEFT", -2, 0)
        else
            stateIcon:SetPoint("BOTTOMRIGHT", overlayFrame, "TOPRIGHT", 0, 2)
        end

        if inCombat then
            SetIconTextureOrAtlas(
                stateIcon,
                { "UI-HUD-UnitFrame-Player-CombatIcon", "Player-CombatIcon" },
                "Interface\\CharacterFrame\\UI-StateIcon",
                0.5, 1.0, 0.0, 0.49
            )
            stateIcon:SetAlpha(1)
            stateIcon:Show()
        elseif resting then
            SetIconTextureOrAtlas(
                stateIcon,
                nil,
                "Interface\\CharacterFrame\\UI-StateIcon",
                0.0, 0.5, 0.0, 0.421875
            )
            stateIcon:Show()
        else
            stateIcon:Hide()
        end

        -- 3. Party/Raid Leader Crown or Assistant Icon (top-left)
        if UnitIsGroupLeader("player") then
            SetIconTextureOrAtlas(
                leaderIcon,
                { "UI-HUD-UnitFrame-Player-Group-LeaderIcon", "GroupFinder-Icon-Leader" },
                "Interface\\GroupFrame\\UI-Group-LeaderIcon"
            )
            leaderIcon:Show()
        elseif IsInRaid() and UnitIsGroupAssistant("player") then
            SetIconTextureOrAtlas(
                leaderIcon,
                { "UI-HUD-UnitFrame-Player-Group-AssistantIcon" },
                "Interface\\GroupFrame\\UI-Group-AssistantIcon"
            )
            leaderIcon:Show()
        else
            leaderIcon:Hide()
        end

        -- 4. Group Role Icon (next to leader icon)
        local role = UnitGroupRolesAssigned("player")
        local atlases = ROLE_ATLASES[role]
        local coords = ROLE_TEXCOORDS[role]
        if atlases or coords then
            SetIconTextureOrAtlas(
                roleIcon,
                atlases,
                "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES",
                coords and coords[1], coords and coords[2], coords and coords[3], coords and coords[4]
            )
            roleIcon:ClearAllPoints()
            if leaderIcon:IsShown() then
                roleIcon:SetPoint("LEFT", leaderIcon, "RIGHT", 2, 0)
            else
                roleIcon:SetPoint("BOTTOMLEFT", overlayFrame, "TOPLEFT", 1, 2)
            end
            roleIcon:Show()
        else
            roleIcon:Hide()
        end

        -- 5. PvP / War Mode Badge (left edge)
        local faction = UnitFactionGroup("player")
        if UnitIsPVPFreeForAll("player") then
            SetIconTextureOrAtlas(
                pvpIcon,
                { "UI-HUD-UnitFrame-Player-PVP-FFA" },
                "Interface\\TargetingFrame\\UI-PVP-FFA"
            )
            pvpIcon:Show()
        elseif faction and UnitIsPVP("player") then
            SetIconTextureOrAtlas(
                pvpIcon,
                { "UI-HUD-UnitFrame-Player-PVP-" .. faction },
                "Interface\\TargetingFrame\\UI-PVP-" .. faction
            )
            pvpIcon:Show()
        else
            pvpIcon:Hide()
        end

        -- 6. Raid Target Marker (top-center)
        local raidIdx = GetRaidTargetIndex("player")
        if raidIdx and raidIdx >= 1 and raidIdx <= 8 and SetRaidTargetIconTexture then
            raidTargetIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            SetRaidTargetIconTexture(raidTargetIcon, raidIdx)
            raidTargetIcon:Show()
        else
            raidTargetIcon:Hide()
        end
    else
        stateIcon:Hide()
        leaderIcon:Hide()
        roleIcon:Hide()
        pvpIcon:Hide()
        raidTargetIcon:Hide()
    end

    -- 7. Full Character Name + Compact Red Combat Frame around Name
    nameBadge:ClearAllPoints()
    if roleIcon:IsShown() then
        nameBadge:SetPoint("LEFT", roleIcon, "RIGHT", 3, 0)
    elseif leaderIcon:IsShown() then
        nameBadge:SetPoint("LEFT", leaderIcon, "RIGHT", 3, 0)
    else
        nameBadge:SetPoint("BOTTOMLEFT", overlayFrame, "TOPLEFT", 0, 2)
    end

    if DB.nameText then
        local fullName = GetFullCharacterName()
        if fullName and fullName ~= "" then
            local _, classFile = UnitClass("player")
            local color = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[classFile]
            if color then
                nameText:SetTextColor(color.r, color.g, color.b)
            else
                nameText:SetTextColor(1.0, 0.82, 0.0)
            end
            nameText:SetText(fullName)
            nameText:Show()

            local w = nameText:GetStringWidth() or 60
            nameBadge:SetSize(w + 10, 16)
            nameBadge:Show()
            UpdateNameCombatFrameVisual(inCombat)
        else
            nameText:Hide()
            nameBadge:Hide()
        end
    else
        nameText:Hide()
        if DB.combatFlash and inCombat then
            nameBadge:SetSize(36, 10)
            nameBadge:Show()
            UpdateNameCombatFrameVisual(true)
        else
            nameBadge:Hide()
        end
    end
end

local function HookDefaultNameUpdates()
    if nameHooked then return end
    local nameCandidates = {
        PlayerName,
        PlayerFrame and PlayerFrame.name,
        PlayerFrame and PlayerFrame.PlayerFrameContent
            and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain
            and PlayerFrame.PlayerFrameContent.PlayerFrameContentMain.Name,
    }
    local hookedAny = false
    for _, fs in ipairs(nameCandidates) do
        if fs and fs.SetText then
            hooksecurefunc(fs, "SetText", function()
                UpdateIndicators()
            end)
            hookedAny = true
        end
    end
    if hookedAny then
        nameHooked = true
    end
end

local function HookEditMode()
    if editModeHooked or not EditModeManagerFrame then return end

    EditModeManagerFrame:HookScript("OnShow", function()
        inEditMode = true
        if not InCombatLockdown() then
            if clickBtn then
                clickBtn:EnableMouse(false)
                clickBtn:Hide()
            end
            RestoreDefaultPlayerFrameForEditMode()
        end
    end)

    EditModeManagerFrame:HookScript("OnHide", function()
        inEditMode = false
        if not InCombatLockdown() then
            HideDefaultPlayerFrame()
            local prd = PersonalResourceDisplayFrame
            if prd then
                if clickBtn then
                    clickBtn:ClearAllPoints()
                    clickBtn:SetAllPoints(prd)
                    clickBtn:EnableMouse(true)
                    clickBtn:Show()
                end
                if overlayFrame then
                    overlayFrame:ClearAllPoints()
                    overlayFrame:SetAllPoints(prd)
                end
            end
        end
        UpdateIndicators()
    end)

    editModeHooked = true
end

local function ApplyAllSettings()
    ApplyPRDVisibilitySetting()
    UpdateTargetComboPoints()
    UpdateIndicators()
    for key, cb in pairs(optionCheckboxes) do
        if DB[key] ~= nil then
            cb:SetChecked(DB[key])
        end
    end
end

local function UpdateReadyCheck(event, arg1, arg2)
    if not readyCheckIcon then return end
    if event == "READY_CHECK" then
        SetIconTextureOrAtlas(
            readyCheckIcon,
            { "UI-LFG-PendingMark" },
            "Interface\\RaidFrame\\ReadyCheck-Waiting"
        )
        readyCheckIcon:Show()
    elseif event == "READY_CHECK_CONFIRM" then
        if arg1 == "player" then
            if arg2 then
                SetIconTextureOrAtlas(
                    readyCheckIcon,
                    { "UI-LFG-ReadyMark" },
                    "Interface\\RaidFrame\\ReadyCheck-Ready"
                )
            else
                SetIconTextureOrAtlas(
                    readyCheckIcon,
                    { "UI-LFG-DeclineMark" },
                    "Interface\\RaidFrame\\ReadyCheck-NotReady"
                )
            end
            readyCheckIcon:Show()
        end
    elseif event == "READY_CHECK_FINISHED" then
        C_Timer.After(1.5, function()
            if readyCheckIcon then
                readyCheckIcon:Hide()
            end
        end)
    end
end

local function SetupOptionsPanel()
    if optionsPanel then return end

    optionsPanel = CreateFrame("Frame", "PRDPlayerFrameOptionsPanel")
    optionsPanel.name = "PRD Player Frame"

    local title = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("PRD Player Frame")

    local subtitle = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("Configure your Personal Resource Display player frame replacement.")

    local divider = optionsPanel:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -10)
    divider:SetPoint("RIGHT", optionsPanel, "RIGHT", -16, 0)
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.5)

    local optionsList = {
        {
            key = "combatFlash",
            label = "Red Combat Frame Around Name",
            desc = "Highlights your character name with a compact glowing red frame in combat and aggro.",
        },
        {
            key = "statusIcons",
            label = "Status Icons (ZZZ, Swords, Leader, Role, PvP, Raid Marker)",
            desc = "Displays resting ZZZ, combat crossed swords, group leader/role icons, PvP badge, and raid markers.",
        },
        {
            key = "nameText",
            label = "Character Name (First & Secondary Name)",
            desc = "Displays your full class-colored character name above the Personal Resource Display.",
        },
        {
            key = "levelText",
            label = "Character Level Badge (Top-Right)",
            desc = "Displays your character level in a badge at the top-right corner.",
        },
        {
            key = "combatNumbers",
            label = "Floating Combat Numbers",
            desc = "Displays incoming damage, heals, dodges, parries, and absorbs over the bars.",
        },
        {
            key = "alwaysShowPRD",
            label = "Always Show Personal Resource Display",
            desc = "Keeps the Personal Resource Display visible out of combat and while resting.",
        },
        {
            key = "hideTargetComboPoints",
            label = "Hide Combo Points on Target Frame",
            desc = "Completely hides combo points on your Target Frame while keeping them on the Personal Resource Display.",
        },
    }

    local prevAnchor = divider
    for i, opt in ipairs(optionsList) do
        local cb = CreateFrame("CheckButton", "PRDPlayerFrameOption_" .. opt.key, optionsPanel, "UICheckButtonTemplate")
        if i == 1 then
            cb:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -14)
        else
            cb:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -18)
        end
        cb:SetSize(26, 26)
        cb:SetChecked(DB[opt.key])

        local label = cb:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("LEFT", cb, "RIGHT", 6, 2)
        label:SetText(opt.label)

        local desc = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
        desc:SetTextColor(0.75, 0.75, 0.75)
        desc:SetText(opt.desc)

        cb:SetHitRectInsets(0, -420, 0, -12)

        cb:SetScript("OnClick", function(self)
            DB[opt.key] = self:GetChecked() and true or false
            ApplyAllSettings()
        end)

        optionCheckboxes[opt.key] = cb
        prevAnchor = cb
    end

    local resetBtn = CreateFrame("Button", "PRDPlayerFrameResetButton", optionsPanel, "UIPanelButtonTemplate")
    resetBtn:SetSize(140, 24)
    resetBtn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 2, -24)
    resetBtn:SetText("Reset to Defaults")
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(defaults) do
            DB[k] = v
        end
        ApplyAllSettings()
    end)

    optionsPanel:SetScript("OnShow", function()
        for key, cb in pairs(optionCheckboxes) do
            if DB[key] ~= nil then
                cb:SetChecked(DB[key])
            end
        end
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        settingsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel, "PRD Player Frame")
        settingsCategory.ID = "PRD Player Frame"
        Settings.RegisterAddOnCategory(settingsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(optionsPanel)
    end
end

local function OpenOptionsMenu()
    if Settings and Settings.OpenToCategory and settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    end
end

local function SetupPRDFrame()
    local prd = PersonalResourceDisplayFrame
    if not prd or clickBtn then return end
    if InCombatLockdown() then return end

    if setupTicker then
        setupTicker:Cancel()
        setupTicker = nil
    end

    -- 1. Secure clickable overlay matching the PRD bounds
    clickBtn = CreateFrame("Button", "PRDPlayerFrameUnitButton", UIParent, "SecureUnitButtonTemplate")
    clickBtn:SetAllPoints(prd)
    clickBtn:SetFrameStrata("MEDIUM")
    clickBtn:SetFrameLevel(20)
    clickBtn:RegisterForClicks("AnyUp")
    clickBtn:SetAttribute("unit", "player")
    clickBtn:SetAttribute("*type1", "target")
    clickBtn:SetAttribute("*type2", "togglemenu")
    clickBtn.unit = "player"

    local hoverTex = clickBtn:CreateTexture(nil, "HIGHLIGHT")
    hoverTex:SetAllPoints(clickBtn)
    hoverTex:SetColorTexture(1, 1, 1, 0.08)

    clickBtn:SetScript("OnEnter", function(self)
        if inEditMode then return end
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        GameTooltip:SetUnit("player")
        GameTooltip:Show()
    end)
    clickBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- 2. Visual overlay parented to UIParent (anchored to PRD)
    overlayFrame = CreateFrame("Frame", "PRDPlayerFrameOverlayFrame", UIParent)
    overlayFrame:SetAllPoints(prd)
    overlayFrame:SetFrameStrata("MEDIUM")
    overlayFrame:SetFrameLevel(18)

    -- Level badge pill in TOP-RIGHT corner
    levelBadge = CreateFrame("Frame", nil, overlayFrame, "BackdropTemplate")
    levelBadge:SetSize(24, 16)
    levelBadge:SetPoint("BOTTOMRIGHT", overlayFrame, "TOPRIGHT", 0, 2)
    levelBadge:SetFrameLevel(22)
    levelBadge:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    levelBadge:SetBackdropColor(0.08, 0.06, 0.02, 0.9)
    levelBadge:SetBackdropBorderColor(0.85, 0.68, 0.2, 1.0)
    levelBadge:Hide()

    levelText = levelBadge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelText:SetPoint("CENTER", levelBadge, "CENTER", 0, 0)
    levelText:SetTextColor(1.0, 0.82, 0.0)

    -- Resting ZZZ / Combat Crossed Swords icon (positioned to the left of the top-right level badge)
    stateIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    stateIcon:SetSize(22, 22)
    stateIcon:SetPoint("RIGHT", levelBadge, "LEFT", -2, 0)
    stateIcon:Hide()

    -- Leader crown / Assistant icon (top-left)
    leaderIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    leaderIcon:SetSize(16, 16)
    leaderIcon:SetPoint("BOTTOMLEFT", overlayFrame, "TOPLEFT", 1, 2)
    leaderIcon:Hide()

    -- Group role icon (top-left)
    roleIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    roleIcon:SetSize(16, 16)
    roleIcon:Hide()

    -- Compact name container + crisp red combat border around the name
    nameBadge = CreateFrame("Frame", nil, overlayFrame, "BackdropTemplate")
    nameBadge:SetSize(70, 16)
    nameBadge:SetPoint("BOTTOMLEFT", overlayFrame, "TOPLEFT", 0, 2)
    nameBadge:SetFrameLevel(22)
    nameBadge:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    nameBadge:SetBackdropColor(0, 0, 0, 0)
    nameBadge:SetBackdropBorderColor(0, 0, 0, 0)

    -- Soft outer red glow exclusively around the name frame in combat
    nameOuterGlow = CreateFrame("Frame", nil, nameBadge, "BackdropTemplate")
    nameOuterGlow:SetPoint("TOPLEFT", nameBadge, "TOPLEFT", -2, 2)
    nameOuterGlow:SetPoint("BOTTOMRIGHT", nameBadge, "BOTTOMRIGHT", 2, -2)
    nameOuterGlow:SetFrameLevel(21)
    nameOuterGlow:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    nameOuterGlow:SetBackdropBorderColor(1.0, 0.08, 0.08, 0.45)
    nameOuterGlow:Hide()

    nameText = nameBadge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("CENTER", nameBadge, "CENTER", 0, 0)
    nameText:SetShadowOffset(1, -1)
    nameText:SetShadowColor(0, 0, 0, 1)
    nameText:Hide()

    -- PvP icon (left edge)
    pvpIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    pvpIcon:SetSize(24, 24)
    pvpIcon:SetPoint("RIGHT", overlayFrame, "LEFT", -2, 0)
    pvpIcon:Hide()

    -- Raid target marker (top-center)
    raidTargetIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    raidTargetIcon:SetSize(20, 20)
    raidTargetIcon:SetPoint("BOTTOM", overlayFrame, "TOP", 0, 2)
    raidTargetIcon:Hide()

    -- Ready check icon (center)
    readyCheckIcon = overlayFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    readyCheckIcon:SetSize(26, 26)
    readyCheckIcon:SetPoint("CENTER", overlayFrame, "CENTER", 0, 0)
    readyCheckIcon:Hide()

    -- Floating combat feedback text
    feedbackText = overlayFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
    feedbackText:SetPoint("CENTER", overlayFrame, "CENTER", 0, 0)
    feedbackText:Hide()
    if CombatFeedback_Initialize then
        CombatFeedback_Initialize(overlayFrame, feedbackText, 18)
    end

    overlayFrame:SetScript("OnUpdate", function(self, elapsed)
        if inEditMode then return end
        local now = GetTime()

        if hitFlare > 0 then
            hitFlare = math.max(0, hitFlare - elapsed * 3.0)
        end

        if nameOuterGlow and nameOuterGlow:IsShown() then
            local threat = UnitThreatSituation("player") or 0
            local speed = (threat >= 3) and 8.5 or 5.0
            local wave = 0.5 + 0.5 * math.sin(now * speed)
            local flareBoost = hitFlare * 0.45

            nameBadge:SetBackdropBorderColor(
                1.0,
                math.min(1.0, 0.12 + flareBoost * 0.6),
                math.min(1.0, 0.12 + flareBoost * 0.6),
                math.min(1.0, 0.78 + 0.22 * wave + flareBoost)
            )
            nameOuterGlow:SetBackdropBorderColor(
                1.0,
                0.06,
                0.06,
                math.min(0.85, 0.22 + 0.32 * wave + flareBoost)
            )
        end

        if stateIcon:IsShown() and not UnitAffectingCombat("player") and IsResting() then
            local zzzPulse = 0.65 + 0.35 * math.sin(now * 3.2)
            stateIcon:SetAlpha(zzzPulse)
        end

        if DB and DB.combatNumbers and self.feedbackStartTime and CombatFeedback_OnUpdate then
            CombatFeedback_OnUpdate(self, elapsed)
        elseif feedbackText and feedbackText:IsShown() and not self.feedbackStartTime then
            feedbackText:Hide()
        end
    end)

    HookDefaultNameUpdates()
    HookEditMode()
    UpdateIndicators()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UNIT_POWER_UPDATE")
eventFrame:RegisterEvent("UNIT_POWER_FREQUENT")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
eventFrame:RegisterEvent("UNIT_FACTION")
eventFrame:RegisterEvent("UNIT_LEVEL")
eventFrame:RegisterEvent("UNIT_NAME_UPDATE")
eventFrame:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
eventFrame:RegisterEvent("UNIT_COMBAT")
eventFrame:RegisterEvent("READY_CHECK")
eventFrame:RegisterEvent("READY_CHECK_CONFIRM")
eventFrame:RegisterEvent("READY_CHECK_FINISHED")

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4, arg5)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_EditMode" then
            HookEditMode()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        InitDB()
        SetupOptionsPanel()
        HookFadeFunctionsForCombo()
        HookDefaultNameUpdates()
        HookEditMode()
        ApplyPRDVisibilitySetting()
        HideDefaultPlayerFrame()
        SetupPRDFrame()
        UpdateTargetComboPoints()

        if not self.comboHooked then
            if ComboFrame_Update then
                hooksecurefunc("ComboFrame_Update", UpdateTargetComboPoints)
            end
            if ComboFrame_OnEvent then
                hooksecurefunc("ComboFrame_OnEvent", UpdateTargetComboPoints)
            end
            if TargetFrame_Update then
                hooksecurefunc("TargetFrame_Update", UpdateTargetComboPoints)
            end
            self.comboHooked = true
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        HookFadeFunctionsForCombo()
        HookDefaultNameUpdates()
        HookEditMode()
        ApplyPRDVisibilitySetting()
        HideDefaultPlayerFrame()
        SetupPRDFrame()
        UpdateTargetComboPoints()
        UpdateIndicators()

        if not clickBtn and not setupTicker then
            setupTicker = C_Timer.NewTicker(0.25, function()
                HookDefaultNameUpdates()
                HookEditMode()
                ApplyPRDVisibilitySetting()
                HideDefaultPlayerFrame()
                SetupPRDFrame()
                UpdateTargetComboPoints()
                UpdateIndicators()
            end, 20)
        end

        C_Timer.After(1.0, UpdateIndicators)
        return
    end

    if event == "PLAYER_TARGET_CHANGED" or event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
        if (event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT") and arg1 ~= "player" then
            return
        end
        UpdateTargetComboPoints()
        return
    end

    if event == "UNIT_COMBAT" then
        if arg1 == "player" and overlayFrame then
            if DB and DB.combatNumbers and CombatFeedback_OnCombatEvent then
                CombatFeedback_OnCombatEvent(overlayFrame, arg2, arg3, arg4, arg5)
            end
            if DB and DB.combatFlash and arg2 == "WOUND" then
                hitFlare = 1.0
            end
        end
        return
    end

    if event == "READY_CHECK" or event == "READY_CHECK_CONFIRM" or event == "READY_CHECK_FINISHED" then
        UpdateReadyCheck(event, arg1, arg2)
        return
    end

    if (event == "UNIT_FACTION" or event == "UNIT_LEVEL" or event == "UNIT_NAME_UPDATE" or event == "UNIT_THREAT_SITUATION_UPDATE") and arg1 ~= "player" then
        return
    end

    UpdateIndicators()
end)

SLASH_PRDPLAYERFRAME1 = "/prdp"
SLASH_PRDPLAYERFRAME2 = "/prdpf"
SLASH_PRDPLAYERFRAME3 = "/prdplayerframe"
SlashCmdList["PRDPLAYERFRAME"] = function()
    OpenOptionsMenu()
end
