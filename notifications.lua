local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local naughty = require("naughty")
local wibox = require("wibox")
local dpi = require("beautiful.xresources").apply_dpi
local config = require("config")
local util = require("util")

local config_dir = gears.filesystem.get_configuration_dir()
local theme = dofile(config_dir .. "theme.lua")

-- Initialize module
local notifications = {}

-- Notification storage
notifications.history = {}
notifications.popup = nil
notifications._label = nil
notifications._cached_button = nil  -- Add this to cache the button

-- Scrolling state
local scroll_state = {
    start_idx = 1,
    items_per_page = 5,  -- Will be adjusted based on max_height
}

-- Format the message to a single line with ellipsis
local function format_message(text, length)
    if not text then return "" end
    -- Remove newlines and extra spaces
    text = text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    -- Truncate if too long
    if #text > length then
        return text:sub(1, length) .. "..."
    end
    return text
end

-- Format timestamp into a 12-hour clock time
local function format_timestamp(timestamp)
    return os.date("%I:%M %p", timestamp):gsub("^0", "")  -- Remove leading zero from hour
end

-- Create a notification entry widget
local function create_notification_widget(n)
    -- Create close button
    local close_button = create_image_button({
        image_path = config_dir .. "theme-icons/close.png",
        image_size = dpi(16),
        padding = dpi(10),
        button_size = dpi(34),
        opacity = 0.5,
        opacity_hover = 1,
        bg_color = theme.notifications.button_bg,
        border_color = theme.notifications.button_border,
        hover_bg = theme.notifications.button_bg_focus,
        hover_border = theme.notifications.button_border_focus,
        shape_radius = dpi(0),
        on_click = function()
            for i, notif in ipairs(notifications.history) do
                if notif == n then
                    table.remove(notifications.history, i)
                    update_count()
                    break
                end
            end
            if notifications.popup and notifications.popup.visible then
                notifications.popup.widget = create_notification_list()
            end
        end
    })

    -- Container for close button that's initially invisible
    local close_container = wibox.widget {
        {
            close_button,
            left = dpi(17),
            top = dpi(10),
            widget = wibox.container.margin
        },
        halign = "left",
        valign = "center",
        widget = wibox.container.place
    }
    close_container.visible = false

    -- Create the content
    local content = wibox.widget {
        {
            {
                image = n.icon,
                resize = true,
                forced_width = config.notifications.icon_size,
                forced_height = config.notifications.icon_size,
                widget = wibox.widget.imagebox,
            },
            valign = "center",
            widget = wibox.container.place
        },
        {
            {
                markup = "<b>" .. format_message(n.title, 30) .. "</b>",
                font = font_with_size(dpi(12)),
                align = "left",
                forced_height = dpi(20),
                widget = wibox.widget.textbox,
                id = "notif_title"
            },
            {
                {
                    {
                        text = format_message(n.text, dpi(60)),
                        font = font_with_size(dpi(12)),
                        align = "left",
                        forced_height = dpi(22),
                        widget = wibox.widget.textbox,
                        id = "notif_message"
                    },
                    forced_width = dpi(300), -- Fixed width for message
                    widget = wibox.container.constraint
                },
                {
                    text = format_timestamp(n.timestamp),
                    font = font_with_size(dpi(10)),
                    align = "right",
                    forced_width = dpi(50), -- Fixed width for timestamp
                    widget = wibox.widget.textbox
                },
                layout = wibox.layout.fixed.horizontal,
                spacing = dpi(10)
            },
            spacing = dpi(-2),
            layout = wibox.layout.fixed.vertical
        },
        spacing = dpi(10),
        layout = wibox.layout.fixed.horizontal
    }


    local bg_container = wibox.widget {
		{
	        {
	            content,
	            margins = dpi(8),
	            widget = wibox.container.margin
	        },
	        bg = theme.notifications.notif_bg,
	        widget = wibox.container.background,
			shape = function(cr, width, height)
	            gears.shape.rounded_rect(cr, width, height, dpi(6))
	        end,
			shape_border_width = 1,
			shape_border_color = theme.notifications.notif_border,
			id = "notif_background"
		},
		top = dpi(10),
		bottom = 0,
		left = dpi(10),
		right = dpi(10),
		widget = wibox.container.margin
    }

    -- Main container with overlay
    local w = wibox.widget {
        bg_container,
        close_container,
        layout = wibox.layout.stack
    }

    -- Show/hide close button and change background on hover
    w:connect_signal("mouse::enter", function()
        close_container.visible = true
		local background = bg_container:get_children_by_id("notif_background")[1]
        background.bg = theme.notifications.notif_bg_hover
		background.shape_border_color = theme.notifications.notif_border_hover
    end)
    w:connect_signal("mouse::leave", function()
        close_container.visible = false
		local background = bg_container:get_children_by_id("notif_background")[1]
        background.bg = theme.notifications.notif_bg
		background.shape_border_color = theme.notifications.notif_border
    end)

    return w
end

