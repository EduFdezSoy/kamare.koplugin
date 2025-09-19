local BD = require("ui/bidi")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local datetime = require("datetime")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local ConfigDialog = require("ui/widget/configdialog")
local KamareOptions = require("kamareoptions")
local Configurable = require("frontend/configurable")
local InputContainer = require("ui/widget/container/inputcontainer")
local TitleBar = require("ui/widget/titlebar")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Size = require("ui/size")
local _ = require("gettext")
local T = require("ffi/util").template

local KamareImageViewer = InputContainer:extend{
    MODE = {
        off = 0,
        page_progress = 1,
        pages_left_book = 2,
        time = 3,
        battery = 4,
        percentage = 5,
        book_time_to_read = 6,
    },

    symbol_prefix = {
        letters = {
            time = nil,
            pages_left_book = "->",
            battery = "B:",
            percentage = "R:",
            book_time_to_read = "TB:",
        },
        icons = {
            time = "⌚",
            pages_left_book = "⇒",
            battery = "",
            percentage = "⤠",
            book_time_to_read = "⏳",
        },
        compact_items = {
            time = nil,
            pages_left_book = "›",
            battery = "",
            percentage = nil,
            book_time_to_read = nil
        }
    },

    image = nil,
    image_disposable = true,
    images_list_nb = nil,
    fullscreen = false,
    title_text = _("Viewing image"),
    width = nil,
    height = nil,
    scale_factor = 0,
    rotated = false,
    _center_x_ratio = 0.5,
    _center_y_ratio = 0.5,
    _image_wg = nil,
    _images_list = nil,
    _images_list_disposable = nil,
    _scaled_image_func = nil,

    reading_mode = 0,
    scrollable_container = nil,

    images_vertical_group = nil,
    loaded_images = nil,
    loaded_image_widgets = nil,

    on_close_callback = nil,
    start_page = 1,

    configurable = Configurable:new(),
    options = KamareOptions,

    image_padding = Size.margin.small,

    footer_settings = {
        enabled = true,
        page_progress = true,
        pages_left_book = true,
        time = true,
        battery = Device:hasBattery(),
        percentage = true,
        book_time_to_read = false,
        mode = 1,
        item_prefix = "icons",
        text_font_size = 14,
        text_font_bold = false,
        height = Screen:scaleBySize(15),
        disable_progress_bar = false,
        progress_bar_position = "alongside",
        progress_style_thin = false,
        progress_style_thin_height = 3,
        progress_style_thick_height = 7,
        progress_margin_width = 10,
        items_separator = "bar",
        align = "center",
        lock_tap = false,
    }
}

function KamareImageViewer:init()
    self:loadSettings()

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        local diagonal = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = range } },
            ScrollableHold = { GestureRange:new{ ges = "hold", range = range } },
            ScrollableHoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
            ScrollablePan = { GestureRange:new{ ges = "pan", range = range } },
            ScrollablePanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
            ScrollableSwipe = { GestureRange:new{ ges = "swipe", range = range } },
            TapDiagonal = { GestureRange:new{ ges = "two_finger_tap",
                    scale = {diagonal - Screen:scaleBySize(200), diagonal}, rate = 1.0,
                }
            },
            MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
        }
    end

    if self.fullscreen then
        self.covers_fullscreen = true
    end

    self.mode_index = {
        [0] = "off",
        [1] = "page_progress",
        [2] = "pages_left_book",
        [3] = "time",
        [4] = "battery",
        [5] = "percentage",
        [6] = "book_time_to_read",
    }

    self.viewing_start_time = os.time()
    self.image_viewing_times = {}
    self.current_image_start_time = os.time()

    self.title_bar_visible = false

    if self.reading_mode == 1 then
        if type(self.image) == "table" then
            self._images_list = self.image
            self._images_list_cur = self.start_page or 1
            if self._images_list_cur < 1 then
                self._images_list_cur = 1
            end
            self._images_list_nb = self.images_list_nb or #self._images_list
            if self._images_list_cur > self._images_list_nb then
                self._images_list_cur = self._images_list_nb
            end

            self.image = nil
            self._images_orig_scale_factor = self.scale_factor
            self._images_list_disposable = self.image_disposable

            logger.dbg("KamareImageViewer: continuous mode setup with start_page =", self._images_list_cur, "of", self._images_list_nb)
        end
    else
        if type(self.image) == "table" then
            self._images_list = self.image
            self._images_list_cur = self.start_page or 1
            if self._images_list_cur < 1 then
                self._images_list_cur = 1
            end
            self._images_list_nb = self.images_list_nb or #self._images_list
            if self._images_list_cur > self._images_list_nb then
                self._images_list_cur = self._images_list_nb
            end

            self.image = self._images_list[self._images_list_cur]
            if type(self.image) == "function" then
                self.image = self.image()
            end

            self._images_orig_scale_factor = self.scale_factor
            self._images_list_disposable = self.image_disposable
            self.image_disposable = self._images_list.image_disposable

            logger.dbg("KamareImageViewer: initialized with start_page =", self._images_list_cur, "of", self._images_list_nb)
        end
        if type(self.image) == "function" then
            self._scaled_image_func = self.image
            self.image = self._scaled_image_func(1)
        end
    end

    if self.image and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit") then
        self.rotated = (Screen:getWidth() > Screen:getHeight()) ~= (self.image:getWidth() > self.image:getHeight())
    end

    self.align = "center"
    self.region = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end

    self:updateGestureEvents()

    self:registerKeyEvents()

    self:setupTitleBar()
    self:initConfigGesListener()

    self.footerTextGeneratorMap = {
        empty = function() return "" end,

        page_progress = function()
            if not self._images_list or self._images_list_nb <= 1 then
                return ""
            end
            return ("%d / %d"):format(self._images_list_cur, self._images_list_nb)
        end,

        pages_left_book = function()
            if not self._images_list or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].pages_left_book
            local remaining = self._images_list_nb - self._images_list_cur
            return prefix and (prefix .. " " .. remaining) or tostring(remaining)
        end,

        time = function()
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].time
            local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
            if not prefix then
                return clock
            else
                return prefix .. " " .. clock
            end
        end,

        battery = function()
            if not Device:hasBattery() then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].battery
            local powerd = Device:getPowerDevice()
            local batt_lvl = powerd:getCapacity()
            local is_charging = powerd:isCharging()

            if symbol_type == "icons" or symbol_type == "compact_items" then
                if symbol_type == "compact_items" then
                    return BD.wrap(prefix)
                else
                    return BD.wrap(prefix) .. batt_lvl .. "%"
                end
            else
                return BD.wrap(prefix) .. " " .. (is_charging and "+" or "") .. batt_lvl .. "%"
            end
        end,

        percentage = function()
            if not self._images_list or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].percentage
            local progress = (self._images_list_cur - 1) / (self._images_list_nb - 1) * 100
            local string_percentage = "%.1f%%"
            if prefix then
                string_percentage = prefix .. " " .. string_percentage
            end
            return string_percentage:format(progress)
        end,

        book_time_to_read = function()
            if not self._images_list or self._images_list_nb <= 1 then
                return ""
            end
            local symbol_type = self.footer_settings.item_prefix
            local prefix = self.symbol_prefix[symbol_type].book_time_to_read
            local remaining = self._images_list_nb - self._images_list_cur
            local time_estimate = self:getTimeEstimate(remaining)
            return (prefix and prefix .. " " or "") .. time_estimate
        end,
    }

    self:updateFooterTextGenerator()

    self.frame_elements = VerticalGroup:new{ align = "left" }

    self.main_frame = FrameContainer:new{
        radius = not self.fullscreen and 8 or nil,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_elements,
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.main_frame,
    }

    if self._images_list and self._images_list_nb > 1 then
        self:setupFooter()
    end

    self:update()
end

function KamareImageViewer:registerKeyEvents()
    logger.dbg("registerKeyEvents called")

    if not Device:hasKeys() then
        logger.dbg("No keys available, skipping key event registration")
        return
    end

    self.key_events = {}

    if type(self.image) == "table" then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            ShowPrevImage = { { Device.input.group.PgBack } },
            ShowNextImage = { { Device.input.group.PgFwd } },
        }
        logger.dbg("Registered key events for image list navigation")
    else
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }

        if self.reading_mode == 1 then
            self.key_events.ScrollPageUp = { { Device.input.group.PgBack } }
            self.key_events.ScrollPageDown = { { Device.input.group.PgFwd } }
            logger.dbg("Continuous mode: registered scroll key events")
        else
            self.key_events.ZoomIn = { { Device.input.group.PgBack } }
            self.key_events.ZoomOut = { { Device.input.group.PgFwd } }
            logger.dbg("Page mode: registered zoom key events")
        end
    end

    logger.dbg("Key events registered successfully")
