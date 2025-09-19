local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local DetailViewer = WidgetContainer:extend{
    title = _("Details"),
    dimen = nil,
    book_data = nil,
    catalog_manager = nil,
}

function DetailViewer:init()
    logger.dbg("DetailViewer:init() called for book:", self.book_data and self.book_data.title)
    logger.dbg("DetailViewer:init() - Getting screen dimensions")

    self.dimen = Geom:new{
        w = Device.screen:getWidth(),
        h = Device.screen:getHeight(),
    }
    logger.dbg("DetailViewer:init() - Screen dimensions:", self.dimen.w, "x", self.dimen.h)

    logger.dbg("DetailViewer:init() - Initializing caches")
    self.cover_cache = {}
    self.downloading_urls = {}

    -- Add gesture events
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        return self.dimen
                    end
                }
            },
        }
    end

    logger.dbg("DetailViewer:init() - Calling initUI()")
    self:initUI()
    logger.dbg("DetailViewer:init() - Completed successfully")
end

function DetailViewer:initUI()
    logger.dbg("DetailViewer:initUI() - Starting UI initialization")
    local title_bar_height = Size.item.height_default
    local content_height = self.dimen.h - title_bar_height
    logger.dbg("DetailViewer:initUI() - Title bar height:", title_bar_height, "Content height:", content_height)

    -- Create title bar
    logger.dbg("DetailViewer:initUI() - Creating title bar")
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        height = title_bar_height,
        title = self.title,
        title_shrink_font_to_fit = true,
        left_icon = "appbar.chevron.left",
        left_icon_tap_callback = function()
            self:onClose()
        end,
        close_callback = function()
            self:onClose()
        end,
    }
    logger.dbg("DetailViewer:initUI() - Title bar created successfully")

    -- Create content
    logger.dbg("DetailViewer:initUI() - Creating content widget")
    self.content_widget = self:createContent(content_height)
    logger.dbg("DetailViewer:initUI() - Content widget created successfully")

    logger.dbg("DetailViewer:initUI() - Creating main frame container")
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            self.content_widget,
        }
    }
    logger.dbg("DetailViewer:initUI() - UI initialization completed successfully")
end

function DetailViewer:createContent(content_height)
    logger.dbg("DetailViewer:createContent() - Starting content creation, height:", content_height)
    local padding = Size.padding.large
    local cover_width = math.floor(self.dimen.w * 0.35)
    local cover_height = math.floor(cover_width * 1.5) -- 2:3 aspect ratio
    local text_width = self.dimen.w - cover_width - 3 * padding
    logger.dbg("DetailViewer:createContent() - Calculated dimensions - cover:", cover_width, "x", cover_height, "text width:", text_width)

    -- Create cover image
    logger.dbg("DetailViewer:createContent() - Creating cover widget")
    local cover_widget = self:createCoverWidget(cover_width, cover_height)
    logger.dbg("DetailViewer:createContent() - Cover widget created")

    -- Create book info
    logger.dbg("DetailViewer:createContent() - Creating info widget")
    local info_widget = self:createInfoWidget(text_width)
    logger.dbg("DetailViewer:createContent() - Info widget created")

    -- Main content layout
    logger.dbg("DetailViewer:createContent() - Creating main content layout")
    local main_content = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = padding },
        cover_widget,
        HorizontalSpan:new{ width = padding },
        info_widget,
    }
    logger.dbg("DetailViewer:createContent() - Main content layout created")

    -- Create action buttons
    logger.dbg("DetailViewer:createContent() - Creating action buttons")
    local buttons_widget = self:createActionButtons()
    logger.dbg("DetailViewer:createContent() - Action buttons created")

    logger.dbg("DetailViewer:createContent() - Creating final vertical group")
    local result = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = padding },
        main_content,
        VerticalSpan:new{ width = padding * 2 },
        buttons_widget,
        VerticalSpan:new{ width = padding },
    }
    logger.dbg("DetailViewer:createContent() - Content creation completed successfully")
    return result
end

function DetailViewer:createCoverWidget(width, height)
    logger.dbg("DetailViewer:createCoverWidget() - Starting, dimensions:", width, "x", height)
    logger.dbg("DetailViewer:createCoverWidget() - Book data available:", self.book_data ~= nil)

    local image_url = self.book_data.image or self.book_data.thumbnail
    local cover_widget

    if image_url then
        logger.dbg("DetailViewer:createCoverWidget() - Creating cover image, URL:", image_url)
        cover_widget = self:createCoverImage(image_url, width, height)
        logger.dbg("DetailViewer:createCoverWidget() - Cover image created")
    else
        logger.dbg("DetailViewer:createCoverWidget() - No image found, using placeholder")
        cover_widget = self:createPlaceholderCover(width, height)
        logger.dbg("DetailViewer:createCoverWidget() - Placeholder cover created")
    end

    logger.dbg("DetailViewer:createCoverWidget() - Completed successfully")
    return cover_widget
