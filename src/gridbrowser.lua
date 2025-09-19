local Blitbuffer = require("ffi/blitbuffer")
local CatalogManager = require("catalogmanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local DetailViewer = require("detailviewer")
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

local GridBrowser = WidgetContainer:extend{
    title = _("Kavita Library"),
    dimen = nil,
    covers_per_row = 4,
    cover_spacing = Size.span.horizontal_default,
    row_spacing = Size.span.vertical_default,
}

function GridBrowser:init()
    logger.dbg("GridBrowser:init() called")
    self.catalog_manager = CatalogManager:new()
    
    -- Set authentication credentials in CatalogManager
    if self.server_config then
        self.catalog_manager.username = self.server_config.username
        self.catalog_manager.password = self.server_config.password
    end
    
    self.dimen = Geom:new{
        w = Device.screen:getWidth(),
        h = Device.screen:getHeight(),
    }

    -- Initialize data storage
    self.feeds_data = {
        on_deck = {},
        recently_updated = {},
        recently_added = {},
    }

    self.covers_cache = {} -- Cache for downloaded cover images
    self.downloading_urls = {} -- Track concurrent downloads

    self:initUI()

    -- Load feeds asynchronously if server config is available
    if self.server_config then
        logger.dbg("GridBrowser: server_config available, starting async feed loading")
        UIManager:nextTick(function()
            self:loadFeeds()
        end)
    else
        logger.dbg("GridBrowser: no server_config available")
        self:showNoServerMessage()
    end
end

function GridBrowser:initUI()
    -- Calculate dimensions
    local title_bar_height = Size.item.height_default
    local content_height = self.dimen.h - title_bar_height
    local row_height = math.floor((content_height - 4 * self.row_spacing) / 3)
    local cover_width = math.floor((self.dimen.w - (self.covers_per_row + 1) * self.cover_spacing) / self.covers_per_row)
    local cover_height = math.floor(row_height * 0.8) -- Leave space for title

    self.cover_size = {
        w = cover_width,
        h = cover_height,
    }

    -- Create title bar
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        height = title_bar_height,
        title = self.title,
        title_shrink_font_to_fit = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            self:onClose()
        end,
        close_callback = function()
            self:onClose()
        end,
    }

    -- Create content area
    self.content_container = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = self.row_spacing },
    }

    -- Create loading message
    self.loading_widget = CenterContainer:new{
        dimen = Geom:new{
            w = self.dimen.w,
            h = content_height,
        },
        TextWidget:new{
            text = _("Loading library..."),
            face = Font:getFace("infofont"),
        }
    }

    -- Create main vertical group that we can easily modify
    self.main_content = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.loading_widget,
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.main_content,
    }
end

function GridBrowser:loadFeeds()
    logger.dbg("GridBrowser:loadFeeds() called")
    if not self.server_config then
        logger.warn("GridBrowser: No server configured")
        self:showNoServerMessage()
        return
    end

    logger.dbg("GridBrowser: Starting to load feeds from server:", self.server_config.url)

    -- Load feeds asynchronously one by one to avoid blocking UI
    UIManager:nextTick(function()
        self:loadOnDeckFeed()
    end)
end

