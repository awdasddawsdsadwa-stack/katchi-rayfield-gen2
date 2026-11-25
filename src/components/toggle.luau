--!nonstrict

-- Copyright (c) 2026 Corridon Capital
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

local Toggle = {}
Toggle.__index = Toggle
Toggle.__type = "Toggle"

-- Utility
local utility = script.Parent.Parent.utility

-- Variables
local variables = require(utility.variables)
local functions = require(utility.functions)
local moveable = require(utility.moveable)
local lockable = require(utility.lockable)
local locale = require(utility.locale)
local inlineDescription = require(utility.inlineDescription)
local hapticEngine = require(utility.HapticEngine)
local enums = require(utility.enums)
local log = require(utility.log)
-- Share key coercion/naming/capture/matching with the dedicated Keybind element so both
-- agree on what a key is and how it fires. No circular require: keybind never loads toggle.
local keybindUtils = require(script.Parent.keybind)

function Toggle.new(tab, properties)
    properties = if typeof(properties) == "table" then properties else {}

    local self = setmetatable({
        tab = assert(tab, "Missing argument #1 (Tab expected)"),
        window = tab.window,
        name = properties.name or properties.Name or "Switch",
        icon = properties.icon or properties.Icon,
        description = properties.description or properties.Description,
        forgetState = properties.forgetState or properties.ForgetState or tab.forgetState, -- dont save config for this element if true.
        compact = tab.compact or false, -- true when the host is a Row

        flag = properties.flag
            or properties.Flag
            or (
                not (properties.forgetState or properties.ForgetState or tab.forgetState)
                    and functions.deriveFlagFromName(properties.name or properties.Name or "Switch")
                or nil
            ),

        callback = properties.callback or properties.Callback or function() end,

        -- Right-click to record a hotkey. Accepts a KeyCode / UserInputType / PlayerActions
        -- EnumItem, a key name string, or nil for unbound (see keybindUtils.coerceKey).
        keybind = keybindUtils.coerceKey(properties.keybind or properties.Keybind),
        recording = false,

        value = if (properties.value or properties.Value) ~= nil then (properties.value or properties.Value) else false,
    }, Toggle)

    -- register as a saveable control if flagged (works in a row too)
    self.window:_registerControl(self)

    -- Hidden companion control: Gen2 only serialises what lives in window.controls, so a
    -- flagged toggle gets a second, headless entry under <flag>_Keybind. It carries no UI,
    -- fires no element callbacks, and restores through the same persistence system.
    if self.flag and self.flag ~= "" and not self.forgetState then
        local keybindControl = {
            __type = "ToggleKeybind",
            flag = self.flag .. "_Keybind",
            value = self.keybind,
            toggle = self,
        }

        function keybindControl:Set(key, skipChanged)
            self.toggle:SetKeybind(key, skipChanged)
        end

        function keybindControl:_serialize()
            return { tostring(self.value.EnumType), self.value.Value }
        end

        function keybindControl:_deserialize(raw)
            local enumName = tostring(raw[1]):gsub("^Enum%.", "")
            local enumOk, enumType = pcall(function()
                return Enum[enumName]
            end)
            if not enumOk or not enumType then
                return
            end
            local item = enums.itemFromValue(enumType, raw[2])
            if item then
                self.toggle:SetKeybind(item, true) -- quiet: a load must not fire or autosave
            end
        end

        self.window:_registerControl(keybindControl)
        self._keybindControl = keybindControl
    end

    if self.compact then
        self:_buildCompact()
    else
        self:_buildFull()
    end

    -- full-width descriptions live inside the 60px box, under the title. The 70px right inset
    -- keeps a long description clear of the pill, which sits to the right of both rows. A compact
    -- row has no room for one.
    if not self.compact then
        self.descriptor = inlineDescription.attach(self, 10, 30, 15, 70)
    end

    -- Right-click (both layouts) only enters/exits recording; MouseButton1Click stays the
    -- element's own toggle, so normal left-clicking and drag/scroll behaviour are untouched.
    self.window:ConnectFor(self, self.interact.MouseButton2Click, function()
        hapticEngine.click()
        if self.recording then
            self:_stopRecording()
        else
            self:_startRecording()
        end
    end)

    -- One persistent listener mirrors keybind.luau: capture the next key while recording,
    -- otherwise fire Set on a match. `processed` keeps typing in an Input/core UI from
    -- triggering either path.
    self.window:ConnectFor(self, variables.userInputService.InputBegan, function(input, processed)
        if processed then
            return
        end
        if self.recording then
            local key = keybindUtils.captureKeyboard(input)
            if key == keybindUtils.CAPTURE_CANCEL then
                self:_stopRecording()
            elseif key then
                self:SetKeybind(key)
            end
            return
        end
        -- another element is mid-rebind: that keypress belongs to it, not to us
        if self.window._recordingKeybind then
            return
        end
        if keybindUtils.matchesKey(self.keybind, input) then
            self:Set(not self.value) -- same path as a click, so callbacks and autosave fire
        end
    end)

    -- A dev-supplied binding goes through the same clash checks as a recorded one. Elements
    -- built later lose to whichever earlier toggle/Keybind already owns the key.
    if self.keybind ~= Enum.KeyCode.Unknown and not self:SetKeybind(self.keybind, true) then
        self.keybind = Enum.KeyCode.Unknown
        if self._keybindControl then
            self._keybindControl.value = self.keybind
        end
    end

    return self
