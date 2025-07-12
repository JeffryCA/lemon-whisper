local selectedLanguage = "auto"
local selectedScript = "base.py"
local languages = {
    {title = "Auto Detect", lang = "auto"},
    {title = "English", lang = "en"},
    {title = "Spanish", lang = "es"},
    {title = "German", lang = "de"},
    -- add more whisper supported languages as needed 
}
local scripts = {
    {title = "Base Transcription", script = "base.py"},
    {title = "Live Transcription", script = "live.py"}
}

local transcriptionMenu

local function updateMenu()
    local menuData = {}
    
    -- Script selection section
    for _, s in ipairs(scripts) do
        local script = s  -- Create a local copy for the closure
        table.insert(menuData, {
            title = script.title,
            checked = (script.script == selectedScript),
            fn = function()
                selectedScript = script.script
                updateMenu()
            end,
        })
    end
    
    -- Add separator
    table.insert(menuData, {title = "-"})
    
    -- Language selection section
    for _, l in ipairs(languages) do
        local lang = l  -- Create a local copy for the closure
        table.insert(menuData, {
            title = lang.title,
            checked = (lang.lang == selectedLanguage),
            fn = function()
                selectedLanguage = lang.lang
                updateMenu()
            end,
        })
    end
    
    transcriptionMenu:setMenu(menuData)
end

transcriptionMenu = hs.menubar.new()
transcriptionMenu:setTitle("🍋")
updateMenu()

hs.hotkey.bind({"ctrl"}, "Y", function()
    transcriptionMenu:setTitle("📝")
    local command = string.format(
        "/full/path/to/lemon-whisper/.venv/bin/python /full/path/to/lemon-whisper/%s --lang=%s",
        selectedScript,
        selectedLanguage
    )
    local transcriptionTask = hs.task.new(
        "/bin/zsh",
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                hs.alert.show("Error")
            end
            transcriptionMenu:setTitle("🍋")
        end,
        {"-c", command}
    )
    transcriptionTask:start()
end)