function GridBrowser:loadOnDeckFeed()
    logger.dbg("GridBrowser: Loading On Deck feed")
    local on_deck_items, on_deck_error = self.catalog_manager:getOnDeck(
        self.server_config.url,
        self.server_config.username,
        self.server_config.password
    )

    if on_deck_items then
        logger.dbg("GridBrowser: On Deck loaded, items count:", #on_deck_items)
        self.feeds_data.on_deck = on_deck_items
        self:updateContent()
    else
        logger.warn("GridBrowser: Failed to load On Deck:", on_deck_error)
    end

    -- Load next feed
    UIManager:nextTick(function()
        self:loadRecentlyUpdatedFeed()
    end)
end

function GridBrowser:loadRecentlyUpdatedFeed()
    logger.dbg("GridBrowser: Loading Recently Updated feed")
    local recently_updated_items, recently_updated_error = self.catalog_manager:getRecentlyUpdated(
        self.server_config.url,
        self.server_config.username,
        self.server_config.password
    )

    if recently_updated_items then
        logger.dbg("GridBrowser: Recently Updated loaded, items count:", #recently_updated_items)
        self.feeds_data.recently_updated = recently_updated_items
        self:updateContent()
    else
        logger.warn("GridBrowser: Failed to load Recently Updated:", recently_updated_error)
    end

    -- Load next feed
    UIManager:nextTick(function()
        self:loadRecentlyAddedFeed()
    end)
end

function GridBrowser:loadRecentlyAddedFeed()
    logger.dbg("GridBrowser: Loading Recently Added feed")
    local recently_added_items, recently_added_error = self.catalog_manager:getRecentlyAdded(
        self.server_config.url,
        self.server_config.username,
        self.server_config.password
    )

    if recently_added_items then
        logger.dbg("GridBrowser: Recently Added loaded, items count:", #recently_added_items)
        self.feeds_data.recently_added = recently_added_items
        self:updateContent()
    else
        logger.warn("GridBrowser: Failed to load Recently Added:", recently_added_error)
    end

    logger.dbg("GridBrowser: All feeds loading completed")
end

function GridBrowser:updateContent()
    -- Only rebuild if we have any data to show
    local has_data = #self.feeds_data.on_deck > 0 or
                     #self.feeds_data.recently_updated > 0 or
                     #self.feeds_data.recently_added > 0

    if has_data then
        self:buildContent()
    end
end

function GridBrowser:showNoServerMessage()
    -- Replace loading widget with no server message
    local no_server_widget = CenterContainer:new{
        dimen = Geom:new{
            w = self.dimen.w,
            h = self.dimen.h - Size.item.height_default,
        },
        TextWidget:new{
            text = _("No server configured"),
            face = Font:getFace("infofont"),
        }
    }

    -- Clear the old main_content properly
    if self.main_content then
        self.main_content:clear()
    end

    self.main_content = VerticalGroup:new{
        align = "left",
        self.title_bar,
        no_server_widget,
    }

    -- Clear the old frame container
    if self[1] then
        self[1]:clear()
    end

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.main_content,
    }

    UIManager:setDirty(self, "ui")
end

function GridBrowser:buildContent()
    logger.dbg("GridBrowser:buildContent() called")

    -- Clear and reset the existing content container properly
    if self.content_container then
        self.content_container:clear()
    end

    self.content_container = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = self.row_spacing },
    }

    -- Add On Deck section (no title, 4 covers)
    logger.dbg("GridBrowser: Adding On Deck section with", #self.feeds_data.on_deck, "items")
    self:addOnDeckSection(self.feeds_data.on_deck)

    -- Add two-column section for Recently Updated and Recently Added
    logger.dbg("GridBrowser: Adding two-column section")
    self:addTwoColumnSection(
        _("Recently Updated"), self.feeds_data.recently_updated,
        _("Recently Added"), self.feeds_data.recently_added
    )

    -- Add text links section
    self:addTextLinksSection()

    logger.dbg("GridBrowser: Clearing main_content and adding new content")

    -- Clear the old main_content properly
    if self.main_content then
        self.main_content:clear()
    end

    -- Replace loading widget with content
    self.main_content = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.content_container,
    }

    -- Clear the old frame container
    if self[1] then
        self[1]:clear()
    end

    -- Update the main frame container
    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.main_content,
    }

    logger.dbg("GridBrowser: Setting dirty and forcing repaint")

    -- Force a full refresh of the widget
    UIManager:setDirty(self, "ui")
    logger.dbg("GridBrowser:buildContent() completed")
end

function GridBrowser:addOnDeckSection(items)
    -- Books row (no title)
    local books_row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = self.cover_spacing },
    }

    -- Add up to 4 books
    for i = 1, math.min(4, #items) do
        local book = items[i]
        local book_widget = self:createBookWidget(book, self.cover_size)
        table.insert(books_row, book_widget)
        if i < 4 then
            table.insert(books_row, HorizontalSpan:new{ width = self.cover_spacing })
        end
    end

    table.insert(self.content_container, books_row)
    table.insert(self.content_container, VerticalSpan:new{ width = self.row_spacing })
end

function GridBrowser:addTwoColumnSection(left_title, left_items, right_title, right_items)
    -- Content row
    local content_row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = self.cover_spacing },
        self:createStackedColumn(left_items),
        HorizontalSpan:new{ width = self.cover_spacing },
        self:createStackedColumn(right_items),
    }

    table.insert(self.content_container, content_row)
    table.insert(self.content_container, VerticalSpan:new{ width = Size.span.vertical_default })

    -- Section titles underneath the stacks
    local titles_row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = self.cover_spacing },
        LeftContainer:new{
            dimen = Geom:new{
                w = (self.dimen.w - 3 * self.cover_spacing) / 2,
                h = Size.item.height_default,
            },
            TextWidget:new{
                text = left_title,
                face = Font:getFace("smallinfofont", 10),
            }
        },
        HorizontalSpan:new{ width = self.cover_spacing },
        LeftContainer:new{
            dimen = Geom:new{
                w = (self.dimen.w - 3 * self.cover_spacing) / 2,
                h = Size.item.height_default,
            },
            TextWidget:new{
                text = right_title,
                face = Font:getFace("smallinfofont", 10),
            }
        },
    }

    table.insert(self.content_container, titles_row)
    table.insert(self.content_container, VerticalSpan:new{ width = self.row_spacing })