end

-- Minimal feedback: the title reads "..." until a key lands (or Escape cancels). Sharing
-- window._recordingKeybind with keybind.luau means the window's menu key and every other
-- keybind/toggle stay quiet during the capture, and Hide() cancels us through the same hook.
-- The popup explains the controls but is deliberately non-modal for input: the global
-- InputBegan listener above keeps capturing keys while it is open, and every way out of
-- recording (bind, Backspace, Escape, another capture, Hide) funnels through _stopRecording,
-- which dismisses the card with it. Its "Got it" button only acknowledges - it doesn't end
-- recording, so the next key still binds.
function Toggle:_startRecording()
    local current = self.window._recordingKeybind
    if current and current ~= self and type(current._stopRecording) == "function" then
        current:_stopRecording()
    end
    self.recording = true
    self.window._recordingKeybind = self
    if self.title then
        self.title.Text = "..."
    end
    self._keybindPopup = self.window:Popup({
        title = "Set Keybind",
        content = "Press any key to bind it to this toggle.\n"
            .. "Backspace clears the keybind.\n"
            .. "Escape cancels.\n"
            .. "Left-click still toggles normally.",
        options = { { text = "Got it" } },
    })
end

function Toggle:_stopRecording()
    if not self.recording then
        return
    end
    self.recording = false
    if self._keybindPopup then
        self._keybindPopup:Close()
        self._keybindPopup = nil
    end
    -- defer like Keybind does: the key that ends recording is still being dispatched and
    -- the window/other elements must keep seeing the flag until that dispatch finishes.
    if self.window._recordingKeybind == self then
        local window = self.window
        task.defer(function()
            if window._recordingKeybind == self then
                window._recordingKeybind = nil
            end
        end)
    end
    if self.title then
        self.title.Text = locale.resolve(self.name)
    end
end

-- Assign a hotkey. Returns true on success, false if the key belongs to the menu toggle
-- or another keybind/toggle (the old binding is kept). nil / an invalid value clears it.
function Toggle:SetKeybind(key, skipChanged)
    local value = keybindUtils.coerceKey(key)
    local interactive = self.recording

    if value ~= Enum.KeyCode.Unknown then
        local conflict = nil
        if value == self.window.settings.toggleKeybind then
            conflict = "the menu toggle key"
        else
            local owner = self.window:_keybindOwner(value, self)
            if owner then
                conflict = "'" .. tostring(owner.name) .. "'"
            end
        end
        if conflict then
            local message = keybindUtils.keyName(value) .. " is bound to " .. conflict .. "; kept "
                .. keybindUtils.keyName(self.keybind)
            log.warn("Rayfield: " .. message)
            if interactive then
                self.window:Notify({
                    title = locale.resolve("Keybind unavailable"),
                    content = message .. ".",
                })
            end
            self:_stopRecording()
            return false
        end
    end

    self.keybind = value
    if self._keybindControl then
        self._keybindControl.value = value
    end
    if self.recording then
        self:_stopRecording()
    end
    if not skipChanged and self._keybindControl then
        self.window:_persist(self._keybindControl) -- flagged toggles autosave their hotkey too
    end
    return true
end

function Toggle:GetKeybind()
    return self.keybind
end

