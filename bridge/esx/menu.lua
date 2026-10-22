-- ESX.UI.Menu and ESX context menus on top of ox_lib, loaded with
-- require 'bridge.esx.menu' by the esx client file.
--
-- 'default' menus become lib.registerMenu menus and 'dialog' menus become
-- lib.inputDialog prompts. ESX keeps several menus open as a stack and shows
-- the newest one; this does the same, so closing a submenu brings its parent
-- back. Script handlers run in their own thread with ESX's (data, menu) args.

local S = require 'bridge.esx.shared'
local clean = S.clean

local RESOURCE = GetCurrentResourceName()
local OX_PREFIX = 'esx_menu:'

local Menu = { RegisteredTypes = {}, Opened = {} }
local state = {}           -- [menu] = { kind, oxId, submit, cancel, change, onClose, selected, running, suspended, custom }
local lastId = 0
local renderQueued = false
local runningDialog        -- dialog menu whose input is on screen

local ALIGN = {
    ['top-left'] = 'top-left', ['top-right'] = 'top-right',
    ['bottom-left'] = 'bottom-left', ['bottom-right'] = 'bottom-right',
    left = 'top-left', right = 'top-right', center = 'top-left', top = 'top-left', bottom = 'bottom-left',
}

-- 'fas fa-car' / 'fa-solid fa-car' -> 'car'
local function faIcon(icon)
    if type(icon) ~= 'string' or icon == '' then return nil end
    return icon:match('fa%-([%w%-]+)%s*$') or icon
end

local function indexOf(menu)
    for i = 1, #Menu.Opened do
        if Menu.Opened[i] == menu then return i end
    end
end

local function find(menuType, namespace, name)
    for i = #Menu.Opened, 1, -1 do
        local m = Menu.Opened[i]
        if m.type == menuType and m.namespace == namespace and m.name == name then return m end
    end
end

local function elements(menu)
    return menu.data.elements or {}
end

local function handlerData(menu, current)
    return { _namespace = menu.namespace, _name = menu.name, current = current, elements = menu.data.elements }
end