-- Create the notification list widget
function create_notification_list()
    local list_layout = wibox.layout.fixed.vertical()
    list_layout.spacing = dpi(0)

    -- Calculate items per page based on max_height and entry_height
    scroll_state.items_per_page = math.floor(
        (config.notifications.max_height - dpi(20)) / config.notifications.entry_height
    )

    -- Create preview area
    local preview_area = wibox.widget {
        {
			{
	            {
	                id = "preview_content",
	                layout = wibox.layout.fixed.vertical,
	            },
	            margins = dpi(10),
	            widget = wibox.container.margin
			},
			layout = wibox.layout.fixed.horizontal
        },
        bg = theme.notifications.preview_bg,
        widget = wibox.container.background,
        visible = false
    }

    -- Create right side layout that wraps the preview
    local right_layout = wibox.widget {
        nil,
        preview_area,
        nil,
        expand = "none",
        layout = wibox.layout.align.vertical
    }

    -- Create a constraint container that will handle the width only
    local right_container = wibox.widget {
        right_layout,
        forced_width = dpi(300),
        visible = false,  -- Start hidden
        widget = wibox.container.constraint
    }

    -- Function to update preview
    local function update_preview(n)
        local content = wibox.widget {
            -- Heading with icon and title
            {
                {
                    {
                        image = n.icon,
                        resize = true,
                        forced_width = dpi(48),
                        forced_height = dpi(48),
                        widget = wibox.widget.imagebox,
                    },
                    valign = "center",
                    widget = wibox.container.place
                },
                {
                    markup = "<b>" .. (n.title or "") .. "</b>",
                    align = "left",
                    widget = wibox.widget.textbox
                },
                spacing = dpi(10),
                layout = wibox.layout.fixed.horizontal
            },
            -- Full message text
            {
                text = n.text,
                align = "left",
                wrap = "word",
                widget = wibox.widget.textbox
            },
            spacing = dpi(8),
            layout = wibox.layout.fixed.vertical
        }
        
        local preview_content = preview_area:get_children_by_id("preview_content")[1]
        preview_content:reset()
        preview_content:add(content)
        preview_area.visible = true
        right_container.visible = true
    end

    -- Function to clear preview
    local function clear_preview()
        local preview_content = preview_area:get_children_by_id("preview_content")[1]
        preview_content:reset()
        preview_area.visible = false
        right_container.visible = false
    end

    -- Create notification widgets with hover behavior
    local visible_widgets = {}
    local end_idx = math.min(scroll_state.start_idx + scroll_state.items_per_page - 1, #notifications.history)
    for i = scroll_state.start_idx, end_idx do
        local n = notifications.history[i]
        local w = create_notification_widget(n)
        
        -- Add hover behavior for preview
        w:connect_signal("mouse::enter", function()
            update_preview(n)
        end)
        w:connect_signal("mouse::leave", function()
            clear_preview()
        end)
        
        list_layout:add(w)
        table.insert(visible_widgets, w)
    end

    -- Create scroll controls if needed
    local scroll_controls = wibox.widget {
        layout = wibox.layout.align.horizontal
    }

    if scroll_state.start_idx > 1 then
        scroll_controls.first = wibox.widget {
            markup = "<b>▲</b>",
            align = "center",
            widget = wibox.widget.textbox
        }
        scroll_controls:buttons(gears.table.join(
            scroll_controls:buttons(),
            awful.button({}, 1, function()
                scroll_state.start_idx = math.max(1, scroll_state.start_idx - scroll_state.items_per_page)
                if notifications.popup then
                    notifications.popup.widget = create_notification_list()
                end
            end)
        ))
    end

    if end_idx < #notifications.history then
        scroll_controls.third = wibox.widget {
            markup = "<b>▼</b>",
            align = "center",
            widget = wibox.widget.textbox
        }
        scroll_controls:buttons(gears.table.join(
            scroll_controls:buttons(),
            awful.button({}, 1, function()
                scroll_state.start_idx = math.min(
                    #notifications.history,
                    scroll_state.start_idx + scroll_state.items_per_page
                )
                if notifications.popup then
                    notifications.popup.widget = create_notification_list()
                end
            end)
        ))
    end

    -- Create clear all button
    local clear_all_button = create_labeled_image_button({
        image_path = config_dir .. "theme-icons/close.png",
        label_text = "All",
        image_size = dpi(16),
        padding = dpi(8),
        opacity = 0.5,
        opacity_hover = 1,
        bg_color = theme.notifications.button_bg,
        border_color = theme.notifications.button_border,
        fg_color = theme.notifications.button_fg,
        hover_bg = theme.notifications.button_bg_focus,
        hover_border = theme.notifications.button_border_focus,
        hover_fg = theme.notifications.button_fg_focus,
        shape_radius = dpi(4),
        on_click = function()
            notifications.history = {}
            if notifications.popup then
                notifications.popup.widget = create_notification_list()
            end
        end
    })

    -- Combine list, clear button, and controls
    local list_widget = wibox.widget {
        list_layout,
        {
            {
                {
                    clear_all_button,
                    layout = wibox.layout.fixed.horizontal
                },
                halign = "left",
                widget = wibox.container.place
            },
            margins = dpi(10),
            widget = wibox.container.margin
        },
        scroll_controls,
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(5)
    }

    -- Create the final layout
    local main_layout = wibox.layout.fixed.horizontal()
    main_layout.spacing = dpi(10)

    -- Add the list widget (with constraint)
    main_layout:add(wibox.widget {
        list_widget,
        forced_width = config.notifications.max_width,
        widget = wibox.container.constraint
    })

    -- Add right side container to main layout
    main_layout:add(right_container)

    return main_layout
end

-- Create the notification center button
function notifications.create_button()

    -- Create the label
    local label = wibox.widget {
        text = "0",
        font = font_with_size(math.floor(config.notifications.button_size * 0.75)),
        align = 'left',
        valign = 'center',
        widget = wibox.widget.textbox
    }

	local icon = wibox.widget {
        image = beautiful.notification_icon or config_dir .. "theme-icons/notification.png",
        resize = true,
        forced_width = config.notifications.button_size,
        forced_height = config.notifications.button_size,
        opacity = 0.5,
        widget = wibox.widget.imagebox
    }

    -- Create content
    local content = wibox.widget {
        {
            icon,
            margins = dpi(3),
            widget = wibox.container.margin
        },
        {
            label,
            right = dpi(3),
            widget = wibox.container.margin
        },
        layout = wibox.layout.fixed.horizontal
    }

    -- Create the button
    local button = wibox.widget {
        content,
        bg = theme.notifications.main_button_bg,
        shape = function(cr, width, height)
            gears.shape.rounded_rect(cr, width, height, dpi(4))
        end,
        fg = theme.notifications.button_fg,
        widget = wibox.container.background
    }

    -- Create the popup
    notifications.popup = awful.popup {
        widget = create_notification_list(),
        border_color = beautiful.border_focus,
        border_width = beautiful.border_width,
        ontop = true,
        visible = false,
        shape = function(cr, width, height)
            gears.shape.rounded_rect(cr, width, height, dpi(6))
        end,
        placement = function(d)
            awful.placement.top_left(d, {
                margins = {
                    top = beautiful.wibar_height + dpi(5),
                    left = dpi(5)
                },
                parent = mouse.screen
            })
        end
    }

    -- Add hover effects
    button:connect_signal("mouse::enter", function()
        button.bg = theme.notifications.main_button_bg_focus
        icon.opacity = 1
        button.fg = theme.notifications.button_fg_focus
    end)

    button:connect_signal("mouse::leave", function()
        button.bg = theme.notifications.main_button_bg
        icon.opacity = 0.5
        button.fg = theme.notifications.button_fg
    end)

    -- Add all button handlers
    button:buttons(gears.table.join(
        -- Left click to toggle
        awful.button({}, 1, function()
            -- Reset scroll position when opening
            if not notifications.popup.visible then
                scroll_state.start_idx = 1
                notifications.popup.widget = create_notification_list()
            end
            -- Position popup on current screen
            notifications.popup.screen = mouse.screen
            notifications.popup.visible = not notifications.popup.visible
        end),
        -- Scroll up
        awful.button({}, 4, function()
            if notifications.popup.visible then
                scroll_state.start_idx = math.max(1, scroll_state.start_idx - 1)
                notifications.popup.widget = create_notification_list()
            end
        end),
        -- Scroll down
        awful.button({}, 5, function()
            if notifications.popup.visible then
                scroll_state.start_idx = math.min(
                    #notifications.history - scroll_state.items_per_page + 1,
                    scroll_state.start_idx + 1
                )
                notifications.popup.widget = create_notification_list()
            end
        end)
    ))

    -- Update function
    function update_count()
		gears.timer.start_new(0.1, function()
            label.text = tostring(#notifications.history)
            return false
        end)
    end

    -- Connect signals
    naughty.connect_signal("added", update_count)
    naughty.connect_signal("destroyed", update_count)

    -- Initial update
    update_count()

	gears.timer.start_new(2, function()
        return false
    end)

    local layout = wibox.widget {
        button,
        margins = dpi(4),
        widget = wibox.container.margin
    }

    return layout
end

function notifications.update_count()
    if notifications._button and notifications._button.label then
        notifications._button.label.text = tostring(#notifications.history)
    end
end

-- Function to add a notification
function add_notification(n)
    -- Create notification entry
    local notification = {
        title = n.title or "",
        text = n.message or n.text or "",
        icon = n.app_icon or n.icon or "",
        timestamp = os.time()
    }
    
    -- Add to start of table
    table.insert(notifications.history, 1, notification)

    -- Update the list widget if it exists and is visible
    if notifications.popup and notifications.popup.visible then
        notifications.popup.widget = create_notification_list()
    end
end

-- Connect to notification signal
naughty.connect_signal("added", function(n)
    add_notification(n)
end)

return notifications