end

function KamareImageViewer:updateGestureEvents()
    if not Device:isTouchDevice() then
        logger.dbg("updateGestureEvents: not a touch device, skipping")
        return
    end

    local range = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    local diagonal = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        ScrollableHold = { GestureRange:new{ ges = "hold", range = range } },
        ScrollableHoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
        ScrollablePan = { GestureRange:new{ ges = "pan", range = range } },
        ScrollablePanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        ScrollableSwipe = { GestureRange:new{ ges = "swipe", range = range } },
        TapDiagonal = { GestureRange:new{ ges = "two_finger_tap",
                scale = {diagonal - Screen:scaleBySize(200), diagonal}, rate = 1.0,
            }
        },
        MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
    }

    if self.reading_mode == 0 then
        self.ges_events.Spread = { GestureRange:new{ ges = "spread", range = range } }
        self.ges_events.Pinch = { GestureRange:new{ ges = "pinch", range = range } }
        logger.dbg("updateGestureEvents: Added zoom gestures (Spread/Pinch) - page mode")
    else
        self.ges_events.Spread = nil
        self.ges_events.Pinch = nil
        logger.dbg("updateGestureEvents: Zoom gestures disabled - continuous mode")
    end
end

function KamareImageViewer:getKamareSettings()
    if self.ui and self.ui.kamare and self.ui.kamare.kamare_settings then
        return self.ui.kamare.kamare_settings
    end

    local kamare_settings_file = DataStorage:getSettingsDir() .. "/kamare.lua"
    local kamare_settings = LuaSettings:open(kamare_settings_file)

    if next(kamare_settings.data) ~= nil then
        return kamare_settings
    else
        kamare_settings:close()
        return nil
    end
end

function KamareImageViewer:loadSettings()
    local kamare_settings = self:getKamareSettings()
    if kamare_settings then
        self.configurable:loadSettings(kamare_settings, self.options.prefix.."_")

        if self.configurable.footer_mode then
            self.footer_settings.mode = self.configurable.footer_mode
        end

        if self.configurable.reading_mode ~= nil then
            self.reading_mode = self.configurable.reading_mode
            logger.dbg("Loaded reading mode:", self.reading_mode)
        end

        logger.dbg("Loaded Kamare settings from file")
    else
        logger.dbg("No Kamare settings available - using defaults")
    end

    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.reading_mode = self.reading_mode
    logger.dbg("Final configurable.footer_mode:", self.configurable.footer_mode)
    logger.dbg("Final footer_settings.mode:", self.footer_settings.mode)
end

function KamareImageViewer:syncAndSaveSettings()
    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.reading_mode = self.reading_mode
    self:saveSettings()
end

function KamareImageViewer:saveSettings()
    local kamare_settings = self:getKamareSettings()
    if kamare_settings then
        self.configurable:saveSettings(kamare_settings, self.options.prefix.."_")
        kamare_settings:flush()
        logger.dbg("Saved Kamare settings to file")
    end
end

function KamareImageViewer:getCurrentFooterMode()
    return self.footer_settings.mode
end

function KamareImageViewer:isValidMode(mode)
    if mode == self.MODE.off then
        return true
    end

    local mode_name = self.mode_index[mode]
    if not mode_name then
        logger.dbg("Invalid mode index:", mode)
        return false
    end

    local is_enabled = self.footer_settings[mode_name]
    logger.dbg("Mode", mode, "(", mode_name, ") is", is_enabled and "enabled" or "disabled")
    return is_enabled
end

function KamareImageViewer:cycleToNextValidMode()
    local old_mode = self.footer_settings.mode
    local max_modes = #self.mode_index
    local attempts = 0

    self.footer_settings.mode = (self.footer_settings.mode + 1) % (max_modes + 1)

    while attempts < max_modes + 1 do
        logger.dbg("Checking mode", self.footer_settings.mode)

        if self:isValidMode(self.footer_settings.mode) then
            local mode_name = self.mode_index[self.footer_settings.mode] or "off"
            logger.dbg("Found valid mode:", mode_name)
            break
        else
            self.footer_settings.mode = (self.footer_settings.mode + 1) % (max_modes + 1)
            logger.dbg("Skipping invalid mode, trying next")
        end
        attempts = attempts + 1
    end

    if attempts >= max_modes + 1 then
        logger.dbg("No valid modes found, defaulting to off")
        self.footer_settings.mode = self.MODE.off
    end

    local mode_name = self.mode_index[self.footer_settings.mode] or "off"
    logger.dbg("Mode cycled from", old_mode, "to", self.footer_settings.mode, "(", mode_name, ")")

    self:syncAndSaveSettings()

    return self.footer_settings.mode
end

function KamareImageViewer:setFooterMode(new_mode)
    if new_mode == nil then
        logger.warn("setFooterMode called with nil mode, ignoring")
        return false
    end

    if not self:isValidMode(new_mode) then
        logger.warn("Attempt to set invalid mode:", new_mode)
        return false
    end

    self.footer_settings.mode = new_mode

    local mode_name = self.mode_index[new_mode] or "off"
    logger.dbg("Set footer mode to:", new_mode, "name:", mode_name)

    self:syncAndSaveSettings()
    return true
end

function KamareImageViewer:initConfigGesListener()
    if not Device:isTouchDevice() then return end

    local DTAP_ZONE_MENU = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local DTAP_ZONE_CONFIG = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local DTAP_ZONE_CONFIG_EXT = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    local DTAP_ZONE_MINIBAR = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    local DTAP_ZONE_FORWARD = G_defaults:readSetting("DTAP_ZONE_FORWARD")
    local DTAP_ZONE_BACKWARD = G_defaults:readSetting("DTAP_ZONE_BACKWARD")

    self:registerTouchZones({
        {
            id = "kamare_menu_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_menu_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU_EXT.x, ratio_y = DTAP_ZONE_MENU_EXT.y,
                ratio_w = DTAP_ZONE_MENU_EXT.w, ratio_h = DTAP_ZONE_MENU_EXT.h,
            },
            overrides = {
                "kamare_menu_tap",
            },
            handler = function() return self:onTapMenu() end,
        },
        {
            id = "kamare_config_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG.x, ratio_y = DTAP_ZONE_CONFIG.y,
                ratio_w = DTAP_ZONE_CONFIG.w, ratio_h = DTAP_ZONE_CONFIG.h,
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_config_ext_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_CONFIG_EXT.x, ratio_y = DTAP_ZONE_CONFIG_EXT.y,
                ratio_w = DTAP_ZONE_CONFIG_EXT.w, ratio_h = DTAP_ZONE_CONFIG_EXT.h,
            },
            overrides = {
                "kamare_config_tap",
            },
            handler = function() return self:onTapConfig() end,
        },
        {
            id = "kamare_forward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_FORWARD.x, ratio_y = DTAP_ZONE_FORWARD.y,
                ratio_w = DTAP_ZONE_FORWARD.w, ratio_h = DTAP_ZONE_FORWARD.h,
            },
            handler = function() return self:onTapForward() end,
        },
        {
            id = "kamare_backward_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_BACKWARD.x, ratio_y = DTAP_ZONE_BACKWARD.y,
                ratio_w = DTAP_ZONE_BACKWARD.w, ratio_h = DTAP_ZONE_BACKWARD.h,
            },
            handler = function() return self:onTapBackward() end,
        },
        {
            id = "kamare_minibar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MINIBAR.x, ratio_y = DTAP_ZONE_MINIBAR.y,
                ratio_w = DTAP_ZONE_MINIBAR.w, ratio_h = DTAP_ZONE_MINIBAR.h,
            },
            handler = function() return self:onTapMinibar() end,
        },
    })
end