end

function GridBrowser:createStackedColumn(items)
    local column_width = (self.dimen.w - 3 * self.cover_spacing) / 2
    local base_cover_size = {
        w = math.floor(column_width * 0.45),
        h = math.floor((column_width * 0.45) * (self.cover_size.h / self.cover_size.w)),
    }
    local column_height = math.floor(base_cover_size.h * 1.2) -- Just slightly taller than the covers

    local column = OverlapGroup:new{
        dimen = Geom:new{
            w = column_width,
            h = column_height,
        },
    }

    -- Add up to 3 books with specific positioning (3 in background, 2 in middle, 1 on top)
    local num_items = math.min(3, #items)
    for i = 3, 1, -1 do
        if i > num_items then
            -- Skip if we don't have this many items
            goto continue
        end
        local book = items[i]
        local scale_factors = {1.0, 0.94, 0.80} -- 100%, 94%, 80%
        local scale_factor = scale_factors[i]
        local cover_size = {
            w = math.floor(base_cover_size.w * scale_factor),
            h = math.floor(base_cover_size.h * scale_factor),
        }

        local x_offset, y_offset

        if i == 1 then
            -- First image: largest, on the left, bottom aligned
            x_offset = 0
            y_offset = column_height - cover_size.h
        elseif i == 2 then
            -- Second image: smaller, center aligned, bottom aligned
            x_offset = (column_width - cover_size.w) / 2
            y_offset = column_height - cover_size.h
        else -- i == 3
            -- Third image: smallest, right aligned, bottom aligned
            x_offset = column_width - cover_size.w
            y_offset = column_height - cover_size.h
        end

        -- Create cover widget without text
        local cover_widget = self:createStackedCoverWidget(book, cover_size)

        -- Wrap in a positioned container
        local positioned_widget = OverlapGroup:new{
            dimen = Geom:new{
                w = cover_size.w + x_offset,
                h = cover_size.h + y_offset,
            },
            LeftContainer:new{
                dimen = Geom:new{
                    w = cover_size.w + x_offset,
                    h = cover_size.h + y_offset,
                },
                VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ width = y_offset },
                    HorizontalGroup:new{
                        align = "top",
                        HorizontalSpan:new{ width = x_offset },
                        cover_widget,
                    }
                }
            }
        }

        table.insert(column, positioned_widget)
        ::continue::
    end

    return LeftContainer:new{
        dimen = Geom:new{
            w = column_width,
            h = column_height,
        },
        column,
    }
end

function GridBrowser:addTextLinksSection()
    -- Add MORE padding before the lines
    table.insert(self.content_container, VerticalSpan:new{ width = 100 })

    local column_width = (self.dimen.w - 3 * self.cover_spacing) / 2

    -- Create horizontal lines for each column
    local left_line = LineWidget:new{
        dimen = Geom:new{
            w = column_width,
            h = Size.border.thin,
        }
    }

    local right_line = LineWidget:new{
        dimen = Geom:new{
            w = column_width,
            h = Size.border.thin,
        }
    }

    local lines_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.cover_spacing },
        left_line,
        HorizontalSpan:new{ width = self.cover_spacing },
        right_line,
    }

    table.insert(self.content_container, lines_row)

    local links_row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = self.cover_spacing },
        self:createTextLink(_("Want to Read"), function()
            UIManager:show(InfoMessage:new{
                text = _("Want to Read - Coming Soon"),
            })
        end),
        HorizontalSpan:new{ width = self.cover_spacing },
        self:createTextLink(_("All Series"), function()
            UIManager:show(InfoMessage:new{
                text = _("All Series - Coming Soon"),
            })
        end),
    }

    table.insert(self.content_container, links_row)
    table.insert(self.content_container, lines_row)
    table.insert(self.content_container, VerticalSpan:new{ width = self.row_spacing })
