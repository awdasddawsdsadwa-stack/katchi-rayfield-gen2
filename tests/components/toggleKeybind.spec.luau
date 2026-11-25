local helpers = (_G :: any).__RAYFIELD_TEST_HELPERS

return function()
    local Window = helpers.requireComponent("window")
    local variables = helpers.requireUtility("variables")
    local filesystem = helpers.requireUtility("filesystem")

    local function fireKey(code, processed)
        helpers.services.UserInputService.InputBegan:Fire({
            UserInputType = Enum.UserInputType.Keyboard,
            KeyCode = code,
        }, processed == true)
    end

    describe("toggle keybinds", function()
        local windows

        beforeEach(function()
            windows = {}
        end)

        afterEach(function()
            for _, window in windows do
                if window and not window.unloaded then
                    window:Unload()
                end
            end
        end)

        local function makeWindow(properties)
            local window = Window.new(properties or {
                name = "Hotkey Window",
                showName = "Hotkey",
                configuration = { autoSave = false, autoLoad = false },
            })
            table.insert(windows, window)
            return window
        end

        it("accepts enum, key name, PascalCase, PlayerActions and nil bindings", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })

            local byEnum = tab:CreateToggle({ name = "By Enum", keybind = Enum.KeyCode.Q })
            local byName = tab:CreateToggle({ name = "By Name", Keybind = "Z" })
            local byAction = tab:CreateToggle({ name = "By Action", keybind = Enum.PlayerActions.CharacterJump })
            local unbound = tab:CreateToggle({ name = "Unbound", keybind = nil })

            expect(byEnum:GetKeybind()).to.equal(Enum.KeyCode.Q)
            expect(byName:GetKeybind()).to.equal(Enum.KeyCode.Z)
            expect(byAction:GetKeybind()).to.equal(Enum.PlayerActions.CharacterJump)
            expect(unbound:GetKeybind()).to.equal(Enum.KeyCode.Unknown)

            expect(byEnum:SetKeybind("X")).to.equal(true)
            expect(byEnum:GetKeybind()).to.equal(Enum.KeyCode.X)
            expect(byEnum:SetKeybind(nil)).to.equal(true)
            expect(byEnum:GetKeybind()).to.equal(Enum.KeyCode.Unknown)

            -- a PlayerAction fires on Roblox's default key for it
            local seen = 0
            local actionToggle = tab:CreateToggle({
                name = "Move",
                keybind = Enum.PlayerActions.CharacterForward,
                callback = function()
                    seen += 1
                end,
            })
            fireKey(Enum.KeyCode.W)
            expect(seen).to.equal(1)
            expect(actionToggle.value).to.equal(true)
        end)

        it("records on right-click, cancels on Escape, and leaves left-click alone", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })
            local calls = {}
            local toggle = tab:CreateToggle({
                name = "Escaping",
                callback = function(value)
                    table.insert(calls, value)
                end,
            })

            expect(toggle.title.Text).to.equal("Escaping")
            toggle.interact.MouseButton2Click:Fire()
            expect(toggle.recording).to.equal(true)
            expect(w._recordingKeybind).to.equal(toggle)
            expect(toggle.title.Text).to.equal("...")

            fireKey(Enum.KeyCode.Escape)
            expect(toggle.recording).to.equal(false)
            expect(w._recordingKeybind).to.equal(nil)
            expect(toggle.title.Text).to.equal("Escaping")
            expect(#calls).to.equal(0)

            -- left click still flips the switch and fires the callback
            toggle.interact.MouseButton1Click:Fire()
            expect(toggle.value).to.equal(true)
            expect(calls[#calls]).to.equal(true)

            -- now record a real key: the capture itself must not toggle anything
            toggle.interact.MouseButton2Click:Fire()
            fireKey(Enum.KeyCode.G)
            expect(toggle:GetKeybind()).to.equal(Enum.KeyCode.G)
            expect(toggle.recording).to.equal(false)
            expect(toggle.title.Text).to.equal("Escaping")
            expect(#calls).to.equal(1)

            -- later presses flip it through Set so the callback fires
            fireKey(Enum.KeyCode.G)
            expect(toggle.value).to.equal(false)
            expect(calls[#calls]).to.equal(false)

            -- and input already consumed by the game/core UI is ignored
            fireKey(Enum.KeyCode.G, true)
            expect(toggle.value).to.equal(false)
            expect(#calls).to.equal(2)
        end)

        it("opens a keybind popup that explains the controls without stealing the capture", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })
            local toggle = tab:CreateToggle({ name = "Prompted" })

            toggle.interact.MouseButton2Click:Fire()
            local popup = toggle._keybindPopup
            expect(popup).to.be.ok()
            expect(popup.title).to.equal("Set Keybind")
            expect(string.find(popup.content, "Backspace", 1, true)).to.be.ok()
            expect(popup._closed).to.equal(false)
            expect(toggle.recording).to.equal(true)

            -- the dismiss button only acknowledges: the next key still binds
            local interact
            for _, instance in popup.screenGui:GetDescendants() do
                if instance.ClassName == "TextButton" then
                    interact = instance
                end
            end
            expect(interact).to.be.ok()
            interact.MouseButton1Click:Fire()
            expect(popup._closed).to.equal(true)
            expect(toggle.recording).to.equal(true)

            fireKey(Enum.KeyCode.P)
            expect(toggle:GetKeybind()).to.equal(Enum.KeyCode.P)
            expect(toggle.recording).to.equal(false)

            -- Escape cancels the capture and takes the card with it
            toggle.interact.MouseButton2Click:Fire()
            local second = toggle._keybindPopup
            expect(second._closed).to.equal(false)
            fireKey(Enum.KeyCode.Escape)
            expect(second._closed).to.equal(true)
            expect(toggle.recording).to.equal(false)
        end)

        it("clears a binding with Backspace and works in a compact row", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })
            local row = tab:CreateGroup({ direction = "row" })
            local toggle = row:CreateToggle({ name = "Compact" })

            expect(toggle.compact).to.equal(true)
            toggle.interact.MouseButton2Click:Fire()
            expect(toggle.recording).to.equal(true)
            fireKey(Enum.KeyCode.C)
            expect(toggle:GetKeybind()).to.equal(Enum.KeyCode.C)
            fireKey(Enum.KeyCode.C)
            expect(toggle.value).to.equal(true)

            toggle.interact.MouseButton2Click:Fire()
            fireKey(Enum.KeyCode.Backspace)
            expect(toggle:GetKeybind()).to.equal(Enum.KeyCode.Unknown)
            expect(toggle.recording).to.equal(false)
        end)

        it("keeps distinct bindings and refuses menu and duplicate keys", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })
            local first = tab:CreateToggle({ name = "First", keybind = Enum.KeyCode.One })
            local second = tab:CreateToggle({ name = "Second", keybind = Enum.KeyCode.Two })

            -- a key already owned by another toggle is refused, old binding kept
            second.interact.MouseButton2Click:Fire()
            fireKey(Enum.KeyCode.One)
            expect(second:GetKeybind()).to.equal(Enum.KeyCode.Two)
            expect(second.recording).to.equal(false)
            expect(first:GetKeybind()).to.equal(Enum.KeyCode.One)

            -- the window's menu key is off limits too
            second.interact.MouseButton2Click:Fire()
            fireKey(w.settings.toggleKeybind)
            expect(second:GetKeybind()).to.equal(Enum.KeyCode.Two)

            -- a Keybind element owns its key just as firmly
            local owned = tab:CreateKeybind({ name = "Owned", value = Enum.KeyCode.Three })
            expect(first:SetKeybind(Enum.KeyCode.Three)).to.equal(false)
            expect(first:GetKeybind()).to.equal(Enum.KeyCode.One)

            -- the menu-toggle element sees toggle hotkeys as taken as well
            local menu = tab:CreateKeybind({ name = "Menu", value = w.settings.toggleKeybind, isMenuToggle = true })
            menu:Set(Enum.KeyCode.One)
            expect(menu.value).to.equal(w.settings.toggleKeybind)
            expect(owned.value).to.equal(Enum.KeyCode.Three)

            -- both original bindings still work independently
            local hits = 0
            first.callback = function()
                hits += 1
            end
            fireKey(Enum.KeyCode.One)
            fireKey(Enum.KeyCode.Two)
            expect(hits).to.equal(1)
            expect(first.value).to.equal(true)
            expect(second.value).to.equal(true)
        end)

        it("unregisters the hidden keybind flag with its toggle", function()
            local w = makeWindow()
            local tab = w:CreateTab({ name = "Main" })
            local toggle = tab:CreateToggle({ name = "Doomed", flag = "doomed", keybind = Enum.KeyCode.U })

            expect(w.controls.doomed).to.equal(toggle)
            expect(w.controls.doomed_Keybind).to.be.ok()
            tab:Remove()
            expect(w.controls.doomed).to.equal(nil)
            expect(w.controls.doomed_Keybind).to.equal(nil)
        end)

        it("shares the recording slot with Keybind elements and cancels on Hide", function()
            local w = makeWindow()
            w:Show()
            local tab = w:CreateTab({ name = "Main" })
            local toggle = tab:CreateToggle({ name = "Shared", keybind = Enum.KeyCode.B })
            local keybind = tab:CreateKeybind({ name = "Hotkey", value = Enum.KeyCode.H })

            toggle.interact.MouseButton2Click:Fire()
            expect(w._recordingKeybind).to.equal(toggle)

            -- starting a different capture cancels ours
            keybind.box.MouseButton1Click:Fire()
            expect(toggle.recording).to.equal(false)
            expect(keybind.recording).to.equal(true)
            expect(w._recordingKeybind).to.equal(keybind)

            -- the toggle's hotkey stays quiet while the other element captures
            fireKey(Enum.KeyCode.B)
            expect(toggle.value).to.equal(false)

            -- and hiding cancels whichever element is recording
            w:Hide()
            expect(keybind.recording).to.equal(false)
            expect(w._recordingKeybind).to.equal(nil)
            expect(toggle.title.Text).to.equal("Shared")
        end)

        describe("config persistence", function()
            local originals
            local files

            local function newWindow(fileName, autoSave, autoLoad)
                local w = makeWindow({
                    name = "Saved Keys",
                    showName = "Saved Keys",
                    configuration = {
                        autoSave = autoSave,
                        autoLoad = autoLoad,
                        fileName = fileName,
                    },
                })
                return w
            end

            local function saved(w)
                local _, fullPath = w:GetPath()
                return variables.httpService:JSONDecode(files[fullPath])
            end

            beforeEach(function()
                files = {}
                originals = {
                    fileSystemManager = variables.fileSystemManager,
                    ensureDir = filesystem.ensureDir,
                    writefile = filesystem.writefile,
                    readfile = filesystem.readfile,
                    isfile = filesystem.isfile,
                    delfile = filesystem.delfile,
                }
                variables.fileSystemManager = {
                    getPath = function(_, childPath)
                        return "Root/" .. childPath
                    end,
                }
                filesystem.ensureDir = function() end
                filesystem.writefile = function(path, content)
                    files[path] = content
                end
                filesystem.readfile = function(path)
                    return files[path]
                end
                filesystem.isfile = function(path)
                    return files[path] ~= nil
                end
                filesystem.delfile = function(path)
                    files[path] = nil
                end
            end)

            afterEach(function()
                variables.fileSystemManager = originals.fileSystemManager
                filesystem.ensureDir = originals.ensureDir
                filesystem.writefile = originals.writefile
                filesystem.readfile = originals.readfile
                filesystem.isfile = originals.isfile
                filesystem.delfile = originals.delfile
            end)

            it("round trips a recorded key through manual Save and Load", function()
                local w1 = newWindow("ManualKeys", false, false)
                local t1 = w1:CreateTab({ name = "Main" })
                local toggle = t1:CreateToggle({ name = "Farm", flag = "farm", value = false })

                toggle.interact.MouseButton2Click:Fire()
                fireKey(Enum.KeyCode.P)
                expect(toggle:GetKeybind()).to.equal(Enum.KeyCode.P)
                expect(w1:Save()).to.equal(true)

                local cfg = saved(w1)
                expect(cfg.farm).to.equal(false) -- existing flag saving is untouched
                expect(cfg.farm_Keybind).to.be.ok()
                expect(cfg.farm_Keybind[1]).to.equal("Enum.KeyCode")
                expect(cfg.farm_Keybind[2]).to.equal(Enum.KeyCode.P.Value)

                local w2 = newWindow("ManualKeys", false, false)
                local t2 = w2:CreateTab({ name = "Main" })
                local restored = false
                local rebuilt = t2:CreateToggle({
                    name = "Farm",
                    flag = "farm",
                    value = false,
                    callback = function(value)
                        restored = value
                    end,
                })
                expect(w2:Load()).to.equal(true)
                expect(rebuilt:GetKeybind()).to.equal(Enum.KeyCode.P)
                expect(w2:Get("farm_Keybind")).to.equal(Enum.KeyCode.P)
                expect(restored).to.equal(false)

                fireKey(Enum.KeyCode.P)
                expect(rebuilt.value).to.equal(true)
                expect(restored).to.equal(true)
            end)

            it("autosaves and autoLoads a recorded key like any other flag", function()
                local w1 = newWindow("AutoKeys", true, false)
                local t1 = w1:CreateTab({ name = "Main" })
                local first = t1:CreateToggle({ name = "Auto", flag = "auto", value = false })

                first:SetKeybind("J")
                expect(next(files)).to.be.ok() -- the keybind assignment autosaved on its own
                first:Set(true)
                expect(saved(w1).auto).to.equal(true)

                local w2 = newWindow("AutoKeys", true, true)
                local t2 = w2:CreateTab({ name = "Main" })
                local second = t2:CreateToggle({ name = "Auto", flag = "auto", value = false })
                w2:Show()

                expect(second:GetKeybind()).to.equal(Enum.KeyCode.J)
                expect(second.value).to.equal(true)
            end)

            it("restores a hotkey on a toggle built after autoLoad already ran", function()
                local w = newWindow("LateKeys", false, true)
                local tab = w:CreateTab({ name = "Main" })
                w._loadedConfig = {
                    Late = true,
                    Late_Keybind = { "Enum.KeyCode", Enum.KeyCode.L.Value },
                    -- a malformed saved key must leave the default alone instead of throwing
                    Broken_Keybind = { "Enum.NotARealEnum", 1 },
                }

                local late = tab:CreateToggle({ name = "Late", flag = "Late", value = false })
                expect(late.value).to.equal(true)
                expect(late:GetKeybind()).to.equal(Enum.KeyCode.L)

                local broken = tab:CreateToggle({ name = "Broken", flag = "Broken", keybind = Enum.KeyCode.M })
                expect(broken:GetKeybind()).to.equal(Enum.KeyCode.M)
            end)
        end)
    end)
end