function KamareImageViewer:onShowConfigMenu()
    logger.dbg("Showing Kamare config menu")

    self.configurable.footer_mode = self.footer_settings.mode
    self.configurable.reading_mode = self.reading_mode
    logger.dbg("Before showing config dialog - configurable.footer_mode:", self.configurable.footer_mode)
    logger.dbg("Before showing config dialog - footer_settings.mode:", self.footer_settings.mode)

    logger.dbg("Configurable object contents:")
    for k, v in pairs(self.configurable) do
        logger.dbg("  ", k, "=", v)
    end

    self.config_dialog = ConfigDialog:new{
        document = nil,
        ui = self.ui or self,
        configurable = self.configurable,
        config_options = self.options,
        is_always_active = true,
        covers_footer = true,
        close_callback = function()
            self:onConfigCloseCallback()
        end,
    }

    self.config_dialog:onShowConfigPanel(1)
    UIManager:show(self.config_dialog)
    return true
end

function KamareImageViewer:onConfigCloseCallback()
    self.config_dialog = nil

    local footer_mode = self.configurable.footer_mode
    if footer_mode and footer_mode ~= self.footer_settings.mode then
        if self:setFooterMode(footer_mode) then
            self:fullFooterRefresh()
        end
    end

    local reading_mode = self.configurable.reading_mode
    if reading_mode ~= nil and reading_mode ~= self.reading_mode then
        local old_mode = self.reading_mode
        self.reading_mode = reading_mode
        logger.dbg("Reading mode changed from", old_mode, "to", self.reading_mode)

        if self.scrollable_container then
            logger.dbg("onConfigCloseCallback: Freeing existing scrollable container")
            self.scrollable_container:free()
            self.scrollable_container = nil
        end
        self:_clean_image_wg()

        self:updateGestureEvents()

        self:registerKeyEvents()

        self:update()
    end

    self:syncAndSaveSettings()
end

function KamareImageViewer:onCloseConfigMenu()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end
end

function KamareImageViewer:onSetFooterMode(...)
    local args = {...}
    logger.dbg("onSetFooterMode called with", #args, "arguments:")
    for i, arg in ipairs(args) do
        logger.dbg("  arg[" .. i .. "] =", arg, "(" .. type(arg) .. ")")
    end

    local mode = args[1]
    logger.dbg("onSetFooterMode called with mode:", mode)

    if self:setFooterMode(mode) then
        self:fullFooterRefresh()
        logger.dbg("Footer mode updated to:", mode)
        return true
    end

    return false
end

function KamareImageViewer:onSetReadingMode(arg)
    logger.dbg("onSetReadingMode: Handling SetReadingMode event with arg:", arg)
    logger.dbg("onSetReadingMode: arg type =", type(arg), "arg value =", tostring(arg))

    local old_mode = self.reading_mode
    self.reading_mode = arg
    self.configurable.reading_mode = arg

    logger.dbg("onSetReadingMode: Reading mode changed from", old_mode, "to", self.reading_mode)

    if self.scrollable_container then
        logger.dbg("onSetReadingMode: Freeing existing scrollable container")
        self.scrollable_container:free()
        self.scrollable_container = nil
    end
    logger.dbg("onSetReadingMode: Cleaning image widget...")
    self:_clean_image_wg()

    logger.dbg("onSetReadingMode: Updating gesture events...")
    self:updateGestureEvents()

    self:registerKeyEvents()

    logger.dbg("onSetReadingMode: Updating UI...")
    self:update()
    self:fullFooterRefresh()

    logger.dbg("onSetReadingMode: SetReadingMode handled successfully")
    return true
end

function KamareImageViewer:fullFooterRefresh()
    self:applyFooterMode()
    self:refreshFooter()
end

function KamareImageViewer:onTapMenu()
    logger.dbg("Menu zone tap - toggling title bar")
    self:toggleTitleBar()
    return true
end

function KamareImageViewer:onTapConfig()
    logger.dbg("Config zone tap - showing config menu")
    return self:onShowConfigMenu()
end

function KamareImageViewer:onTapMinibar()
    logger.dbg("Minibar zone tap - cycling footer mode")
    if not self.footer_settings.enabled or not self._images_list or self._images_list_nb <= 1 then
        logger.dbg("Footer not available for minibar tap")
        return false
    end

    if self.footer_settings.lock_tap then
        logger.dbg("Footer tap locked - opening config menu instead")
        return self:onShowConfigMenu()
    end

    self:cycleToNextValidMode()
    self:fullFooterRefresh()

    local footer_height = self.footer_settings.height
    local footer_region = Geom:new{
        x = 0, y = Screen:getHeight() - footer_height,
        w = Screen:getWidth(), h = footer_height
    }
    UIManager:setDirty(self, "ui", footer_region)
    return true
end

function KamareImageViewer:onTapForward()
    logger.dbg("Forward zone tap")

    if self.reading_mode == 1 then
        if self.scrollable_container then
            logger.dbg("Continuous mode: scrolling down")
            local result = self.scrollable_container:onScrollPageDown()
            self:_checkAndLoadMoreImages()
            return result
        else
            logger.dbg("Continuous mode: no scrollable container, falling back to page navigation")
            if BD.mirroredUILayout() then
                self:onShowPrevImage()
            else
                self:onShowNextImage()
            end
            return true
        end
    else
        if BD.mirroredUILayout() then
            logger.dbg("Mirrored layout - going to previous image")
            self:onShowPrevImage()
        else
            logger.dbg("Normal layout - going to next image")
            self:onShowNextImage()
        end
        return true
    end
end

function KamareImageViewer:onTapBackward()
    logger.dbg("Backward zone tap")

    if self.reading_mode == 1 then
        if self.scrollable_container then
            logger.dbg("Continuous mode: scrolling up")
            local result = self.scrollable_container:onScrollPageUp()
            self:_checkAndLoadMoreImages()
            return result
        else
            logger.dbg("Continuous mode: no scrollable container, falling back to page navigation")
            if BD.mirroredUILayout() then
                self:onShowNextImage()
            else
                self:onShowPrevImage()
            end
            return true
        end
    else
        if BD.mirroredUILayout() then
            logger.dbg("Mirrored layout - going to next image")
            self:onShowNextImage()
        else
            logger.dbg("Normal layout - going to previous image")
            self:onShowPrevImage()
        end
        return true
    end
end

function KamareImageViewer:onTapUnzoned(ges)
    logger.dbg("Unzoned tap - showing config menu")
    return self:onShowConfigMenu()
end

function KamareImageViewer:setupTitleBar()
    local title = self._title or _("Images")
    local subtitle

    if self.metadata then
        title = self.metadata.text or title
        if self.metadata.author then
            subtitle = T(_("by %1"), self.metadata.author)
        end
    end

    self.title_bar = TitleBar:new{
        width = Screen:getWidth(),
        fullscreen = "true",
        align = "center",
        title = title,
        subtitle = subtitle,
        title_shrink_font_to_fit = true,
        title_top_padding = Screen:scaleBySize(6),
        button_padding = Screen:scaleBySize(5),
        right_icon_size_ratio = 1,
        with_bottom_line = true,
        close_callback = function()
            self:onClose()
        end,
        show_parent = self,
    }

    logger.dbg("TitleBar created successfully with title:", title, "subtitle:", subtitle)
end

function KamareImageViewer:_clean_image_wg()
    if self._image_wg then
        logger.dbg("KamareImageViewer:_clean_image_wg")
        self._image_wg:free()
        self._image_wg = nil
    end
end

function KamareImageViewer:_getWebtoonScaleFactor(container_width, scrollbar_width)
    if not self.image then return 1 end

    local image_w = self.image:getWidth()

    local left_padding = self.image_padding + (scrollbar_width or 0)
    local right_padding = self.image_padding

    local horizontal_scrollbar_space = 3 * (scrollbar_width or 0)

    local available_w = (container_width or self.width) - left_padding - right_padding - horizontal_scrollbar_space

    local scale_factor = available_w / image_w

    logger.dbg("Webtoon scale factor:", scale_factor,
               "available_w:", available_w,
               "image_w:", image_w,
               "left_padding:", left_padding,
               "right_padding:", right_padding,
               "horizontal_scrollbar_space:", horizontal_scrollbar_space,
               "scrollbar_width:", scrollbar_width or 0)
    return scale_factor
end

function KamareImageViewer:_getRotationAngle()
    if not self.rotated then return 0 end

    local rotate_clockwise
    if Screen:getWidth() <= Screen:getHeight() then
        rotate_clockwise = G_reader_settings:isTrue("imageviewer_rotation_portrait_invert") or false
    else
        rotate_clockwise = not G_reader_settings:isTrue("imageviewer_rotation_landscape_invert")
    end
    return rotate_clockwise and 270 or 90
end

function KamareImageViewer:_new_image_wg()
    logger.dbg("_new_image_wg called - reading_mode:", self.reading_mode)

    local rotation_angle = self:_getRotationAngle()

    if self._scaled_image_func then
        local scale_factor_used
        self.image, scale_factor_used = self._scaled_image_func(self.scale_factor, self.width, self.img_container_h)
        if self.scale_factor == 0 then
            self._scale_factor_0 = scale_factor_used
        end
    end

    if self.reading_mode == 1 then
        logger.dbg("Using continuous mode - creating ScrollableContainer with dynamic loading")

        local start_page, end_page
        if self._images_list_cur == 1 then
            start_page = 1
            end_page = math.min(3, self._images_list_nb)
        elseif self._images_list_cur == self._images_list_nb then
            start_page = math.max(self._images_list_nb - 2, 1)
            end_page = self._images_list_nb
        else
            start_page = self._images_list_cur - 1
            end_page = self._images_list_cur + 1
            start_page = math.max(1, start_page)
            end_page = math.min(self._images_list_nb, end_page)
        end

        if self.loaded_image_widgets then
            for image_num, widget_info in pairs(self.loaded_image_widgets) do
                if widget_info.widget then
                    widget_info.widget:free()
                end
                if widget_info.placeholder then
                    widget_info.placeholder:free()
                end
                if widget_info.container then
                    widget_info.container:free()
                end
            end
            self.loaded_image_widgets = {}
        end

        self.images_vertical_group = VerticalGroup:new{}

        for page_num = start_page, end_page do
            self:_addImageToContainer(page_num)
        end

        self.loaded_images = {
            first = start_page,
            last = end_page
        }

        local scroll_y = 0
        if self._images_list_cur > start_page then
            for page_num = start_page, self._images_list_cur - 1 do
                local widget_info = self.loaded_image_widgets[page_num]
                if widget_info and widget_info.widget then
                    scroll_y = scroll_y + widget_info.widget:getSize().h
                end
            end
        end

        self.image_container = ScrollableContainer:new{
            dimen = Geom:new{
                x = 0, y = 0,
                w = self.width,
                h = self.img_container_h,
            },
            show_parent = self,
            background = Blitbuffer.COLOR_WHITE,
            self.images_vertical_group,
            swipe_full_view = true,
            scroll_bar_width = Screen:scaleBySize(4),
            scroll_callback = function()
                self:_checkAndLoadMoreImages()
            end,
        }
        self.scrollable_container = self.image_container

        self.scrollable_container:initState()
        if scroll_y > 0 then
            self.scrollable_container:setScrolledOffset(Geom:new{x = 0, y = scroll_y})
            logger.dbg("Continuous mode: set initial scroll to y =", scroll_y, "to show page", self._images_list_cur)
        else
            self.scrollable_container:setScrolledOffset(Geom:new{x = 0, y = 0})
        end

        logger.dbg("Continuous mode: initialized with pages", start_page, "to", end_page, "showing page", self._images_list_cur, "(total:", end_page - start_page + 1, "pages)")
    else
        logger.dbg("Using page mode - creating CenterContainer")
        local scale_factor = (self._scaled_image_func and 1 or self.scale_factor)
        local max_image_h = self.img_container_h
        local max_image_w = self.width
        if self.title_bar_visible then
            max_image_h = self.img_container_h - Size.margin.small*2
            max_image_w = self.width - Size.margin.small*2
        end

        self._image_wg = ImageWidget:new{
            image = self.image,
            image_disposable = false,
            file_do_cache = false,
            alpha = true,
            width = max_image_w,
            height = max_image_h,
            rotation_angle = rotation_angle,
            scale_factor = scale_factor,
            center_x_ratio = self._center_x_ratio,
            center_y_ratio = self._center_y_ratio,
        }

        self.image_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.img_container_h,
            },
            self._image_wg,
        }
        if self.scrollable_container then
            self.scrollable_container:free()
            self.scrollable_container = nil
        end
    end