end

function GridBrowser:createTextLink(text, callback)
    local column_width = (self.dimen.w - 3 * self.cover_spacing) / 2

    local text_widget = TextWidget:new{
        text = text,
        face = Font:getFace("smalltfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local tap_input = InputContainer:new{
        dimen = Geom:new{
            w = column_width,
            h = Size.item.height_default,
        },
        ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = column_width,
                        h = Size.item.height_default,
                    }
                }
            },
        },
        callback = callback,
    }

    function tap_input:onTap()
        self.callback()
        return true
    end

    return OverlapGroup:new{
        dimen = Geom:new{
            w = column_width,
            h = Size.item.height_default,
        },
        LeftContainer:new{
            dimen = Geom:new{
                w = column_width,
                h = Size.item.height_default,
            },
            text_widget,
        },
        tap_input,
    }
end

function GridBrowser:createBookWidget(book, cover_size)
    local cover_widget
    local image_url = book.image or book.thumbnail

    if image_url then
        logger.dbg("GridBrowser: Creating cover image for book:", book.title or book.text, "URL:", image_url)
        cover_widget = self:createCoverImage(image_url, book.title, cover_size)
    else
        logger.dbg("GridBrowser: No image found for book:", book.title or book.text, "using placeholder")
        cover_widget = self:createPlaceholderCover(book.title, cover_size)
    end

    -- Book title (truncated, smaller font)
    local title_text = book.title or book.text or _("Unknown")
    local max_chars = math.floor(cover_size.w / 8) -- Approximate character width
    if #title_text > max_chars then
        title_text = title_text:sub(1, max_chars - 3) .. "..."
    end

    local title_widget = LeftContainer:new{
        dimen = Geom:new{
            w = cover_size.w,
            h = Size.item.height_default * 0.7, -- Smaller height
        },
        TextWidget:new{
            text = title_text,
            face = Font:getFace("smallinfofont", 10), -- Smaller font
            max_width = cover_size.w,
        }
    }

    local book_container = VerticalGroup:new{
        align = "center",
        cover_widget,
        VerticalSpan:new{ width = Size.span.vertical_default }, -- Changed from Size.span.vertical_default / 2
        title_widget,
    }

    -- Make it tappable
    local tap_input = InputContainer:new{
        dimen = Geom:new{
            w = cover_size.w,
            h = cover_size.h + Size.item.height_default * 0.7 + Size.span.vertical_default, -- Updated height calculation
        },
        ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = cover_size.w,
                        h = cover_size.h + Size.item.height_default * 0.7 + Size.span.vertical_default, -- Updated height calculation
                    }
                }
            },
        },
        book_data = book,
        parent = self,
    }

    function tap_input:onTap()
        local detail_viewer = DetailViewer:new{
            book_data = self.book_data,
            catalog_manager = self.parent.catalog_manager,
            close_callback = function()
                -- Optional: refresh the grid when returning
            end,
        }
        UIManager:show(detail_viewer)
        return true
    end

    return OverlapGroup:new{
        dimen = Geom:new{
            w = cover_size.w,
            h = cover_size.h + Size.item.height_default * 0.7 + Size.span.vertical_default, -- Updated height calculation
        },
        book_container,
        tap_input,
    }
end

function GridBrowser:createStackedCoverWidget(book, cover_size)
    local cover_widget
    local image_url = book.image or book.thumbnail

    if image_url then
        logger.dbg("GridBrowser: Creating stacked cover image for book:", book.title or book.text, "URL:", image_url)
        cover_widget = self:createCoverImage(image_url, book.title, cover_size)
    else
        logger.dbg("GridBrowser: No image found for stacked book:", book.title or book.text, "using placeholder")
        cover_widget = self:createPlaceholderCover(book.title, cover_size)
    end

    -- Make it tappable (cover only, no text)
    local tap_input = InputContainer:new{
        dimen = Geom:new{
            w = cover_size.w,
            h = cover_size.h,
        },
        ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = cover_size.w,
                        h = cover_size.h,
                    }
                }
            },
        },
        book_data = book,
        parent = self,
    }

    function tap_input:onTap()
        local detail_viewer = DetailViewer:new{
            book_data = self.book_data,
            catalog_manager = self.parent.catalog_manager,
            close_callback = function()
                -- Optional: refresh the grid when returning
            end,
        }
        UIManager:show(detail_viewer)
        return true
    end

    return OverlapGroup:new{
        dimen = Geom:new{
            w = cover_size.w,
            h = cover_size.h,
        },
        cover_widget,
        tap_input,
    }
