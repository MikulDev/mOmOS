-- Application Menu
local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local wibox = require("wibox")
local dpi = require("beautiful.xresources").apply_dpi
local naughty = require("naughty")

local config_dir = gears.filesystem.get_configuration_dir()
local icon_dir = config_dir .. "theme-icons/"

local theme = dofile(config_dir .. "theme.lua")
local util = require("util")

-- {{{ Error handling
-- Handle runtime errors after startup
do
    local in_error = false
    awesome.connect_signal("debug::error", function (err)
        -- Make sure we don't go into an endless error loop
        if in_error then return end
        in_error = true

        naughty.notify({ preset = naughty.config.presets.critical,
                         title = "Error in appmenu:",
                         text = tostring(err) })
        in_error = false
    end)
end
-- }}}

-- Initialize the menu table that will hold all our functions and state
appmenu_data = {
    wibox = nil,
    widget = nil,
    search_textbox = nil,
    visible_entries = 10,
    current_start = 1,
    desktop_entries = {},
    filtered_list = {},
    pinned_apps = {}, -- Store pinned applications
    max_pinned = 8,   -- Maximum number of pinned apps
    font = theme.font .. " " .. dpi(13),
	current_focus = {
        type = "search", -- can be "search", "pinned", "apps", or "pin_button"
        index = nil,     -- index in the current list (for pinned or apps)
        pin_focused = false -- whether pin button is focused for current app
    },
	icons = {
        search = icon_dir .. "search.png",  -- Your search icon file
        pin = icon_dir .. "pin.png",        -- Your pin icon file
        pinned = icon_dir .. "pinned.png"   -- Your pinned icon file
    }
}

-- Function to get theme color or fallback
function get_color(beautiful_color, fallback_color)
    if beautiful_color then
        return beautiful_color
    else
        return fallback_color
    end
end

function get_icon_path(desktop_file_content)
    local icon_name = desktop_file_content:match("Icon=([^\n]+)")
    if not icon_name then return nil end
    
    -- First check if icon_name is a direct path
    if icon_name:match("^/") then  -- Starts with '/'
        local f = io.open(icon_name)
        if f then
            f:close()
            return icon_name
        end
    end
    
	-- Most icons are in subdirectories of this path
	local icon_dir = "/usr/share/icons/"
    -- Iterate through common icon directories (preferred HD icons are checked first)
    local icon_paths = {
		icon_dir .. "hicolor/scalable/apps/",
		icon_dir .. "hicolor/256x256/apps/",
		icon_dir .. "hicolor/64/apps/",
		icon_dir .. "hicolor/64x64/apps/",
		icon_dir .. "hicolor/48/apps/",
		icon_dir .. "hicolor/48x48/apps/",
		icon_dir .. "hicolor/16x16/apps/",
		icon_dir,
        "/usr/share/pixmaps/",
        os.getenv("HOME") .. "/.local/share/icons/hicolor/48x48/apps/",
        os.getenv("HOME") .. "/.local/share/icons/hicolor/scalable/apps/"
    }
    local extensions = { ".png", ".svg", ".xpm", "" }
    
    for _, path in ipairs(icon_paths) do
        for _, ext in ipairs(extensions) do
            local icon_path = path .. icon_name .. ext
            local f = io.open(icon_path)
            if f then
                f:close()
                return icon_path
            end
        end
    end
    
    return nil
end

-- Helper for scan_desktop_files() which handles quotes in the Exec= line
function handle_exec_quotes(str)
    if not str then return nil end
    -- Replace escaped quotes with temporary markers
    str = str:gsub('\\"', '§DQUOTE§')
    str = str:gsub("\\'", '§SQUOTE§')
    -- Remove unescaped quotes
    str = str:gsub('"', '')
    str = str:gsub("'", '')
    -- Restore escaped quotes
    str = str:gsub('§DQUOTE§', '"')
    str = str:gsub('§SQUOTE§', "'")
    return str
end