end

function KamareImageViewer:setupFooter()
    self.footer_text_face = Font:getFace("ffont", self.footer_settings.text_font_size)
    self.footer_text = TextWidget:new{
        text = "",
        face = self.footer_text_face,
        bold = self.footer_settings.text_font_bold,
    }

    self.progress_bar = ProgressWidget:new{
        width = Screen:getWidth() - 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width),
        height = self.footer_settings.progress_style_thick_height,
        percentage = 0,
        tick_width = 0,
        ticks = nil,
        last = nil,
        initial_pos_marker = false,
    }

    self.progress_bar:updateStyle(true, self.footer_settings.progress_style_thick_height)

    local margin_span = HorizontalSpan:new{ width = Screen:scaleBySize(self.footer_settings.progress_margin_width) }

    local text_container = CenterContainer:new{
        dimen = Geom:new{ w = 0, h = self.footer_settings.height },
        self.footer_text,
    }

    self.footer_horizontal_group = HorizontalGroup:new{
        margin_span,
        self.progress_bar,
        text_container,
        margin_span,
    }

    self.footer_vertical_frame = VerticalGroup:new{
        self.footer_horizontal_group
    }

    self.footer_content = FrameContainer:new{
        self.footer_vertical_frame,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_bottom = 0,
    }

    local total_height = self.footer_settings.height

    self.footer_container = BottomContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = total_height,
        },
        self.footer_content,
    }

    logger.dbg("Screen dimensions:", Screen:getWidth(), Screen:getHeight())
    logger.dbg("Footer container created with initial dimen:", self.footer_container.dimen.x, self.footer_container.dimen.y, self.footer_container.dimen.w, self.footer_container.dimen.h)

    self:fullFooterRefresh()

    UIManager:setDirty(self, "ui", self.footer_container.dimen)
end

function KamareImageViewer:updateFooterTextGenerator()
    logger.dbg("updateFooterTextGenerator called")
    if not self.footer_settings.enabled then
        logger.dbg("Footer disabled, setting empty generator")
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end

    if not self:isValidMode(self.footer_settings.mode) then
        logger.dbg("Current mode not valid, setting empty generator")
        self.genFooterText = self.footerTextGeneratorMap.empty
        return
    end

    local mode_name = self.mode_index[self.footer_settings.mode]
    logger.dbg("Setting generator for mode:", mode_name)
    self.genFooterText = self.footerTextGeneratorMap[mode_name] or self.footerTextGeneratorMap.empty
end

function KamareImageViewer:updateFooterContent()
    if not self.footer_text then
        logger.dbg("updateFooterContent - no footer_text widget")
        return
    end

    if not self.genFooterText then
        logger.dbg("updateFooterContent - no text generator, setting empty")
        self.genFooterText = self.footerTextGeneratorMap.empty
        self:updateFooterTextGenerator()
    end

    local new_font_face = Font:getFace("ffont", self.footer_settings.text_font_size)
    if new_font_face ~= self.footer_text_face then
        logger.dbg("updateFooterContent - font changed, updating")
        self.footer_text_face = new_font_face
        local current_text = self.footer_text.text
        self.footer_text:free()
        self.footer_text = TextWidget:new{
            text = current_text,
            face = self.footer_text_face,
            bold = self.footer_settings.text_font_bold,
        }
        self.footer_horizontal_group[3][1] = self.footer_text
    elseif self.footer_settings.text_font_bold ~= self.footer_text.bold then
        logger.dbg("updateFooterContent - bold changed, updating")
        local current_text = self.footer_text.text
        self.footer_text:free()
        self.footer_text = TextWidget:new{
            text = current_text,
            face = self.footer_text_face,
            bold = self.footer_settings.text_font_bold,
        }
        self.footer_horizontal_group[3][1] = self.footer_text
    end

    local text = self.genFooterText()
    logger.dbg("updateFooterContent - generated text:", text)
    self.footer_text:setText(text)

    local margins_width = 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width)

    local min_progress_width = math.floor(Screen:getWidth() * 0.20)
    local text_available_width = Screen:getWidth() - margins_width - min_progress_width

    self.footer_text:setMaxWidth(text_available_width)
    local text_size = self.footer_text:getSize()

    local text_spacer = Screen:scaleBySize(10)
    local text_container_width = text_size.w + text_spacer

    if text == "" or text_size.w <= 0 then
        self.footer_horizontal_group[3].dimen.w = 0
        self.progress_bar.width = Screen:getWidth() - 2 * Screen:scaleBySize(self.footer_settings.progress_margin_width)
    else
        self.footer_horizontal_group[3].dimen.w = text_container_width
        self.progress_bar.width = math.max(min_progress_width,
            Screen:getWidth() - margins_width - text_container_width)
    end

    self.footer_horizontal_group[4].width = Screen:scaleBySize(self.footer_settings.progress_margin_width)

    self.footer_horizontal_group:resetLayout()
