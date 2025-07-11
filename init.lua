local selectedLanguage = "auto"
local languages = {
    {title = "Auto Detect", lang = "auto"},
    {title = "English", lang = "en"},
    {title = "Spanish", lang = "es"},
    {title = "German", lang = "de"},
    -- add more whisper supported languages as needed 
}

local function setLanguage(lang)
    selectedLanguage = lang.lang
    local menuData = {}
    for _, l in ipairs(languages) do
        table.insert(menuData, {
            title = l.title,
            checked = (l.lang == selectedLanguage),
            fn = function()
                setLanguage(l)
            end,
        })
    end
    transcriptionMenu:setMenu(menuData)
end

transcriptionMenu = hs.menubar.new()
transcriptionMenu:setTitle("🍋")
setLanguage({lang = selectedLanguage})

hs.hotkey.bind({"ctrl"}, "Y", function()
    transcriptionMenu:setTitle("📝")
    local command = string.format(
        "/full/path/to/lemon-whisper/.venv/bin/python /full/path/to/lemon-whisper/local-transcription.py --lang=%s",
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