-- Scans for and parses desktop entries
function scan_desktop_files()
    local paths = {
        "/usr/share/applications/",
        os.getenv("HOME") .. "/.local/share/applications/"
    }
    
    appmenu_data.desktop_entries = {} -- Clear existing entries
    
    for _, path in ipairs(paths) do
        local handle = io.popen('find "' .. path .. '" -name "*.desktop"')
        if handle then
            for file in handle:lines() do
                local f = io.open(file)
                if f then
                    local content = f:read("*all")
                    f:close()
                    
                    -- Parse basic .desktop file info
                    local name = content:match("Name=([^\n]+)")
                    -- Handle quoted exec command
                    local exec = content:match("Exec=([^\n]+)")
                    exec = handle_exec_quotes(exec)
                    local nodisplay = content:match("NoDisplay=([^\n]+)")
                    local hidden = content:match("Hidden=([^\n]+)")
                    
                    -- Only add if it's a valid, non-hidden application
                    if name and exec and not (nodisplay == "true") and not (hidden == "true") then
                        -- Clean up exec command
                        exec = exec:gsub("%%[fFuU]", "")
                        exec = exec:gsub("%%k", file)
                        exec = exec:gsub("%%c", name)
                        exec = exec:gsub("%%[A-Z]", "")
                        
                        -- Get icon path
                        local icon_path = get_icon_path(content)
                        
                        table.insert(appmenu_data.desktop_entries, {
                            name = name,
                            exec = exec,
                            icon = icon_path
                        })
                    end
                end
            end
            handle:close()
        end
    end
    
    -- Sort applications alphabetically
    table.sort(appmenu_data.desktop_entries, function(a, b) 
        return string.lower(a.name) < string.lower(b.name)
    end)
end

-- Save pinned apps to a file
function save_pinned_apps()
    local file = io.open(config_dir .. "persistent/pinned_apps.lua", "w")
    if file then
        file:write("return {")
        for _, app in ipairs(appmenu_data.pinned_apps) do
            file:write(string.format(
                '\n  {name = "%s", exec = "%s", icon = "%s"},',
                app.name, app.exec, app.icon or ""
            ))
        end
        file:write("\n}")
        file:close()
    end
end

-- Load pinned apps from file
function load_pinned_apps()
    local success, apps = pcall(dofile, config_dir .. "persistent/pinned_apps.lua")
    if success and type(apps) == "table" then
        appmenu_data.pinned_apps = apps
    end
end

-- Toggle pin status of an app
function toggle_pin(app)
    if not app then return end
	local is_pinned = false
    local pinned_index = nil
    
	for i, pinned_app in ipairs(appmenu_data.pinned_apps) do
        if pinned_app.name == app.name then
            is_pinned = true
            pinned_index = i
            break
        end
    end
    
    if is_pinned then
        -- Remove from pinned apps
        table.remove(appmenu_data.pinned_apps, pinned_index)
    else
        -- Add to pinned apps if not at maximum
        if #appmenu_data.pinned_apps < appmenu_data.max_pinned then
            table.insert(appmenu_data.pinned_apps, {
                name = app.name,
                exec = app.exec,
                icon = app.icon
            })
        else
            naughty.notify({
                text = "Maximum number of pinned apps reached",
                timeout = 2
            })
            return
        end
    end
    
    save_pinned_apps()
    refresh_menu_widget()
end