end

function DetailViewer:createInfoWidget(width)
    logger.dbg("DetailViewer:createInfoWidget() - Starting, width:", width)
    local info_items = {}

    -- Title
    logger.dbg("DetailViewer:createInfoWidget() - Creating title widget")
    local title = self.book_data.title or self.book_data.text or _("Unknown Title")
    logger.dbg("DetailViewer:createInfoWidget() - Title text:", title)
    table.insert(info_items, TextBoxWidget:new{
        text = title,
        face = Font:getFace("tfont", 20),
        width = width,
        alignment = "left",
    })
    table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default })
    logger.dbg("DetailViewer:createInfoWidget() - Title widget created")

    -- Author
    if self.book_data.author then
        table.insert(info_items, TextBoxWidget:new{
            text = self.book_data.author,
            face = Font:getFace("smallinfofont", 14),
            width = width,
            alignment = "left",
        })
        table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default / 2 })
    end

    -- Series
    if self.book_data.series then
        local series_text = self.book_data.series
        if self.book_data.series_index then
            series_text = series_text .. " #" .. self.book_data.series_index
        end
        table.insert(info_items, self:createInfoLine(_("Series:"), series_text, width))
        table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default / 2 })
    end

    -- Published date
    if self.book_data.published then
        table.insert(info_items, self:createInfoLine(_("Published:"), self.book_data.published, width))
        table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default / 2 })
    end

    -- Summary/Description
    if self.book_data.content or self.book_data.summary then
        table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(info_items, TextWidget:new{
            text = _("Summary:"),
            face = Font:getFace("smallinfofont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
        table.insert(info_items, VerticalSpan:new{ width = Size.span.vertical_default / 2 })

        local summary_text = self.book_data.content or self.book_data.summary
        -- Convert HTML to plain text if needed
        summary_text = util.htmlToPlainTextIfHtml(summary_text)

        table.insert(info_items, TextBoxWidget:new{
            text = summary_text,
            face = Font:getFace("smallinfofont", 12),
            width = width,
            alignment = "left",
        })
    end

    return VerticalGroup:new{
        align = "left",
        unpack(info_items),
    }
end

function DetailViewer:createInfoLine(label, value, width)
    return HorizontalGroup:new{
        align = "top",
        TextWidget:new{
            text = label,
            face = Font:getFace("smallinfofont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        TextBoxWidget:new{
            text = value,
            face = Font:getFace("smallinfofont", 14),
            width = width - 100, -- Reserve space for label
            alignment = "left",
        },
    }
end

function DetailViewer:createActionButtons()
    logger.dbg("DetailViewer:createActionButtons() - Starting")
    local button_width = (self.dimen.w - 3 * Size.padding.large) / 2
    local button_height = Size.item.height_big
    logger.dbg("DetailViewer:createActionButtons() - Button dimensions:", button_width, "x", button_height)

    -- Read button
    logger.dbg("DetailViewer:createActionButtons() - Creating read button")
    local read_button = self:createButton(_("Read"), button_width, button_height, function()
        self:onReadBook()
    end)
    logger.dbg("DetailViewer:createActionButtons() - Read button created")

    -- Download button
    logger.dbg("DetailViewer:createActionButtons() - Creating download button")
    local download_button = self:createButton(_("Download"), button_width, button_height, function()
        self:onDownloadBook()
    end)
    logger.dbg("DetailViewer:createActionButtons() - Download button created")

    logger.dbg("DetailViewer:createActionButtons() - Creating button container")
    local result = CenterContainer:new{
        dimen = Geom:new{
            w = self.dimen.w,
            h = button_height + Size.padding.large,
        },
        HorizontalGroup:new{
            align = "center",
            read_button,
            HorizontalSpan:new{ width = Size.padding.large },
            download_button,
        }
    }
    logger.dbg("DetailViewer:createActionButtons() - Completed successfully")
    return result
end

function DetailViewer:createButton(text, width, height, callback)
    logger.dbg("DetailViewer:createButton() - Creating button:", text, "dimensions:", width, "x", height)

    logger.dbg("DetailViewer:createButton() - Creating button widget frame")
    local button_widget = FrameContainer:new{
        width = width,
        height = height,
        padding = Size.padding.default,
        margin = 0,
        bordersize = Size.border.button,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = width - 2 * Size.padding.default,
                h = height - 2 * Size.padding.default,
            },
            TextWidget:new{
                text = text,
                face = Font:getFace("cfont", 16),
            }
        }
    }
    logger.dbg("DetailViewer:createButton() - Button widget frame created")

    logger.dbg("DetailViewer:createButton() - Creating tap input container")
    local tap_input = InputContainer:new{
        dimen = Geom:new{
            w = width,
            h = height,
        },
    }

    tap_input.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = width,
                    h = height,
                }
            }
        },
    }

    function tap_input:onTap()
        logger.dbg("DetailViewer:createButton() - Button tapped:", text)
        callback()
        return true
    end

    -- Make sure tap_input has a handleEvent method
    function tap_input:handleEvent(event)
        return InputContainer.handleEvent(self, event)
    end
    logger.dbg("DetailViewer:createButton() - Tap input container created")

    logger.dbg("DetailViewer:createButton() - Creating overlap group")
    local result = OverlapGroup:new{
        dimen = Geom:new{
            w = width,
            h = height,
        },
        button_widget,
        tap_input,
    }
    logger.dbg("DetailViewer:createButton() - Button creation completed successfully")
    return result