local function oursOnScreen()
    local open = lib.getOpenMenu()
    return open and open:sub(1, #OX_PREFIX) == OX_PREFIX
end

---------------------------------------------------------------------------
-- 'default' -> lib.registerMenu
---------------------------------------------------------------------------
local function sliderValues(el)
    if type(el.options) == 'table' then
        local values = {}
        for i, v in ipairs(el.options) do
            values[i] = clean(type(v) == 'table' and (v.label or v.name) or v) or tostring(i)
        end
        return values, (tonumber(el.value) or 0) + 1 -- ESX option sliders use a 0-based value
    end

    local min, max = math.floor(tonumber(el.min) or 0), math.floor(tonumber(el.max) or 100)
    if max - min > 500 then max = min + 500 end -- ox_lib renders every value
    local values = {}
    for v = min, max do values[#values + 1] = tostring(v) end
    return values, math.floor(tonumber(el.value) or min) - min + 1
end

local function setSlider(el, scrollIndex)
    if type(el.options) == 'table' then
        el.value = scrollIndex - 1
    else
        el.value = math.floor(tonumber(el.min) or 0) + scrollIndex - 1
    end
end

local function buildOptions(menu)
    local options = {}
    for i, el in ipairs(elements(menu)) do
        local option = {
            label = clean(el.label) or clean(el.title) or ('#%d'):format(i),
            description = clean(el.description),
            icon = faIcon(el.icon),
            close = false,
            args = { index = i },
        }
        if el.type == 'slider' then
            local values, index = sliderValues(el)
            if #values > 0 then
                option.values = values
                option.defaultIndex = math.max(1, math.min(index, #values))
            end
        end
        options[i] = option
    end
    if #options == 0 then options[1] = { label = ' ', close = false } end
    return options
end

local closeMenu, scheduleRender

local function registerDefault(menu)
    local st = state[menu]

    local function fireChange(el)
        local change = st.change
        if el and change then
            CreateThread(function() change(handlerData(menu, el), menu) end)
        end
    end

    lib.registerMenu({
        id = st.oxId,
        title = clean(menu.data.title) or tostring(menu.name),
        position = ALIGN[menu.data.align] or 'top-left',
        options = buildOptions(menu),
        onSelected = function(selected)
            st.selected = selected
            fireChange(elements(menu)[selected])
        end,
        onSideScroll = function(selected, scrollIndex)
            local el = elements(menu)[selected]
            if not el then return end
            setSlider(el, scrollIndex)
            fireChange(el)
        end,
        onClose = function()
            if not indexOf(menu) then return end
            CreateThread(function()
                if st.cancel then
                    st.cancel(handlerData(menu, elements(menu)[st.selected or 1]), menu)
                else
                    closeMenu(menu)
                end
                scheduleRender() -- still open after cancel: ESX keeps it on screen
            end)
        end,
    }, function(selected, scrollIndex)
        local el = elements(menu)[selected]
        if not el then return end
        st.selected = selected
        if scrollIndex then setSlider(el, scrollIndex) end
        local submit = st.submit
        if submit then
            CreateThread(function() submit(handlerData(menu, el), menu) end)
        end
    end)
end

---------------------------------------------------------------------------
-- 'dialog' -> lib.inputDialog
---------------------------------------------------------------------------
local function runDialog(menu)
    local st = state[menu]
    st.running = true
    runningDialog = menu

    CreateThread(function()
        local title = clean(menu.data.title) or tostring(menu.name)
        local input = lib.inputDialog(title, {
            {
                type = menu.data.type == 'big' and 'textarea' or 'input',
                label = title,
                default = menu.data.value ~= nil and tostring(menu.data.value) or nil,
            },
        })

        st.running = false
        if runningDialog == menu then runningDialog = nil end

        -- hidden because another menu opened on top: show it again later
        if st.suspended then
            st.suspended = nil
            return scheduleRender()
        end
        if not indexOf(menu) then return scheduleRender() end

        local data = { _namespace = menu.namespace, _name = menu.name, value = input and input[1] or nil }

        if input then
            if st.submit then st.submit(data, menu) end
        else
            if st.cancel then st.cancel(data, menu) end
            -- never leave a cancelled dialog stuck on screen
            if indexOf(menu) then closeMenu(menu) end
        end

        -- not closed by the script (e.g. invalid amount): ESX keeps the dialog open
        scheduleRender()
    end)
end

---------------------------------------------------------------------------
-- Stack rendering: show the newest open menu
---------------------------------------------------------------------------
local function render()
    renderQueued = false
    local top = Menu.Opened[#Menu.Opened]
    local st = top and state[top]

    if runningDialog and runningDialog ~= top then
        state[runningDialog].suspended = true
        lib.closeInputDialog()
    end

    if not st or st.custom then
        if oursOnScreen() then lib.hideMenu(false) end
        return
    end

    if st.kind == 'default' then
        if lib.getOpenMenu() ~= st.oxId then
            registerDefault(top)
            lib.showMenu(st.oxId, st.selected)
        end
    elseif st.kind == 'dialog' then
        if oursOnScreen() then lib.hideMenu(false) end
        if not st.running then runDialog(top) end
    end
end

function scheduleRender()
    if renderQueued then return end
    renderQueued = true
    SetTimeout(0, render)
end

local function removeMenu(menu, runClose)
    local i = indexOf(menu)
    if not i then return end
    table.remove(Menu.Opened, i)

    local st = state[menu]
    if st.custom then
        local t = Menu.RegisteredTypes[menu.type]
        if t and t.close then t.close(menu.namespace, menu.name) end
    elseif st.kind == 'default' then
        if lib.getOpenMenu() == st.oxId then lib.hideMenu(false) end
    elseif st.kind == 'dialog' and st.running then
        lib.closeInputDialog()
    end

    if runClose and st.onClose then
        local onClose = st.onClose
        CreateThread(function() onClose() end)
    end

    scheduleRender()
    return st
end

function closeMenu(menu)
    removeMenu(menu, true)
end

---------------------------------------------------------------------------
-- ESX.UI.Menu API
---------------------------------------------------------------------------
function Menu.RegisterType(menuType, open, close)
    Menu.RegisteredTypes[menuType] = { open = open, close = close }
end

function Menu.Open(menuType, namespace, name, data, submit, cancel, change, close)
    lastId = lastId + 1

    local menu = {
        type = menuType,
        namespace = namespace,
        name = name,
        data = type(data) == 'table' and data or {},
        resourceName = GetInvokingResource() or RESOURCE,
    }

    local st = {
        oxId = OX_PREFIX .. lastId,
        submit = submit,
        cancel = cancel,
        change = change,
        onClose = close,
    }

    if Menu.RegisteredTypes[menuType] then
        st.custom = true
    elseif menuType == 'default' or menuType == 'dialog' then
        st.kind = menuType
    else
        print(('[rps_core] ESX menu type "%s" is not supported (only default and dialog)'):format(tostring(menuType)))
    end

    function menu.close()
        closeMenu(menu)
    end

    function menu.update(query, newData)
        for _, el in ipairs(elements(menu)) do
            local match = true
            for k, v in pairs(query) do
                if el[k] ~= v then match = false end
            end
            if match then
                for k, v in pairs(newData) do el[k] = v end
            end
        end
    end

    function menu.refresh()
        if not indexOf(menu) then return end
        if st.custom then
            Menu.RegisteredTypes[menuType].open(namespace, name, menu.data)
        elseif st.kind == 'default' then
            registerDefault(menu)
            if lib.getOpenMenu() == st.oxId then lib.showMenu(st.oxId, st.selected) end
        end
    end

    function menu.setElement(i, key, value)
        local el = elements(menu)[i]
        if el then el[key] = value end
    end

    function menu.setElements(newElements)
        menu.data.elements = newElements
    end

    function menu.setTitle(title)
        menu.data.title = title
    end

    function menu.removeElement(query)
        local list = elements(menu)
        for i = #list, 1, -1 do
            for k, v in pairs(query) do
                if list[i][k] == v then
                    table.remove(list, i)
                    break
                end
            end
        end
    end

    if not st.custom and not st.kind then return menu end

    -- ESX replaces a menu reopened with the same namespace and name
    local existing = find(menuType, namespace, name)
    if existing then removeMenu(existing, false) end

    state[menu] = st
    Menu.Opened[#Menu.Opened + 1] = menu

    if st.custom then
        Menu.RegisteredTypes[menuType].open(namespace, name, menu.data)
    else
        scheduleRender()
    end

    return menu
end

function Menu.Close(menuType, namespace, name, cancel)
    local menu = find(menuType, namespace, name)
    if not menu then return end
    local st = removeMenu(menu, not cancel)
    if cancel and st and st.cancel then
        local handler = st.cancel
        CreateThread(function() handler(handlerData(menu), menu) end)
    end
end

function Menu.CloseAll(cancel)
    for i = #Menu.Opened, 1, -1 do
        local menu = Menu.Opened[i]
        if menu then Menu.Close(menu.type, menu.namespace, menu.name, cancel) end
    end
end

function Menu.GetOpened(menuType, namespace, name)
    return find(menuType, namespace, name)
end

Menu.IsOpen = Menu.GetOpened

function Menu.GetOpenedMenus()
    return Menu.Opened
end

AddEventHandler('onResourceStop', function(resource)
    for i = #Menu.Opened, 1, -1 do
        local menu = Menu.Opened[i]
        if menu and (menu.resourceName == resource or menu.namespace == resource) then
            removeMenu(menu, false)
        end
    end
end)

---------------------------------------------------------------------------
-- ESX.OpenContext (esx_context) -> lib.registerContext
---------------------------------------------------------------------------
local Context = {}
local lastContext = 0
local contextArgs

function Context.Open(position, list, onSelect, onClose, canClose)
    if type(list) ~= 'table' then return end
    lastContext = lastContext + 1
    contextArgs = { position = position, onSelect = onSelect, onClose = onClose, canClose = canClose }

    local id = ('esx_context:%d'):format(lastContext)
    local ctx = { position = position, eles = list }
    local title, options = 'Menu', {}

    for i, el in ipairs(list) do
        if i == 1 and el.unselectable and not el.input then
            title = clean(el.title) or title
        else
            local selectable = not el.unselectable and not el.input
            options[#options + 1] = {
                title = clean(el.title) or ' ',
                description = clean(el.description),
                icon = faIcon(el.icon),
                disabled = el.disabled,
                readOnly = not selectable,
                onSelect = selectable and onSelect and function()
                    CreateThread(function() onSelect(ctx, el) end)
                end or nil,
            }
        end
    end

    lib.registerContext({
        id = id,
        title = title,
        canClose = canClose ~= false,
        onExit = onClose and function()
            CreateThread(function() onClose(ctx) end)
        end or nil,
        options = options,
    })
    lib.showContext(id)
end

function Context.Preview(position, list)
    Context.Open(position, list)
end

function Context.Close()
    lib.hideContext(false)
end

function Context.Refresh(list)
    local args = contextArgs
    if not args then return end
    Context.Open(args.position, list, args.onSelect, args.onClose, args.canClose)
end

return { Menu = Menu, Context = Context }