-- Create a pinned app icon
function create_pinned_icon(app, index)
    local icon_widget
    if app.icon then
        icon_widget = wibox.widget {
            {
                image = app.icon,
                resize = true,
                forced_width = dpi(32),
                forced_height = dpi(32),
                widget = wibox.widget.imagebox,
            },
            margins = dpi(2),
            widget = wibox.container.margin
        }
    else
        icon_widget = wibox.widget {
            {
                text = "⬡",
                font = beautiful.font .. " 20",
                forced_width = dpi(32),
                forced_height = dpi(32),
                align = 'center',
                valign = 'center',
                widget = wibox.widget.textbox
            },
            margins = dpi(2),
            widget = wibox.container.margin
        }
    end

    local icon_container = create_image_button({
	    image_path = app.icon,
	    fallback_text = "⬡",
	    image_size = dpi(32),
	    padding = dpi(6),
	    bg_color = theme.appmenu.button_bg,
	    border_color = theme.appmenu.button_border .. "33",
	    shape_radius = dpi(8),
	    on_click = function()
	        awful.spawn(app.exec)
	        appmenu_hide()
	        return true
	    end,
	    on_ctrl_click = function()
	        run_with_sudo(app.exec)
	        appmenu_hide()
	        return true
	    end,
	    on_right_click = function()
	        table.remove(appmenu_data.pinned_apps, index)
	        save_pinned_apps()
	        refresh_menu_widget()
	        return true
	    end
	})

    -- Update background based on focus state
    local function update_focus()
	    if appmenu_data.current_focus.type == "pinned" and appmenu_data.current_focus.index == index then
	        icon_container:update_colors(theme.appmenu.button_bg_focus, theme.appmenu.button_border_focus .. "33")
	    else
	        icon_container:update_colors(theme.appmenu.button_bg, theme.appmenu.button_border .. "33")
	    end
	end

    update_focus() -- Initial state

    -- Subscribe to focus changes
    appmenu_data.wibox:connect_signal("property::current_focus", update_focus)

    -- Mouse handlers
    icon_container:connect_signal("mouse::enter", function()
	    appmenu_data.current_focus = {
	        type = "pinned",
	        index = index,
	        pin_focused = false
	    }
	    appmenu_data.wibox:emit_signal("property::current_focus")
	end)

	icon_container:connect_signal("mouse::leave", function()
	    appmenu_data.current_focus = {
	        type = "pinned",
	        index = nil,
	        pin_focused = false
	    }
	    appmenu_data.wibox:emit_signal("property::current_focus")
	end)

    return icon_container
end