-- the pill switch. same in both layouts; caller places it (pinned right / flex item)
function Toggle:_buildSwitch(parent)
    local window = self.window

    self.functionContainer = window:Create("Frame", {
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(50, 21),

        BackgroundTransparency = 1, -- In = ToggleTrackTransparency

        Parent = parent,
    }, { BackgroundColor3 = "ToggleTrack" })

    window:Create("UICorner", {
        CornerRadius = UDim.new(0, 15),
        Parent = self.functionContainer,
    })

    self.containerStroke = window:Create("UIStroke", {
        Transparency = 1, -- In = 0.85
        Parent = self.functionContainer,
    }, { Color = "SurfaceStroke" })

    self.indicator = window:Create("Frame", {
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(25, 17),
        Position = self.value and UDim2.new(1, -28, 0.5, 0) or UDim2.new(1, -47, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        BackgroundColor3 = self.value and self.window.theme.AccentColor or self.window.theme.ToggleKnobOff,

        BackgroundTransparency = 1, -- In = 0.8

        Parent = self.functionContainer,
    })

    window:Create("UICorner", {
        CornerRadius = UDim.new(1, 0),
        Parent = self.indicator,
    })

    self.indicatorStroke = window:Create("UIStroke", {
        Color = self.value and self.window.theme.AccentStroke or Color3.fromRGB(255, 255, 255),
        Transparency = 1, -- In = 0.7
        Parent = self.indicator,
    })

    -- Accent glow behind the selector; hidden until on (gated by Transparency: 1 hidden, AccentGlow shown)
    self.indicatorGlow = window:CreateGlow(self.indicator, "AccentColor", 20, 1)

    -- Dark wash over the switch for light themes (hidden on dark themes via DarkToggleOverlay).
    self.overlay = window:Create("Frame", {
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromScale(0, 0),
        AnchorPoint = Vector2.new(0, 0),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),

        BackgroundTransparency = 1, -- In = 0

        Parent = self.functionContainer,
    }, { Visible = "DarkToggleOverlay" })

    window:Create("UICorner", {
        CornerRadius = UDim.new(0, 15),
        Parent = self.overlay,
    })

    self.overlayGradient = window:Create("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 30, 30)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 30, 30)),
        }),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0.35),
        }),

        Parent = self.overlay,
    })

    return self.functionContainer
end

-- flip, animate, run callback (error-flash on fail), autosave. press anim is per-layout
function Toggle:_performToggle()
    hapticEngine.click()
    self.value = not self.value
    self:_animateIndicator()
    self.window:_siaUsed(self, if self.value then "on" else "off", self.value)

    self.window:_runGuarded(self, self.callback, self.value)
    self.window:_persist(self)
end

-- full-width: title/icon left, pill pinned right, width-bounce
function Toggle:_buildFull()
    local window = self.window

    self.main = window:Create("Frame", {
        Size = UDim2.new(1, -20, 0, 60),
        BorderSizePixel = 0,
        Name = self.name,
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),

        BackgroundTransparency = 1,

        Parent = self.tab.tabPage,
    }, { BackgroundTransparency = "ElementTransparency" })

    self.stroke = window:StyleElementBody(self.main)
    self.hoverOverlay = window:CreateHoverOverlay(self.main)

    -- title sits near the top of the box so the inline description fits underneath it
    self.container = window:Create("Frame", {
        BorderSizePixel = 0,

        Parent = self.main,
        Size = UDim2.new(0, 170, 0, 16),
        Position = UDim2.new(0, 20, 0, 10),
        AnchorPoint = Vector2.new(0, 0),
        BackgroundTransparency = 1,
    })

    self.containerLayout = window:Create("UIListLayout", {
        Padding = UDim.new(0, 5),
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Left,

        Parent = self.container,
    })

    if self.icon then
        self.iconLabel = window:Create("ImageLabel", {
            Image = self.icon,
            Size = UDim2.fromOffset(16, 16),
            BorderSizePixel = 0,
            BackgroundTransparency = 1,

            ImageTransparency = 1, -- In = 0

            Parent = self.container,
        }, { ImageColor3 = "ContentColor" })
    end

    self.title = window:Create("TextLabel", {
        Text = locale.t(self.name),
        Size = UDim2.fromOffset(250, 16),
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        TextSize = 16,
        AutomaticSize = Enum.AutomaticSize.X,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        LayoutOrder = 1,

        TextTransparency = 1, -- In = 0

        Parent = self.container,
    }, { TextColor3 = "ContentColor", FontFace = "Font" })

    self.interact = window:Create("TextButton", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        BorderSizePixel = 0,
        Position = UDim2.fromScale(1, 0.5),
        AnchorPoint = Vector2.new(1, 0.5),
        TextTransparency = 1,
        ZIndex = 10,

        Parent = self.main,
    })

    -- pill pinned to the right edge, vertically centred in the taller box
    self:_buildSwitch(self.main)
    self.functionContainer.Position = UDim2.new(1, -15, 0, 30)
    self.functionContainer.AnchorPoint = Vector2.new(1, 0.5)

    self.window:_wireElementHover(self)

    self.window:ConnectFor(self, self.interact.MouseButton1Click, function()
        variables.tweenService
            :Create(
                self.stroke,
                TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Transparency = 1 }
            )
            :Play()
        variables.tweenService
            :Create(
                self.main,
                TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
                { Size = UDim2.new(1, -26, 0, 60) }
            )
            :Play()

        self:_performToggle()

        task.wait(0.11)

        variables.tweenService
            :Create(
                self.main,
                TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
                { Size = UDim2.new(1, -20, 0, 60) }
            )
            :Play()
        variables.tweenService
            :Create(
                self.stroke,
                TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Transparency = self.window.theme.ElementStrokeTransparency }
            )
            :Play()
    end)