end

function DetailViewer:createCoverImage(image_url, width, height)
    -- Check cache first
    if self.cover_cache[image_url] then
        logger.dbg("DetailViewer: Found cached image")
        local cached_data = self.cover_cache[image_url]
        local bb = RenderImage:renderImageData(cached_data, #cached_data, false)

        if bb then
            local image_widget = ImageWidget:new{
                image = bb,
                width = width,
                height = height,
                scale_factor = 0,
                image_disposable = true,
            }
            return image_widget
        end
    end

    -- Download if not cached
    if not self.downloading_urls[image_url] then
        self:downloadCoverImage(image_url, width, height)
    end

    return self:createPlaceholderCover(width, height)
end

function DetailViewer:downloadCoverImage(image_url, width, height)
    logger.dbg("DetailViewer: Starting download for:", image_url)

    if self.downloading_urls[image_url] then
        return
    end
    self.downloading_urls[image_url] = true

    -- Use CatalogManager's downloadImage method
    local data, error_msg = self.catalog_manager:downloadImage(image_url)

    if data then
        local test_bb_ok, test_bb_err = pcall(function()
            return RenderImage:renderImageData(data, #data, false)
        end)

        if test_bb_ok and test_bb_err then
            test_bb_err:free()
            self.cover_cache[image_url] = data
            self.downloading_urls[image_url] = nil

            -- Update the cover image
            UIManager:nextTick(function()
                if self.dimen then
                    self:updateCoverImage(width, height)
                end
            end)
        else
            logger.err("DetailViewer: Failed to render image data")
            self.downloading_urls[image_url] = nil
        end
    else
        logger.warn("DetailViewer: Failed to download image:", error_msg)
        self.downloading_urls[image_url] = nil
    end
end

function DetailViewer:updateCoverImage(width, height)
    -- Rebuild the entire UI with the new cover image
    self:initUI()
    UIManager:setDirty(self, "ui")
end

function DetailViewer:createPlaceholderCover(width, height)
    local title = self.book_data.title or self.book_data.text or ""
    local text = title:sub(1, 1):upper()
    if text == "" then text = "?" end

    return FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = height,
            },
            TextWidget:new{
                text = text,
                face = Font:getFace("cfont", math.floor(height / 8)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
        }
    }
end

function DetailViewer:onReadBook()
    logger.dbg("DetailViewer: Read button tapped")
    -- TODO: Implement reading functionality
    UIManager:show(InfoMessage:new{
        text = _("Reading functionality coming soon"),
    })
end

function DetailViewer:onDownloadBook()
    logger.dbg("DetailViewer: Download button tapped")
    -- TODO: Implement download functionality
    UIManager:show(InfoMessage:new{
        text = _("Download functionality coming soon"),
    })
end

function DetailViewer:onClose()
    logger.dbg("DetailViewer:onClose() - Called")
    UIManager:close(self)
    if self.close_callback then
        logger.dbg("DetailViewer:onClose() - Calling close callback")
        self.close_callback()
    end
    logger.dbg("DetailViewer:onClose() - Completed")
end

function DetailViewer:handleEvent(event)
    if event.name == "CloseDocument" or event.name == "Close" then
        self:onClose()
        return true
    end
    return false
end

function DetailViewer:onShow()
    logger.dbg("DetailViewer:onShow() - Called")
    UIManager:setDirty(self, "ui")
    logger.dbg("DetailViewer:onShow() - UI marked as dirty")
end

return DetailViewer