-- Create a single application entry widget
function create_entry(app, index)
    -- Create a widget table to hold all components and state
    local widget = {
        is_pinned = false,
        is_focused = false,
        is_pin_focused = false
    }
    
    -- Check if app is pinned
    for _, pinned_app in ipairs(appmenu_data.pinned_apps) do
        if pinned_app.name == app.name then
            widget.is_pinned = true
            break
        end
    end

    -- Create app icon
    local icon_widget
    if app.icon then
        icon_widget = wibox.widget {
            {
                image = app.icon,
                resize = true,
                forced_width = dpi(24),
                forced_height = dpi(24),
                widget = wibox.widget.imagebox
            },
            margins = dpi(6),
            widget = wibox.container.margin
        }
    else
        icon_widget = wibox.widget {
            {
                text = "⬡",
                font = beautiful.font or "Sans 11" .. " 16",
                forced_width = dpi(24),
                forced_height = dpi(24),
                align = 'center',
                valign = 'center',
                widget = wibox.widget.textbox
            },
            margins = dpi(2),
            widget = wibox.container.margin
        }
    end

    -- Create pin button
    widget.pin_button = create_image_button({
	    image_path = widget.is_pinned and appmenu_data.icons.pinned or appmenu_data.icons.pin,
	    image_size = dpi(24),
	    padding = dpi(6),
	    opacity = 0.8,
	    bg_color = theme.appmenu.pin_button_bg,
	    border_color = theme.appmenu.button_border .. "55",
	    button_size = dpi(32),
	    on_click = function()
	        toggle_pin(app)
	        return true
	    end
	})
	widget.pin_button.visible = false  -- Initially hidden until focus

    -- Create main content
    local main_content = wibox.widget {
        {
            icon_widget,
            {
                text = app.name,
                widget = wibox.widget.textbox,
                font = beautiful.font or "Sans 11"
            },
            spacing = dpi(8),
            layout = wibox.layout.fixed.horizontal,
            valign = 'center'
        },
        widget = wibox.container.background,
        valign = 'center'
    }

    -- Create background container
    widget.background = wibox.widget {
        {
            {
                main_content,
                nil,
                {
                    widget.pin_button,
                    right = dpi(2),
                    top = dpi(2),
                    bottom = dpi(2),
                    widget = wibox.container.margin
                },
                layout = wibox.layout.align.horizontal,
                expand = "inside"
            },
            margins = dpi(4),
            widget = wibox.container.margin,
        },
        bg = theme.appmenu.button_bg,
        fg = theme.appmenu.fg,
        shape = function(cr, width, height)
            gears.shape.rounded_rect(cr, width, height, 6)
        end,
        shape_border_width = 1,
        shape_border_color = theme.appmenu.button_border .. "33",
        forced_height = dpi(44),
        widget = wibox.container.background,
    }

    -- Function to update widget state
	function widget:deselect()
		self.pin_button.visible = false
        self.background.bg = theme.appmenu.button_bg
        self.background.fg = theme.appmenu.fg
        self.background.shape_border_color = theme.appmenu.button_border .. "33"
        self.pin_button.bg = theme.appmenu.pin_button_bg
	end
    function widget:update_state()
	    if appmenu_data.current_focus.type == "apps" and appmenu_data.current_focus.index == index then
	        self.pin_button.visible = true
	        
	        if appmenu_data.current_focus.pin_focused then
	            self.background.bg = theme.appmenu.button_bg
	            self.background.fg = theme.appmenu.fg
	            self.pin_button:update_colors(theme.appmenu.button_bg_focus)
	        else
	            self.background.bg = theme.appmenu.button_bg_focus
	            self.background.fg = beautiful.fg_focus
	            self.pin_button:update_colors(theme.appmenu.pin_button_bg)
	        end
	        self.background.shape_border_color = theme.appmenu.button_border_focus .. "33"
	    else
	        widget:deselect()
	    end
	end

    -- Connect signals
    appmenu_data.wibox:connect_signal("property::current_focus", function()
        widget:update_state()
    end)

    widget.background:connect_signal("mouse::enter", function()
        appmenu_data.current_focus = {
            type = "apps",
            index = index,
            pin_focused = false
        }
        appmenu_data.wibox:emit_signal("property::current_focus")
    end)

    widget.background:connect_signal("mouse::leave", function()
		widget:deselect()
    end)

    widget.pin_button:connect_signal("mouse::enter", function()
        appmenu_data.current_focus = {
            type = "apps",
            index = index,
            pin_focused = true
        }
        appmenu_data.wibox:emit_signal("property::current_focus")
    end)

    widget.pin_button:connect_signal("mouse::leave", function()
        appmenu_data.current_focus = {
            type = "apps",
            index = index,
            pin_focused = false
        }
        widget:update_state()
    end)

    -- Add click handlers
    widget.background:buttons(gears.table.join(
	    -- Normal click: Launch app
	    awful.button({}, 1, function()
	        if not appmenu_data.current_focus.pin_focused then
	            awful.spawn(app.exec)
	            appmenu_hide()
	        end
	        return true
	    end),
	    -- CTRL+click: Launch with sudo
	    awful.button({ "Control" }, 1, function()
	        if not appmenu_data.current_focus.pin_focused then
	            run_with_sudo(app.exec)
	            appmenu_hide()
	        end
	        return true
	    end),
	    -- Right click: Nothing (could be used for context menu in future)
	    awful.button({}, 3, function()
	        return true
	    end)
	))

    -- Create final container
    local container = wibox.widget {
        widget.background,
        left = dpi(8),
        right = dpi(8),
        widget = wibox.container.margin
    }

	add_hover_cursor(container)

    -- Initial state
    widget:update_state()

    return container
end