end

-- compact (row): title left, pill right (SpaceBetween)
function Toggle:_buildCompact()
    local window = self.window

    -- interact sits at ZIndex 10 so the switch pill layers cleanly over the row (see button.luau)
    self.main, self.stroke, self.interact = window:_buildCompactRow(self.tab, self.name, 10)
    self.hoverOverlay = self.interact

    window:Create("UIPadding", {
        PaddingLeft = UDim.new(0, 15),
        PaddingRight = UDim.new(0, 15),

        Parent = self.interact,
    })

    -- title left, pill right
    window:Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalFlex = Enum.UIFlexAlignment.SpaceBetween,
        Padding = UDim.new(0, 10),

        Parent = self.interact,
    })

    self.container = window:Create("Frame", {
        AutomaticSize = Enum.AutomaticSize.X,
        Size = UDim2.fromOffset(0, 16),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        LayoutOrder = 0,

        Parent = self.interact,
    })

    -- text gives up room to the pill when tight
    window:Create("UIFlexItem", {
        FlexMode = Enum.UIFlexMode.Shrink,
        Parent = self.container,
    })

    window:Create("UIListLayout", {
        Padding = UDim.new(0, 5),
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Left,

        Parent = self.container,
    })

    if self.icon then
        self.iconLabel = window:Create("ImageLabel", {
            Image = self.icon,
            Size = UDim2.fromOffset(16, 16),
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            LayoutOrder = 0,

            ImageTransparency = 1, -- In = 0

            Parent = self.container,
        }, { ImageColor3 = "ContentColor" })
    end

    self.title = window:Create("TextLabel", {
        Text = locale.t(self.name),
        Size = UDim2.fromOffset(0, 16),
        AutomaticSize = Enum.AutomaticSize.X,
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        TextSize = 16,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        LayoutOrder = 1,

        TextTransparency = 1, -- In = 0

        Parent = self.container,
    }, { TextColor3 = "ContentColor", FontFace = "Font" })

    -- grows to its text, shrinks + ellipsizes when tight
    window:Create("UIFlexItem", {
        FlexMode = Enum.UIFlexMode.Shrink,
        Parent = self.title,
    })

    -- pill as the right-hand flex item
    self:_buildSwitch(self.interact)
    self.functionContainer.LayoutOrder = 1

    self.window:_wireElementHover(self)

    self.window:ConnectFor(self, self.interact.MouseButton1Click, function()
        variables.tweenService
            :Create(
                self.stroke,
                TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Transparency = 1 }
            )
            :Play()

        self:_performToggle()

        task.wait(0.11)

        variables.tweenService
            :Create(
                self.stroke,
                TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Transparency = self.window.theme.ElementStrokeTransparency }
            )
            :Play()
    end)
end

function Toggle:_animateIndicator()
    local info = TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
    if self.indicatorGlow then
        variables.tweenService
            :Create(self.indicatorGlow, info, { Transparency = self.value and self.window.theme.AccentGlow or 1 })
            :Play()
    end
    if self.value then
        variables.tweenService
            :Create(self.indicator, info, {
                Position = UDim2.new(1, -28, 0.5, 0),
                BackgroundColor3 = self.window.theme.AccentColor,
                BackgroundTransparency = 0,
            })
            :Play()
        variables.tweenService
            :Create(self.indicatorStroke, info, { Color = self.window.theme.AccentStroke, Transparency = 0 })
            :Play()
    else
        variables.tweenService
            :Create(self.indicator, info, {
                Position = UDim2.new(1, -47, 0.5, 0),
                BackgroundColor3 = self.window.theme.ToggleKnobOff,
                BackgroundTransparency = self.window.theme.ToggleKnobOffTransparency,
            })
            :Play()
        variables.tweenService
            :Create(self.indicatorStroke, info, { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.7 })
            :Play()
    end
