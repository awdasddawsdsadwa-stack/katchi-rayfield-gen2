--!nonstrict

-- Copyright (c) 2026 Corridon Capital
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

-- Renders an element's description inside the element's own box, directly under its title,
-- instead of as the separate line that components.descriptor builds.
--
-- The return value is a deliberately minimal stand-in for a Descriptor: Window's reveal/hide
-- and lock paths only ever read element.descriptor.titleLabel, so that is all we need to expose.

local locale = require(script.Parent.locale)

local inlineDescription = {}

-- titleY is accepted for symmetry with the component call sites (which position their own
-- title containers); it doubles as the fallback when no explicit descY is supplied.
function inlineDescription.attach(element, titleY, descY, descHeight)
    if not element.description then
        return nil
    end

    local y = descY or (titleY or 0) + 18

    local label = element.window:Create("TextLabel", {
        Name = "InlineDescription",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        RichText = true,
        Text = locale.t(element.description),
        TextSize = 10,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,

        -- Animation start state; Window:_revealCommon drives unlocked descriptions to 0.7.
        TextTransparency = 0.45,

        Size = UDim2.new(1, -40, 0, descHeight or 15),
        Position = UDim2.new(0, 20, 0, y),
        Parent = element.main,
    }, { TextColor3 = "ContentColor", FontFace = "Font" })

    return { titleLabel = label }
end

return inlineDescription