function create_pinned_row()
    local pinned_row = wibox.widget {
        layout = wibox.layout.fixed.horizontal,
        spacing = dpi(8),
    }

    for i, app in ipairs(appmenu_data.pinned_apps) do
        pinned_row:add(create_pinned_icon(app, i))
    end

    -- Create container with bottom border
    return wibox.widget {
        {
            {
                pinned_row,
                margins = dpi(8),
                widget = wibox.container.margin
            },
            bg = theme.appmenu.bg,
            widget = wibox.container.background
        },
        visible = #appmenu_data.pinned_apps > 0,
        layout = wibox.layout.fixed.horizontal
    }
end

-- Create a completely new list widget based on current state
function create_current_view()
    local list_widget = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(6),
    }

    local start_idx = appmenu_data.current_start
    local end_idx = math.min(start_idx + appmenu_data.visible_entries - 1, #appmenu_data.filtered_list)

    for i = start_idx, end_idx do
        local app = appmenu_data.filtered_list[i]
        if app then
            list_widget:add(create_entry(app, i))
        end
    end

    return list_widget
end

function create_search_box()
    local search_content = wibox.widget {
        {
            {
                image = appmenu_data.icons.search,
                resize = true,
                forced_width = dpi(18),
                forced_height = dpi(18),
				 opacity = 0.5,
                widget = wibox.widget.imagebox
            },
            valign = 'center',
            widget = wibox.container.place
        },
        appmenu_data.search_textbox,
        spacing = dpi(8),
        layout = wibox.layout.fixed.horizontal
    }

    local search_container = wibox.widget {
        {
            search_content,
            margins = dpi(12),
            widget = wibox.container.margin
        },
        bg = theme.appmenu.bg,
        shape = function(cr, width, height)
            gears.shape.rounded_rect(cr, width, height, dpi(15))
        end,
        shape_border_width = 1,
        shape_border_color = theme.appmenu.button_border .. "33",
        widget = wibox.container.background
    }

    -- Update focus state
    local function update_focus()
        if appmenu_data.current_focus.type == "search" then
            search_container.bg = theme.appmenu.button_bg_focus
            search_container.shape_border_color = theme.appmenu.button_border_focus .. "33"
        else
            search_container.bg = theme.appmenu.bg
            search_container.shape_border_color = theme.appmenu.button_border .. "33"
        end
    end

    update_focus() -- Initial state

    -- Subscribe to focus changes
    appmenu_data.wibox:connect_signal("property::current_focus", update_focus)

    -- Create a separator widget for the bottom border
    local separator = wibox.widget {
        widget = wibox.widget.separator,
        orientation = "horizontal",
        forced_height = 1,
        color = theme.appmenu.button_border .. "33",
        span_ratio = 0.98
    }

    return wibox.widget {
        -- First section: Pinned apps with bottom border
        {
            {
                {
                    create_pinned_row(),
                    margins = dpi(8),
                    widget = wibox.container.margin
                },
                separator,
                layout = wibox.layout.fixed.vertical,
                spacing = dpi(1)
            },
            bg = theme.appmenu.bg,
            visible = #appmenu_data.pinned_apps > 0,
            widget = wibox.container.background
        },

        -- Second section: Search box
        {
            search_container,
            left = dpi(12),
            right = dpi(12),
            top = dpi(10),
            bottom = dpi(10),
            widget = wibox.container.margin
        },

        -- Third section: Current view
        {
            create_current_view(),
            margins = dpi(4),
            widget = wibox.container.margin
        },

        layout = wibox.layout.fixed.vertical,
        spacing = dpi(4)
    }
end

-- Filters applications based on search term
function filter_apps(search_term)
    local filtered = {}
    search_term = string.lower(search_term or "")
    
    for _, app in ipairs(appmenu_data.desktop_entries) do
        if string.find(string.lower(app.name), search_term, 1, true) then
            table.insert(filtered, app)
        end
    end
    
    return filtered
end

-- Updates the filtered list based on search term
function update_filtered_list(search_term)
    appmenu_data.filtered_list = {}
    search_term = string.lower(search_term or "")
    
    for _, app in ipairs(appmenu_data.desktop_entries) do
        if string.find(string.lower(app.name), search_term, 1, true) then
            table.insert(appmenu_data.filtered_list, app)
        end
    end
end

-- Updates the entire menu widget with new content
function refresh_menu_widget()
	if #appmenu_data.pinned_apps > 0 then
		if appmenu_data.wibox.height < dpi(672) then appmenu_data.wibox.y = appmenu_data.wibox.y - 80 end
		appmenu_data.wibox.height = dpi(672)
	else
		if appmenu_data.wibox.height > dpi(590) then appmenu_data.wibox.y = appmenu_data.wibox.y + 80 end
		appmenu_data.wibox.height = dpi(590)
	end
    if not appmenu_data.wibox then return end
    appmenu_data.wibox.widget = create_search_box()
end

-- Function to scroll the list
function scroll_list(direction)
    if direction > 0 then  -- Scroll down
        if appmenu_data.current_start + appmenu_data.visible_entries <= #appmenu_data.filtered_list then
            appmenu_data.current_start = appmenu_data.current_start + 1
            -- Update focus if it's now out of view
            if appmenu_data.current_focus.type == "apps" and 
               appmenu_data.current_focus.index < appmenu_data.current_start then
                appmenu_data.current_focus.index = appmenu_data.current_start
                appmenu_data.wibox:emit_signal("property::current_focus")
            end
            refresh_menu_widget()
        end
    else  -- Scroll up
        if appmenu_data.current_start > 1 then
            appmenu_data.current_start = appmenu_data.current_start - 1
            -- Update focus if it's now out of view
            if appmenu_data.current_focus.type == "apps" and 
               appmenu_data.current_focus.index >= appmenu_data.current_start + appmenu_data.visible_entries then
                appmenu_data.current_focus.index = appmenu_data.current_start + appmenu_data.visible_entries - 1
                appmenu_data.wibox:emit_signal("property::current_focus")
            end
            refresh_menu_widget()
        end
    end
end

-- Add this function to handle ensuring the focused item is visible
function ensure_focused_visible()
    if appmenu_data.current_focus.type ~= "apps" then return end
    
    local index = appmenu_data.current_focus.index
    if not index then return end
    
    -- If the focused index is before our current view
    if index < appmenu_data.current_start then
        appmenu_data.current_start = index
        refresh_menu_widget()
    -- If the focused index is after our current view
    elseif index >= appmenu_data.current_start + appmenu_data.visible_entries then
        appmenu_data.current_start = index - appmenu_data.visible_entries + 1
        refresh_menu_widget()
    end
end

local function handle_keyboard_navigation(mod, key)
    local focus = appmenu_data.current_focus
    
    -- Ensure focus has an index if it's not in pinned apps or app list
    if not focus.index then
        focus.type = "apps"
        focus.index = 1
    end
    
    if key == "Up" then
        if focus.type == "apps" then
            -- From app list, go to pinned apps if at top
            if focus.index == 1 and #appmenu_data.pinned_apps > 0 then
                focus.type = "pinned"
                focus.index = 1
                focus.pin_focused = false
            else
                -- Move up in app list
                focus.index = math.max(1, focus.index - 1)
                focus.pin_focused = false
                ensure_focused_visible()
            end
        end
        
    elseif key == "Down" then
        if focus.type == "pinned" then
            -- From pinned apps to app list
            focus.type = "apps"
            focus.index = 1
            focus.pin_focused = false
            ensure_focused_visible()
        elseif focus.type == "apps" then
            -- Move down in app list if not at end
            if focus.index < #appmenu_data.filtered_list then
                focus.index = focus.index + 1
                focus.pin_focused = false
                ensure_focused_visible()
            end
        end
        
    elseif key == "Left" then
        if focus.type == "pinned" then
            -- Navigate left in pinned apps
            if focus.index > 1 then
                focus.index = focus.index - 1
            end
        elseif focus.type == "apps" and focus.pin_focused then
            -- From pin button to main entry
            focus.pin_focused = false
        end
        
    elseif key == "Right" then
        if focus.type == "pinned" then
            -- Navigate right in pinned apps
            if focus.index < #appmenu_data.pinned_apps then
                focus.index = focus.index + 1
            end
        elseif focus.type == "apps" and not focus.pin_focused then
            -- From main entry to pin button
            focus.pin_focused = true
        end

    elseif key == "Tab" and focus.type == "pinned" then
        -- Navigate right in pinned apps
        if focus.index < #appmenu_data.pinned_apps then
            focus.index = focus.index + 1
        else 
            focus.index = 1
        end
        
    elseif key == "Return" then
		local is_ctrl = false
        for _, m in ipairs(mod) do
        	if m == "Control" then
            	is_ctrl = true
           	 	break
       		end
        end
        if focus.type == "apps" then
            local app = appmenu_data.filtered_list[focus.index]
			 if focus.pin_focused then
                toggle_pin(app)
            else
                if app then
                    if is_ctrl then
                        run_with_sudo(app.exec)
                    else
                        awful.spawn(app.exec)
                    end
                    appmenu_hide()
                end
            end
        elseif focus.type == "pinned" then
            local pinned = appmenu_data.pinned_apps[focus.index]
            if pinned then
                -- Launch pinned app with or without sudo
                if is_ctrl then
                    run_with_sudo(appmenu_data.pinned_apps[focus.index].exec)
                else
                    awful.spawn(appmenu_data.pinned_apps[focus.index].exec)
                end
                appmenu_hide()
            end
        end
    elseif key == "Home" then
        if focus.type == "apps" then
            -- Go to first app
            focus.index = 1
            focus.pin_focused = false
            ensure_focused_visible()
        elseif focus.type == "pinned" then
            -- Go to first pinned app
            focus.index = 1
        end
    elseif key == "End" then
        if focus.type == "apps" then
            -- Go to last app
            focus.index = #appmenu_data.filtered_list
            focus.pin_focused = false
            ensure_focused_visible()
        elseif focus.type == "pinned" then
            -- Go to last pinned app
            focus.index = #appmenu_data.pinned_apps
        end
    end
    
    -- Emit focus change signal
    appmenu_data.wibox:emit_signal("property::current_focus")
end

function run_with_sudo(command)
    -- Create the zenity password prompt command
    local zenity_cmd = string.format(
        "zenity --password | sudo -S %s",
        command
    )
    
    -- Execute with shell
    awful.spawn.with_shell(zenity_cmd)
end

function preserve_focus_state()
    appmenu_data.last_focus = {
        type = appmenu_data.current_focus.type,
        index = appmenu_data.current_focus.index,
        pin_focused = appmenu_data.current_focus.pin_focused
    }
end

-- Add this function to restore focus state
function restore_focus_state()
    if appmenu_data.last_focus then
        appmenu_data.current_focus = appmenu_data.last_focus
        appmenu_data.wibox:emit_signal("property::current_focus")
        appmenu_data.last_focus = nil
    end
end

function appmenu_create()
    -- Scan for applications if not already done
    if #appmenu_data.desktop_entries == 0 then
        scan_desktop_files()
    end

    -- Create search textbox
    appmenu_data.search_textbox = wibox.widget {
        widget = wibox.widget.textbox,
        id = "search_input",
        text = "",
        valign = 'center',
        font = appmenu_data.font,
        forced_height = dpi(24)
    }

    -- Initialize filtered list
    update_filtered_list("")

    -- Create initial widget
    return create_search_box()
end

function appmenu_init()
    -- Load pinned apps when initializing
    load_pinned_apps()

    appmenu_data.wibox = wibox{
        screen = mouse.screen, -- Use current mouse screen instead of screen[1]
        width = dpi(500),
        height = dpi(672),
        bg = theme.appmenu.bg,
        border_color = theme.appmenu.border,
        border_width = 1,
        visible = false,
        ontop = true,
        type = "normal"
    }

    appmenu_data.wibox.shape = function(cr, width, height)
        gears.shape.rounded_rect(cr, width, height, dpi(16))
    end

    appmenu_data.wibox.widget = appmenu_create()

    appmenu_data.wibox:buttons(gears.table.join(
        awful.button({ }, 1, nil),
        awful.button({ }, 4, function() scroll_list(-1) end),
        awful.button({ }, 5, function() scroll_list(1) end)
    ))

    appmenu_data.keygrabber = awful.keygrabber {
        autostart = false,
        keypressed_callback = function(_, mod, key)
            -- Preserve focus state when Control is pressed
            if key == "Control_L" or key == "Control_R" then
                preserve_focus_state()
                return
            end
            
            if key == "Escape" then
                appmenu_hide()
                return
            end
            
            -- Handle navigation keys
            if key == "Up" or key == "Down" or key == "Left" or 
               key == "Right" or key == "Return" or key == "Home" or 
               key == "End" or key == "Tab" then
                handle_keyboard_navigation(mod, key)
                return
            end
            
            -- Always handle search input
            appmenu_data.current_filter = appmenu_data.current_filter or ""
            
            if key == "BackSpace" then
                if #appmenu_data.current_filter > 0 then
                    appmenu_data.current_filter = string.sub(appmenu_data.current_filter, 1, -2)
                end
            elseif #key == 1 then
                appmenu_data.current_filter = appmenu_data.current_filter .. key
            end
            
            if appmenu_data.search_textbox then
                appmenu_data.search_textbox.text = appmenu_data.current_filter
                appmenu_data.current_start = 1
                update_filtered_list(appmenu_data.current_filter)
                
                -- Reset focus to first item in filtered list
                appmenu_data.current_focus = {
                    type = "apps",
                    index = 1,
                    pin_focused = false
                }
                ensure_focused_visible()
                refresh_menu_widget()
            end
        end,
        keyreleased_callback = function(_, mod, key)
            -- Restore focus state when Control is released
            if key == "Control_L" or key == "Control_R" then
                restore_focus_state()
            end
        end,
        stop_callback = function()
            appmenu_data.wibox.visible = false
        end
    }

    return appmenu_data.wibox
end

function appmenu_show()
    if appmenu_data.wibox then
		scan_desktop_files()
        -- Update to current screen
        appmenu_data.wibox.screen = mouse.screen

		-- Force focus to our menu wibox to release game input capture
        if client.focus then
            client.focus = nil
        end
        
        -- Rest of your existing show code...
        appmenu_data.current_filter = ""
        appmenu_data.current_start = 1
        appmenu_data.current_focus = {
            type = "pinned",
            index = 1,
            pin_focused = false
        }
        if appmenu_data.search_textbox then
            appmenu_data.search_textbox.text = ""
        end
        update_filtered_list("")
        refresh_menu_widget()
        appmenu_data.wibox:emit_signal("property::current_focus")
        appmenu_data.wibox.visible = true
        awful.placement.centered(appmenu_data.wibox)
        if appmenu_data.keygrabber then
            appmenu_data.keygrabber:start()
        end
    end
end

function appmenu_hide()
    if appmenu_data.wibox then
        appmenu_data.wibox.visible = false
        if appmenu_data.keygrabber then
            appmenu_data.keygrabber:stop()
        end
        appmenu_data.current_focus = {
            type = "search",
            index = nil,
            pin_focused = false
        }
        appmenu_data.wibox:emit_signal("property::current_focus")
        
        -- Focus the client under the mouse cursor
        local c = awful.mouse.client_under_pointer()
        if c then
            client.focus = c
            c:raise()
        end
    end
end

function appmenu_toggle()
    if appmenu_data.wibox and appmenu_data.wibox.visible then
        appmenu_hide()
    else
        appmenu_show()
    end
end

return menu