end

function KamareImageViewer:refreshFooter()
    self:updateFooterContent()
    self:updateProgressBar()
    if self.footer_container then
        UIManager:setDirty(self, "ui", self.footer_container.dimen)
    end
end

function KamareImageViewer:updateProgressBar()
    if not self.progress_bar or self.footer_settings.disable_progress_bar then
        return
    end

    if not self._images_list or self._images_list_nb <= 1 then
        self.progress_bar:setPercentage(0)
        return
    end

    local progress = (self._images_list_cur - 1) / (self._images_list_nb - 1)
    self.progress_bar:setPercentage(progress)
end

function KamareImageViewer:getTimeEstimate(remaining_images)
    if #self.image_viewing_times == 0 then
        return _("N/A")
    end

    local total_time = 0
    for _, time in ipairs(self.image_viewing_times) do
        total_time = total_time + time
    end
    local avg_time = total_time / #self.image_viewing_times

    local remaining_seconds = remaining_images * avg_time

    if remaining_seconds < 60 then
        return T(_("%1s"), math.ceil(remaining_seconds))
    elseif remaining_seconds < 3600 then
        return T(_("%1m"), math.ceil(remaining_seconds / 60))
    else
        local hours = math.floor(remaining_seconds / 3600)
        local minutes = math.ceil((remaining_seconds % 3600) / 60)
        return T(_("%1h %2m"), hours, minutes)
    end
end

function KamareImageViewer:switchToImageNum(image_num)
    if self.current_image_start_time and self._images_list_cur then
        local viewing_time = os.time() - self.current_image_start_time
        if viewing_time > 0 and viewing_time < 300 then
            table.insert(self.image_viewing_times, viewing_time)
            if #self.image_viewing_times > 10 then
                table.remove(self.image_viewing_times, 1)
            end
        end
    end

    if image_num == self._images_list_cur then
        return
    end

    if self.reading_mode == 1 and self.scrollable_container then
        self.current_image_start_time = os.time()
        self:_loadImageRange(image_num)
    else
        if self.image and self.image_disposable and self.image.free then
            logger.dbg("KamareImageViewer:switchToImageNum: free self.image", self.image)
            self.image:free()
            self.image = nil
        end

        self.image = self._images_list[image_num]
        if type(self.image) == "function" then
            self.image = self.image()
        end
        self._images_list_cur = image_num
        self._center_x_ratio = 0.5
        self._center_y_ratio = 0.5
        self.scale_factor = self._images_orig_scale_factor
        self.current_image_start_time = os.time()
        self:update()
    end

    self:updateFooterContent()
    self:updateProgressBar()

    if self.footer_container then
        UIManager:setDirty(self, "ui", self.footer_container.dimen)
    end
end

function KamareImageViewer:onShowNextImage()
    if self._images_list_cur < self._images_list_nb then
        self:switchToImageNum(self._images_list_cur + 1)
    end
end

function KamareImageViewer:onShowPrevImage()
    if self._images_list_cur > 1 then
        self:switchToImageNum(self._images_list_cur - 1)
    end
end

function KamareImageViewer:onScrollPageUp()
    if self.reading_mode == 1 and self.scrollable_container then
        logger.dbg("Continuous mode: scrolling page up")
        return self.scrollable_container:onScrollPageUp()
    end
    return false
end

function KamareImageViewer:onScrollPageDown()
    if self.reading_mode == 1 and self.scrollable_container then
        logger.dbg("Continuous mode: scrolling page down")
        return self.scrollable_container:onScrollPageDown()
    end
    return false
end

function KamareImageViewer:handleEvent(event)
    logger.dbg("KamareImageViewer:handleEvent", event.type, event.ges and event.ges.ges)

    local handled = false

    if self.reading_mode == 1 and self.scrollable_container then
        if event.type == "gesture" and event.handler == nil and event.args and #event.args == 1 then
            local ges = event.args[1]
            local ges_type = ges.ges

            local scrollable_handlers = {
                ["hold"] = "ScrollableHold",
                ["hold_release"] = "ScrollableHoldRelease",
                ["pan"] = "ScrollablePan",
                ["pan_release"] = "ScrollablePanRelease",
                ["swipe"] = "ScrollableSwipe",
                ["hold_pan"] = "ScrollableHoldPan",
                ["hold_pan_release"] = "ScrollableHoldPanRelease",
            }

            local handler_name = scrollable_handlers[ges_type]
            if handler_name then
                logger.dbg("Detected scrollable gesture:", ges_type, "at position:", ges.pos and (ges.pos.x .. "," .. ges.pos.y) or "no pos")
                local scroll_event = {
                    type = "gesture",
                    handler = handler_name,
                    args = {ges},
                }

                if self.scrollable_container:handleEvent(scroll_event) then
                    logger.dbg("ScrollableContainer handled", ges_type)
                    UIManager:setDirty(self, "ui")

                    if ges_type == "pan" or ges_type == "pan_release" or ges_type == "swipe" then
                        logger.dbg("Scrollable gesture completed, checking for new image loads")
                        self:_checkAndLoadMoreImages()
                    end

                    handled = true
                end
            end
        elseif event.type == "key" then
            if event.key == "PgBack" then
                logger.dbg("Key event: PgBack - scrolling up")
                local result = self.scrollable_container:onScrollPageUp()
                self:_checkAndLoadMoreImages()
                return result
            elseif event.key == "PgFwd" then
                logger.dbg("Key event: PgFwd - scrolling down")
                local result = self.scrollable_container:onScrollPageDown()
                self:_checkAndLoadMoreImages()
                return result
            end
        end
    end

    if handled then
        return true
    end

    local pos = event.pos or (event.ges and event.ges.pos)
    if not pos then
        return InputContainer.handleEvent(self, event)
    end

    if self.title_bar_visible and self.title_bar and self.title_bar.dimen and
       self.title_bar.dimen:contains(pos) then
        logger.dbg("Propagating event to title bar")
        return self.title_bar:handleEvent(event)
    end

    if event.type == "touch" or event.type == "gesture" then
        if event.ges and event.ges.ges == "tap" then
            return self:onTap(nil, event.ges)
        end
    end

    return InputContainer.handleEvent(self, event)
end

