-- ESX compatibility include: shared_script '@es_extended/locale.lua'
-- (or '@rps_core/locale.lua'). Runs inside the including resource and provides
-- Locales, _ / Translate and _U / TranslateCap. Translations come from the
-- resource's own locale files: either `Locales['en'] = { ... }` scripts or
-- locales/<lang>.lua files that return a table (loaded on first use).
-- A missing translation returns the key itself.

Locales = Locales or {}

local function currentLocale()
    return (type(Config) == 'table' and Config.Locale) or GetConvar('esx:locale', 'en')
end

local function translations(locale)
    if Locales[locale] == nil then
        local file = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.lua'):format(locale))
        local fn = file and load(file, ('@@%s/locales/%s.lua'):format(GetCurrentResourceName(), locale))
        local ok, result = false, nil
        if fn then ok, result = pcall(fn) end
        -- the file either returns its table or fills Locales[locale] itself
        if Locales[locale] == nil then
            Locales[locale] = (ok and type(result) == 'table') and result or false
        end
    end
    return Locales[locale] or (locale ~= 'en' and translations('en')) or nil
end

function Translate(str, ...)
    if str == nil then return '' end
    local list = translations(currentLocale())
    local text = list and list[str]
    if text == nil then return tostring(str) end

    local ok, result = pcall(string.format, text, ...)
    return ok and result or text
end

function TranslateCap(str, ...)
    return (Translate(str, ...):gsub('^%l', string.upper))
end

_ = Translate
_U = TranslateCap