end

local toggleReveal = TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
-- glow delayed so it doesn't bleed through the fill fade-in on window open
local toggleGlowReveal = TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out, 0, false, 0.35)

function Toggle:_setShown(shown, animate)
    local w = self.window
    if shown then
        w:_revealCommon(self, animate)
        -- carry the state colours here too, so revealing on a tab switch also picks up the theme
        w:_reveal(self.indicator, {
            BackgroundColor3 = self.value and w.theme.AccentColor or w.theme.ToggleKnobOff,
            BackgroundTransparency = self.value and 0 or w.theme.ToggleKnobOffTransparency,
        }, animate, toggleReveal)
        w:_reveal(self.indicatorStroke, {
            Color = self.value and w.theme.AccentStroke or Color3.fromRGB(255, 255, 255),
            Transparency = self.value and 0 or 0.7,
        }, animate, toggleReveal)
        w:_reveal(
            self.indicatorGlow,
            { Transparency = self.value and w.theme.AccentGlow or 1 },
            animate,
            toggleGlowReveal
        )
        w:_reveal(self.overlay, { BackgroundTransparency = 0 }, animate, toggleReveal)
        w:_reveal(self.containerStroke, { Transparency = 0.85 }, animate, toggleReveal)
        w:_reveal(
            self.functionContainer,
            { BackgroundTransparency = w.theme.ToggleTrackTransparency },
            animate,
            toggleReveal
        )
    else
        w:_hideCommon(self, animate)
        w:_reveal(self.indicator, { BackgroundTransparency = 1 }, animate, toggleReveal)
        w:_reveal(self.indicatorStroke, { Transparency = 1 }, animate, toggleReveal)
        w:_reveal(self.indicatorGlow, { Transparency = 1 }, animate, toggleGlowReveal)
        w:_reveal(self.overlay, { BackgroundTransparency = 1 }, animate, toggleReveal)
        w:_reveal(self.containerStroke, { Transparency = 1 }, animate, toggleReveal)
        w:_reveal(self.functionContainer, { BackgroundTransparency = 1 }, animate, toggleReveal)
    end
end

-- Re-apply the visuals that aren't plain themeProperties (the knob's state colour + the reveal
-- transparencies) so a runtime ChangeTheme reaches the switch. Called on the visible tab only.
function Toggle:_refreshTheme()
    local t = self.window.theme
    local info = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local ts = variables.tweenService
    ts:Create(self.functionContainer, info, { BackgroundTransparency = t.ToggleTrackTransparency }):Play()
    ts:Create(self.indicator, info, {
        BackgroundColor3 = self.value and t.AccentColor or t.ToggleKnobOff,
        BackgroundTransparency = self.value and 0 or t.ToggleKnobOffTransparency,
    }):Play()
    ts:Create(self.indicatorStroke, info, {
        Color = self.value and t.AccentStroke or Color3.fromRGB(255, 255, 255),
    }):Play()
    if self.indicatorGlow then
        ts:Create(self.indicatorGlow, info, { Transparency = self.value and t.AccentGlow or 1 }):Play()
    end
end

-- Room the compact toggle needs: side padding + icon (and gap) if shown + title text
-- + the gap to the pill + the pill itself. Lets a horizontal group wrap sensibly.
function Toggle:_minWidth()
    local w = 30 + 10 + 50 -- 15+15 padding, 10 gap to pill, 50 pill
    if self.icon then
        w += 21 -- 16 icon + 5 gap
    end
    -- measure what actually renders: the title shows the translated string
    w += functions.textWidth(self.window.theme.Font, 16, locale.resolve(self.name))
    return w
end

moveable(Toggle)
lockable(Toggle)

function Toggle:Set(value, skipCallback)
    local changed = self.value ~= value
    self.value = value

    if changed then
        self:_animateIndicator()
    end

    -- fire even when unchanged: config load calls Set and relies on the callback to apply
    if not skipCallback then
        self.window:_runGuarded(self, self.callback, self.value)
        self.window:_persist(self) -- skipCallback means apply quietly, so dont autosave either
    end
end

return Toggle