function KamareImageViewer:onScrollableHold(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollableHold: starting hold gesture")
    return self.scrollable_container:onScrollableHold(_, ges)
end

function KamareImageViewer:onScrollableHoldRelease(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollableHoldRelease: ending hold gesture")
    return self.scrollable_container:onScrollableHoldRelease(_, ges)
end

function KamareImageViewer:onScrollablePan(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollablePan: panning")
    return self.scrollable_container:onScrollablePan(_, ges)
end

function KamareImageViewer:onScrollablePanRelease(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollablePanRelease: pan released")
    local result = self.scrollable_container:onScrollablePanRelease(_, ges)

    self:_updateCurrentImageFromScroll()

    return result
end

function KamareImageViewer:onScrollableSwipe(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollableSwipe: swipe detected - direction:", ges.direction, "distance:", ges.distance)
    return self.scrollable_container:onScrollableSwipe(_, ges)
end

function KamareImageViewer:onScrollableHoldPan(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollableHoldPan: hold+pan gesture")
    return self.scrollable_container:onScrollableHoldPan(_, ges)
end

function KamareImageViewer:onScrollableHoldPanRelease(_, ges)
    if self.reading_mode == 0 or not self.scrollable_container then
        return false
    end
    logger.dbg("onScrollableHoldPanRelease: hold+pan released")
    return self.scrollable_container:onScrollableHoldPanRelease(_, ges)
end

function KamareImageViewer:onTap(_, ges)
    logger.dbg("KamareImageViewer:onTap called with ges:", ges.pos.x, ges.pos.y)
    logger.dbg("Screen size:", Screen:getWidth(), Screen:getHeight())

    if self.title_bar_visible and self.title_bar and self.title_bar.dimen then
        if self.title_bar.dimen:contains(ges.pos) then
            return false
        end
    end

    return self:onTapUnzoned(ges)
end

function KamareImageViewer:applyFooterMode()
    local old_mode = self.footer_settings.mode
    self.footer_visible = (self.footer_settings.mode ~= self.MODE.off)
    logger.dbg("applyFooterMode - mode:", old_mode, "visible:", self.footer_visible)

    if not self.footer_visible then
        logger.dbg("Setting empty text generator")
        self.genFooterText = self.footerTextGeneratorMap.empty
        self:updateFooterTextGenerator()
        return
    end

    local mode_name = self.mode_index[self.footer_settings.mode]
    logger.dbg("Setting single mode generator:", mode_name)
    self.genFooterText = self.footerTextGeneratorMap[mode_name] or self.footerTextGeneratorMap.empty
    self:updateFooterTextGenerator()
end

function KamareImageViewer:toggleTitleBar()
    self.title_bar_visible = not self.title_bar_visible
    logger.dbg("Title bar visibility toggled to:", self.title_bar_visible)

    if not self.title_bar then
        logger.dbg("Title bar not created, creating now")
        self:setupTitleBar()
    end

    local orig_dimen = self.main_frame.dimen

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    local title_height = 0
    if self.title_bar_visible and self.title_bar then
        table.insert(self.frame_elements, self.title_bar)
        title_height = self.title_bar:getSize().h or Screen:scaleBySize(35)
    end

    local footer_height = 0
    if self.footer_settings.enabled and self._images_list and self._images_list_nb > 1 and
       self.footer_container and self.footer_settings.mode ~= self.MODE.off then
        table.insert(self.frame_elements, self.footer_container)
        footer_height = self.footer_settings.height
    end

    local new_img_container_h = self.height - title_height - footer_height

    if self.image_container then
        self.image_container.dimen.h = new_img_container_h
        if self.reading_mode == 1 and self.scrollable_container then
            self.scrollable_container.dimen.h = new_img_container_h
            self.scrollable_container:initState()
        else
            self.image_container.dimen.h = new_img_container_h
            self._image_wg.dimen.h = new_img_container_h
        end
    end

    local image_insert_pos = 1
    if self.title_bar_visible then
        image_insert_pos = image_insert_pos + 1
        table.insert(self.frame_elements, image_insert_pos, self.image_container)
    else
        table.insert(self.frame_elements, image_insert_pos, self.image_container)
    end

    self.frame_elements:resetLayout()
    self.main_frame.radius = not self.fullscreen and 8 or nil

    local wfm_mode = Device:hasKaleidoWfm() and "partial" or "ui"
    local update_region = self.main_frame.dimen:combine(orig_dimen)
    UIManager:setDirty(self, function()
        return wfm_mode, update_region, true
    end)
end

function KamareImageViewer:update()
    self:_clean_image_wg()

    local orig_dimen = self.main_frame.dimen
    if self.fullscreen then
        self.height = Screen:getHeight()
        self.width = Screen:getWidth()
    else
        self.height = Screen:getHeight() - Screen:scaleBySize(40)
        self.width = Screen:getWidth() - Screen:scaleBySize(40)
    end

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    local title_height = 0
    if self.title_bar_visible and self.title_bar then
        table.insert(self.frame_elements, self.title_bar)
        title_height = self.title_bar:getSize().h or Screen:scaleBySize(35)
    end

    local footer_height = 0
    if self.footer_settings.enabled and self._images_list and self._images_list_nb > 1 and
       self.footer_container and self.footer_settings.mode ~= self.MODE.off then
        table.insert(self.frame_elements, self.footer_container)
        footer_height = self.footer_settings.height
    end

    self.img_container_h = self.height - title_height - footer_height
    self:_new_image_wg()

    local image_insert_pos = 1
    if self.title_bar_visible then image_insert_pos = image_insert_pos + 1 end
    table.insert(self.frame_elements, image_insert_pos, self.image_container)
    self.frame_elements:resetLayout()

    self.main_frame.radius = not self.fullscreen and 8 or nil

    local wfm_mode = Device:hasKaleidoWfm() and "partial" or "ui"
    self.dithered = true
    UIManager:setDirty(self, function()
        local update_region = self.main_frame.dimen:combine(orig_dimen)
        return wfm_mode, update_region, true
    end)
end

function KamareImageViewer:onZoomIn(inc)
    if self.reading_mode == 1 then
        logger.dbg("Zoom disabled in continuous mode")
        return false
    end

    self:_refreshScaleFactor()

    if not inc then
        inc = 0.2
    end

    local new_factor = self.scale_factor * (1 + inc)
    self:_applyNewScaleFactor(new_factor)
    return true
end

function KamareImageViewer:onZoomOut(dec)
    if self.reading_mode == 1 then
        logger.dbg("Zoom disabled in continuous mode")
        return false
    end

    self:_refreshScaleFactor()

    if not dec then
        dec = 0.2
    elseif dec >= 0.75 then
        dec = 0.75
    end

    local new_factor = self.scale_factor * (1 - dec)
    self:_applyNewScaleFactor(new_factor)
    return true
end

function KamareImageViewer:_refreshScaleFactor()
    if self.scale_factor == 0 then
        self.scale_factor = self._scale_factor_0 or self._image_wg:getScaleFactor()
    end
end

function KamareImageViewer:_applyNewScaleFactor(new_factor)
    self:_refreshScaleFactor()

    if not self._min_scale_factor or not self._max_scale_factor then
        self._min_scale_factor, self._max_scale_factor = self._image_wg:getScaleFactorExtrema()
    end
    new_factor = math.min(new_factor, self._max_scale_factor)
    new_factor = math.max(new_factor, self._min_scale_factor)
    if new_factor ~= self.scale_factor then
        self.scale_factor = new_factor
        self:update()
    else
        if self.scale_factor == self._min_scale_factor then
            logger.dbg("ImageViewer: Hit the min scaling factor:", self.scale_factor)
        elseif self.scale_factor == self._max_scale_factor then
            logger.dbg("ImageViewer: Hit the max scaling factor:", self.scale_factor)
        else
            logger.dbg("ImageViewer: No change in scaling factor:", self.scale_factor)
        end
    end
end

function KamareImageViewer:onSpread(_, ges)
    if self.reading_mode == 1 then return false end

    if not self._image_wg then
        return
    end

    self._center_x_ratio, self._center_y_ratio = self._image_wg:getPanByCenterRatio(ges.pos.x - Screen:getWidth()/2, ges.pos.y - Screen:getHeight()/2)
    if ges.direction == "vertical" then
        local img_h = self._image_wg:getCurrentHeight()
        local screen_h = Screen:getHeight()
        self:onZoomIn(ges.distance / math.min(screen_h, img_h))
    elseif ges.direction == "horizontal" then
        local img_w = self._image_wg:getCurrentWidth()
        local screen_w = Screen:getWidth()
        self:onZoomIn(ges.distance / math.min(screen_w, img_w))
    else
        local img_d = self._image_wg:getCurrentDiagonal()
        local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self:onZoomIn(ges.distance / math.min(screen_d, img_d))
    end
    return true
end

function KamareImageViewer:onPinch(_, ges)
    if self.reading_mode == 1 then return false end

    if not self._image_wg then
        return
    end

    if ges.direction == "vertical" then
        local img_h = self._image_wg:getCurrentHeight()
        local screen_h = Screen:getHeight()
        self:onZoomOut(ges.distance / math.min(screen_h, img_h))
    elseif ges.direction == "horizontal" then
        local img_w = self._image_wg:getCurrentWidth()
        local screen_w = Screen:getWidth()
        self:onZoomOut(ges.distance / math.min(screen_w, img_w))
    else
        local img_d = self._image_wg:getCurrentDiagonal()
        local screen_d = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
        self:onZoomOut(ges.distance / math.min(screen_d, img_d))
    end
    return true
end

function KamareImageViewer:onClose()
    if self.config_dialog then
        self.config_dialog:closeDialog()
    end

    self:syncAndSaveSettings()

    if self.title_bar_visible and self.title_bar then
        UIManager:close(self.title_bar)
        self.title_bar_visible = false
        logger.dbg("Title bar closed on viewer close")
    end

    if self.current_image_start_time and self._images_list_cur then
        local viewing_time = os.time() - self.current_image_start_time
        if viewing_time > 0 and viewing_time < 300 then
            table.insert(self.image_viewing_times, viewing_time)
            if #self.image_viewing_times > 10 then
                table.remove(self.image_viewing_times, 1)
            end
        end
    end

    if self.on_close_callback then
        logger.dbg("KamareImageViewer: calling on_close_callback")
        self.on_close_callback(self._images_list_cur, self._images_list_nb)
    end

    if self.image and self.image_disposable and self.image.free then
        logger.dbg("KamareImageViewer:onClose: free self.image", self.image)
        self.image:free()
        self.image = nil
    end
    if self._images_list and self._images_list_disposable and self._images_list.free then
        logger.dbg("KamareImageViewer:onClose: free self._images_list", self._images_list)
        self._images_list:free()
    end
    if self._scaled_image_func then
        self._scaled_image_func(false)
        self._scaled_image_func = nil
    end
    self._image_wg = nil

    if self.scrollable_container then
        logger.dbg("KamareImageViewer:onClose: freeing scrollable container")
        self.scrollable_container:free()
        self.scrollable_container = nil
    end

    if self.loaded_image_widgets then
        for image_num, widget_info in pairs(self.loaded_image_widgets) do
            if widget_info.widget then
                widget_info.widget:free()
            end
            if widget_info.placeholder then
                widget_info.placeholder:free()
            end
            if widget_info.container then
                widget_info.container:free()
            end
        end
        self.loaded_image_widgets = nil
    end

    if self.images_vertical_group then
        self.images_vertical_group:free()
        self.images_vertical_group = nil
    end

    self.loaded_images = nil

    if self.footer_text then
        self.footer_text:free()
    end
    if self.footer_container then
        self.footer_container:free()
    end
    if self.title_bar then
        self.title_bar:free()
    end

    UIManager:setDirty(nil, function()
        return "flashui", self.main_frame.dimen
    end)

    UIManager:close(self)
    return true
end

function KamareImageViewer:_loadImageRange(target_image)
    if not self.loaded_images or not self.scrollable_container then
        logger.dbg("_loadImageRange: No existing container, doing full rebuild")
        if self.scrollable_container then
            self.scrollable_container:free()
            self.scrollable_container = nil
        end
        self:_clean_image_wg()
        self._images_list_cur = target_image
        self:update()
        return
    end

    local new_first = math.max(1, target_image - 1)
    local new_last = math.min(self._images_list_nb, target_image + 1)

    logger.dbg("_loadImageRange: target =", target_image, "new range:", new_first, "to", new_last)
    logger.dbg("_loadImageRange: current range:", self.loaded_images.first, "to", self.loaded_images.last)

    local overlap_start = math.max(self.loaded_images.first, new_first)
    local overlap_end = math.min(self.loaded_images.last, new_last)
    local overlap_size = math.max(0, overlap_end - overlap_start + 1)

    if overlap_size == 0 then
        logger.dbg("_loadImageRange: No overlap, doing full rebuild")
        if self.scrollable_container then
            self.scrollable_container:free()
            self.scrollable_container = nil
        end
        self:_clean_image_wg()
        self:update()
        return
    end

    for image_num = self.loaded_images.first, self.loaded_images.last do
        if image_num < new_first or image_num > new_last then
            local widget_info = self.loaded_image_widgets[image_num]
            if widget_info then
                for i, child in ipairs(self.images_vertical_group) do
                    if child == widget_info.container then
                        table.remove(self.images_vertical_group, i)
                        break
                    end
                end

                if widget_info.widget then
                    widget_info.widget:free()
                end
                if widget_info.container then
                    widget_info.container:free()
                end
                if widget_info.placeholder then
                    widget_info.placeholder:free()
                end

                self.loaded_image_widgets[image_num] = nil
                logger.dbg("_loadImageRange: Removed image", image_num)
            end
        end
    end

    for image_num = new_first, new_last do
        if image_num < self.loaded_images.first or image_num > self.loaded_images.last then
            if image_num < self.loaded_images.first then
                self:_addImageToContainerAtStart(image_num)
                logger.dbg("_loadImageRange: Added image", image_num, "at start")
            else
                self:_addImageToContainer(image_num)
                logger.dbg("_loadImageRange: Added image", image_num, "at end")
            end
        end
    end

    self.loaded_images.first = new_first
    self.loaded_images.last = new_last

    self.images_vertical_group:resetLayout()
    self.scrollable_container:initState()
    self:_scrollToImage(target_image)

    logger.dbg("_loadImageRange: Updated range to", new_first, "to", new_last, "showing", target_image)
    UIManager:setDirty(self, "ui")
end

function KamareImageViewer:_scrollToImage(image_num)
    if not self.loaded_images or not self.scrollable_container then
        return
    end

    local scroll_y = 0
    for page_num = self.loaded_images.first, image_num - 1 do
        local widget_info = self.loaded_image_widgets[page_num]
        if widget_info and widget_info.widget then
            scroll_y = scroll_y + widget_info.widget:getSize().h
        elseif widget_info and widget_info.original_size then
            scroll_y = scroll_y + widget_info.original_size.h
        end
    end

    self.scrollable_container:setScrolledOffset(Geom:new{x = 0, y = scroll_y})
    logger.dbg("Scrolled to image", image_num, "at y =", scroll_y)
end

function KamareImageViewer:_addImageToContainer(image_num)
    if not self._images_list or image_num < 1 or image_num > self._images_list_nb then
        logger.dbg("Cannot add image", image_num, "- out of bounds")
        return false
    end

    local image = self._images_list[image_num]
    if type(image) == "function" then
        image = image()
    end

    local rotation_angle = self:_getRotationAngle()

    local scrollbar_width = Screen:scaleBySize(4)
    local scale_factor = self:_getWebtoonScaleFactor(self.width, scrollbar_width)
    local full_image_w = image:getWidth() * scale_factor
    local full_image_h = image:getHeight() * scale_factor

    local image_widget = ImageWidget:new{
        image = image,
        image_disposable = false,
        file_do_cache = false,
        alpha = false,
        width = full_image_w,
        height = full_image_h,
        rotation_angle = rotation_angle,
        scale_factor = scale_factor,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
    }

    local left_padding = Size.margin.small + scrollbar_width
    local right_padding = Size.margin.small

    local padded_container = FrameContainer:new{
        padding_left = left_padding,
        padding_right = right_padding,
        padding_top = 0,
        padding_bottom = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        image_widget,
    }

    if not self.loaded_image_widgets then
        self.loaded_image_widgets = {}
    end
    self.loaded_image_widgets[image_num] = {
        widget = image_widget,
        container = padded_container
    }

    table.insert(self.images_vertical_group, padded_container)
    self.images_vertical_group:resetLayout()

    if self.scrollable_container then
        self.scrollable_container:initState()
    end

    logger.dbg("Added image", image_num, "to container - size:", full_image_w, "x", full_image_h)
    logger.dbg("Total content height after adding image:", self.images_vertical_group:getSize().h)
    return true
end

function KamareImageViewer:_addImageToContainerAtStart(image_num)
    if not self._images_list or image_num < 1 or image_num > self._images_list_nb then
        logger.dbg("Cannot add image", image_num, "- out of bounds")
        return false
    end

    local image = self._images_list[image_num]
    if type(image) == "function" then
        image = image()
    end

    local rotation_angle = self:_getRotationAngle()

    local scrollbar_width = Screen:scaleBySize(4)
    local scale_factor = self:_getWebtoonScaleFactor(self.width, scrollbar_width)
    local full_image_w = image:getWidth() * scale_factor
    local full_image_h = image:getHeight() * scale_factor

    local image_widget = ImageWidget:new{
        image = image,
        image_disposable = false,
        file_do_cache = false,
        alpha = false,
        width = full_image_w,
        height = full_image_h,
        rotation_angle = rotation_angle,
        scale_factor = scale_factor,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
    }

    local left_padding = Size.margin.small + scrollbar_width
    local right_padding = Size.margin.small

    local padded_container = FrameContainer:new{
        padding_left = left_padding,
        padding_right = right_padding,
        padding_top = 0,
        padding_bottom = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        image_widget,
    }

    if not self.loaded_image_widgets then
        self.loaded_image_widgets = {}
    end
    self.loaded_image_widgets[image_num] = {
        widget = image_widget,
        container = padded_container
    }

    table.insert(self.images_vertical_group, 1, padded_container)
    self.images_vertical_group:resetLayout()

    if self.scrollable_container then
        self.scrollable_container:initState()
    end

    logger.dbg("Added image", image_num, "to start of container - size:", full_image_w, "x", full_image_h)
    logger.dbg("Total content height after adding image at start:", self.images_vertical_group:getSize().h)
    return true
end

function KamareImageViewer:_checkAndLoadMoreImages()
    if not self.loaded_images or not self.scrollable_container then
        logger.dbg("_checkAndLoadMoreImages: missing required data")
        return
    end

    local scroll_offset = self.scrollable_container:getScrolledOffset()
    if not scroll_offset then
        logger.dbg("_checkAndLoadMoreImages: no scroll offset available")
        return
    end

    local scroll_y = scroll_offset.y
    local container_height = self.scrollable_container.dimen.h
    local content_height = self.scrollable_container:getScrolledSize().h

    logger.dbg("Scroll check - scroll_y:", scroll_y, "container_h:", container_height, "content_h:", content_height)
    logger.dbg("Loaded range:", self.loaded_images.first, "to", self.loaded_images.last, "out of", self._images_list_nb)

    self:_restoreNearbyPlaceholders()

    local top_threshold = container_height * 0.8
    if scroll_y < top_threshold and self.loaded_images.first > 1 then
        local prev_image = self.loaded_images.first - 1
        logger.dbg("Loading previous image:", prev_image, "due to scroll proximity to top")

        if self:_addImageToContainerAtStart(prev_image) then
            self.loaded_images.first = prev_image

            local added_height = self.loaded_image_widgets[prev_image].widget:getSize().h
            local new_scroll_y = scroll_y + added_height
            self.scrollable_container:setScrolledOffset(Geom:new{x = 0, y = new_scroll_y})

            logger.dbg("Successfully loaded previous image", prev_image, "- adjusted scroll by", added_height)
            UIManager:setDirty(self, "ui")
        end
    end

    local bottom_threshold = container_height * 0.8
    local distance_to_bottom = content_height - (scroll_y + container_height)

    logger.dbg("Distance to bottom:", distance_to_bottom, "threshold:", bottom_threshold)

    if distance_to_bottom < bottom_threshold and
       self.loaded_images.last < self._images_list_nb then

        local next_image = self.loaded_images.last + 1
        logger.dbg("Loading next image:", next_image, "due to scroll proximity")
        if self:_addImageToContainer(next_image) then
            self.loaded_images.last = next_image
            logger.dbg("Successfully loaded image", next_image, "- new range:", self.loaded_images.first, "to", self.loaded_images.last)

            local new_content_height = self.scrollable_container:getScrolledSize().h
            logger.dbg("Content height after loading new image:", new_content_height)

            UIManager:setDirty(self, "ui")
        else
            logger.dbg("Failed to load image", next_image)
        end
    else
        if distance_to_bottom >= bottom_threshold then
            logger.dbg("Not close enough to bottom - distance:", distance_to_bottom, "threshold:", bottom_threshold)
        end
        if self.loaded_images.last >= self._images_list_nb then
            logger.dbg("All images already loaded")
        end
    end

    self:_updateCurrentImageFromScroll()

    self:_cleanupDistantImages()
end

function KamareImageViewer:_updateCurrentImageFromScroll()
    if not self.loaded_images or not self.scrollable_container then
        logger.dbg("_updateCurrentImageFromScroll: missing required data")
        return
    end

    local scroll_offset = self.scrollable_container:getScrolledOffset()
    if not scroll_offset then
        logger.dbg("_updateCurrentImageFromScroll: no scroll offset available")
        return
    end

    local scroll_y = scroll_offset.y
    local container_height = self.scrollable_container.dimen.h
    local center_y = scroll_y + (container_height / 2)

    logger.dbg("Updating current image - scroll_y:", scroll_y, "center_y:", center_y, "current_image:", self._images_list_cur)

    local current_y = 0
    local found_current = false

    for idx, child in ipairs(self.images_vertical_group) do
        local image_num = self.loaded_images.first + idx - 1
        if image_num <= self.loaded_images.last then
            local widget_info = self.loaded_image_widgets[image_num]
            if widget_info and widget_info.container == child then
                local image_height
                if widget_info.widget then
                    image_height = widget_info.widget:getSize().h
                elseif widget_info.original_size then
                    image_height = widget_info.original_size.h
                else
                    logger.dbg("No size info available for image", image_num)
                    return
                end

                local image_bottom = current_y + image_height

                logger.dbg("Checking image", image_num, "- top:", current_y, "bottom:", image_bottom, "height:", image_height)

                if center_y >= current_y and center_y < image_bottom then
                    if image_num ~= self._images_list_cur then
                        self._images_list_cur = image_num
                        self:updateFooterContent()
                        self:updateProgressBar()
                        logger.dbg("Current image updated to", image_num, "based on scroll position")
                    else
                        logger.dbg("Current image", image_num, "is still the most visible")
                    end
                    found_current = true
                    break
                end

                current_y = image_bottom
            else
                logger.dbg("No widget info for image", image_num, "or container mismatch")
            end
        end
    end

    if not found_current then
        logger.dbg("No image found at center position - keeping current image", self._images_list_cur)
    end
end

function KamareImageViewer:_cleanupDistantImages()
    if not self.loaded_images or not self.scrollable_container or not self.loaded_image_widgets then
        logger.dbg("_cleanupDistantImages: missing required data")
        return
    end

    local current = self._images_list_cur
    local keep_range = 1
    local cleaned_up = 0

    logger.dbg("Starting cleanup - current:", current, "keep range:", keep_range)

    for image_num, widget_info in pairs(self.loaded_image_widgets) do
        if math.abs(image_num - current) > keep_range and widget_info.widget then
            logger.dbg("Replacing distant image", image_num, "with placeholder - distance:", math.abs(image_num - current))

            local original_size = widget_info.widget:getSize()

            widget_info.widget:free()

            local placeholder_widget = Widget:new{
                dimen = Geom:new{
                    w = original_size.w,
                    h = original_size.h,
                }
            }

            local placeholder = FrameContainer:new{
                width = original_size.w,
                height = original_size.h,
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                padding = 0,
                placeholder_widget,
            }

            widget_info.container[1] = placeholder
            widget_info.widget = nil
            widget_info.placeholder = placeholder
            widget_info.original_size = original_size

            cleaned_up = cleaned_up + 1
        end
    end

    if cleaned_up > 0 then
        logger.dbg("Replaced", cleaned_up, "distant images with placeholders")
        self.images_vertical_group:resetLayout()

        if self.scrollable_container then
            self.scrollable_container:initState()
        end
    else
        logger.dbg("No images needed cleanup")
    end
end

function KamareImageViewer:_restoreNearbyPlaceholders()
    if not self.loaded_images or not self.scrollable_container or not self.loaded_image_widgets then
        return
    end

    local current = self._images_list_cur
    local keep_range = 1
    local restored = 0

    for image_num, widget_info in pairs(self.loaded_image_widgets) do
        if math.abs(image_num - current) <= keep_range and not widget_info.widget and widget_info.placeholder then
            logger.dbg("Restoring placeholder for image", image_num, "- distance:", math.abs(image_num - current))

            local image = self._images_list[image_num]
            if type(image) == "function" then
                image = image()
            end

            local rotation_angle = self:_getRotationAngle()

            local scrollbar_width = Screen:scaleBySize(4)
            local scale_factor = self:_getWebtoonScaleFactor(self.width, scrollbar_width)
            local full_image_w = image:getWidth() * scale_factor
            local full_image_h = image:getHeight() * scale_factor

            local image_widget = ImageWidget:new{
                image = image,
                image_disposable = false,
                file_do_cache = false,
                alpha = false,
                width = full_image_w,
                height = full_image_h,
                rotation_angle = rotation_angle,
                scale_factor = scale_factor,
                center_x_ratio = self._center_x_ratio,
                center_y_ratio = self._center_y_ratio,
            }

            widget_info.placeholder:free()

            widget_info.container[1] = image_widget
            widget_info.widget = image_widget
            widget_info.placeholder = nil
            widget_info.original_size = nil

            restored = restored + 1
        end
    end

    if restored > 0 then
        logger.dbg("Restored", restored, "placeholders to actual images")
        self.images_vertical_group:resetLayout()

        if self.scrollable_container then
            self.scrollable_container:initState()
        end

        UIManager:setDirty(self, "ui")
    end
end

return KamareImageViewer