end

function GridBrowser:createCoverImage(image_url, title, cover_size)
    cover_size = cover_size or self.cover_size
    logger.dbg("GridBrowser:createCoverImage() called for:", title, "URL:", image_url)

    -- Check cache first
    if self.covers_cache[image_url] then
        logger.dbg("GridBrowser: Found cached image for:", title)
        local cached_data = self.covers_cache[image_url]

        -- Render image data - create a fresh BlitBuffer for each widget
        local bb = RenderImage:renderImageData(cached_data, #cached_data, false)

        if not bb then
            logger.warn("GridBrowser: Failed to render cached image data for:", title)
            -- Remove corrupted cache entry
            self.covers_cache[image_url] = nil
            return self:createPlaceholderCover(title, cover_size)
        end

        logger.dbg("GridBrowser: Successfully rendered image for:", title, "BB size:", bb:getWidth(), "x", bb:getHeight())

        local image_widget = ImageWidget:new{
            image = bb,
            width = cover_size.w,
            height = cover_size.h,
            scale_factor = 0, -- Let ImageWidget handle scaling
            image_disposable = true, -- ImageWidget will free the bb
        }

        return image_widget
    end

    -- Download if not cached (only start download once)
    if not self.downloading_urls[image_url] then
        self:downloadCoverImage(image_url, title)
    end

    return self:createPlaceholderCover(title, cover_size)
end

function GridBrowser:downloadCoverImage(image_url, title)
    logger.dbg("GridBrowser:downloadCoverImage() starting download for:", title, "from:", image_url)

    -- Check if already downloading
    if self.downloading_urls[image_url] then
        logger.dbg("GridBrowser: Already downloading:", image_url)
        return
    end
    self.downloading_urls[image_url] = true

    -- Use CatalogManager's downloadImage method
    local data, error_msg = self.catalog_manager:downloadImage(image_url)

    if data then
        logger.dbg("GridBrowser: Downloaded image data size for", title, ":", #data, "bytes")
        
        -- Log first few bytes to check if it's valid image data
        local first_bytes = ""
        for i = 1, math.min(16, #data) do
            first_bytes = first_bytes .. string.format("%02x ", string.byte(data, i))
        end
        logger.dbg("GridBrowser: First 16 bytes of image data for", title, ":", first_bytes)

        -- Test creating BlitBuffer from image data immediately to see if it fails
        local test_bb_ok, test_bb_err = pcall(function()
            return RenderImage:renderImageData(data, #data, false)
        end)

        if test_bb_ok and test_bb_err then
            logger.dbg("GridBrowser: Test image data rendering successful for", title)
            test_bb_err:free()

            -- Cache the image data
            self.covers_cache[image_url] = data
            logger.dbg("GridBrowser: Cached image for", title)

            -- Mark download as complete
            self.downloading_urls[image_url] = nil

            -- Rebuild content to show the new image
            UIManager:nextTick(function()
                if self.dimen then  -- Check if widget still exists
                    logger.dbg("GridBrowser: Image downloaded, rebuilding content to show new image for:", title)
                    self:buildContent()
                end
            end)
        else
            logger.err("GridBrowser: Test image data rendering failed for", title, "error:", test_bb_err or "unknown")
            self.downloading_urls[image_url] = nil
        end
    else
        logger.warn("GridBrowser: Failed to download image for", title, "error:", error_msg)
        self.downloading_urls[image_url] = nil
    end
end

function GridBrowser:createPlaceholderCover(title, cover_size)
    cover_size = cover_size or self.cover_size
    logger.dbg("GridBrowser:createPlaceholderCover() for:", title)
    local text = title and title:sub(1, 1):upper() or "?"

    return FrameContainer:new{
        width = cover_size.w,
        height = cover_size.h,
        padding = 0,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = cover_size.w,
                h = cover_size.h,
            },
            TextWidget:new{
                text = text,
                face = Font:getFace("cfont", math.floor(cover_size.h / 12)), -- Scale font with cover size
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
        }
    }
end


function GridBrowser:onClose()
    UIManager:close(self)
    if self.close_callback then
        self.close_callback()
    end
end

function GridBrowser:onShow()
    UIManager:setDirty(self, "ui")
end

return GridBrowser
