local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local CatalogManager = require("catalogmanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local OPDSClient = require("opdsclient")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local OPDSBrowser = Menu:extend{
    root_catalog_title    = nil,
    root_catalog_username = nil,
    root_catalog_password = nil,
    facet_groups          = nil, -- Stores OPDS facet groups

    title_shrink_font_to_fit = true,
}

function OPDSBrowser:init()
    self.catalog_manager = CatalogManager:new()

    -- Initialize paths table here to avoid nil errors
    self.paths = self.paths or {}

    -- Track if this is the initial startup of this browser instance (not navigation back)
    local is_initial_browser_startup = not self.has_initialized_before
    self.has_initialized_before = true

    -- Check if we have exactly one server and it's the initial browser startup
    if is_initial_browser_startup and self.servers and #self.servers == 1 then
        local single_server = self.servers[1]
        self.root_catalog_title = single_server.title
        self.root_catalog_username = single_server.username
        self.root_catalog_password = single_server.password

        -- First initialize the Menu normally
        self.item_table = {}
        self.catalog_title = nil
        self.title_bar_left_icon = "appbar.menu"
        self.onLeftButtonTap = function()
            -- Reset and show server list
            self.root_catalog_title = nil
            self.root_catalog_username = nil
            self.root_catalog_password = nil
            self.item_table = self:genItemTableFromRoot()
            self.catalog_title = nil
            Menu.init(self) -- Reinitialize with server list
        end
        self.facet_groups = nil
        Menu.init(self) -- Initialize Menu first

        -- Then load the server's content
        self:updateCatalog(single_server.url)

        return
    end

    -- Normal behavior for multiple servers or no servers
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showOPDSMenu()
    end
    self.facet_groups = nil
    Menu.init(self)
end

function OPDSBrowser:showOPDSMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                 text = _("Add Kavita server"),
                 callback = function()
                     UIManager:close(dialog)
                     self:addEditServer()
                 end,
                 align = "left",
             }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

-- Shows facet menu for OPDS catalogs with facets/search support
function OPDSBrowser:showFacetMenu()
    local buttons = {}
    local dialog
    local catalog_url = self.paths[#self.paths].url


    -- Add search option if available
    if self.search_url then
        table.insert(buttons, {{
                                   text = "\u{f002} " .. _("Search"),
                                   callback = function()
                                       UIManager:close(dialog)
                                       self:searchCatalog(self.search_url)
                                   end,
                                   align = "left",
                               }})
        -- table.insert(buttons, {}) -- separator
    end

    -- Add facet groups
    if self.facet_groups then
        for group_name, facets in ffiUtil.orderedPairs(self.facet_groups) do
            table.insert(buttons, {
                { text = "\u{f0b0} " .. group_name, enabled = false, align = "left" }
            })

            for __, link in ipairs(facets) do
                local facet_text = link.title
                if link["thr:count"] then
                    facet_text = T(_("%1 (%2)"), facet_text, link["thr:count"])
                end
                if link["opds:activeFacet"] == "true" then
                    facet_text = "✓ " .. facet_text
                end
                table.insert(buttons, {{
                                           text = facet_text,
                                           callback = function()
                                               UIManager:close(dialog)
                                               self:updateCatalog(url.absolute(catalog_url, link.href))
                                           end,
                                           align = "left",
                                       }})
            end
            table.insert(buttons, {}) -- separator between groups
        end
    end

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end


local function buildRootEntry(server)
    local icons = ""
    if server.username then
        icons = "\u{f2c0}"
    end
    return {
        text       = server.title,
        mandatory  = icons,
        url        = server.url,
        username   = server.username,
        password   = server.password,
        searchable = server.url and server.url:match("%%s") and true or false,
    }
end

-- Builds the root list of catalogs
function OPDSBrowser:genItemTableFromRoot()
    local item_table = {}
    if self.servers then
        for _, server in ipairs(self.servers) do
            table.insert(item_table, buildRootEntry(server))
        end
    end
    return item_table
end

-- Shows dialog to edit properties of the new/existing catalog
function OPDSBrowser:addEditServer(item)
    local fields = {
        {
            hint = _("Server name"),
        },
        {
            hint = _("Server URL"),
        },
        {
            hint = _("Username (optional)"),
        },
        {
            hint = _("Password (optional)"),
            text_type = "password",
        },
    }
    local title
    if item then
        title = _("Edit Kavita server")
        fields[1].text = item.text
        fields[2].text = item.url
        fields[3].text = item.username
        fields[4].text = item.password
    else
        title = _("Add Kavita server")
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local new_fields = dialog:getFields()
                        self:editServerFromInput(new_fields, item)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end


-- Saves catalog properties from input dialog
function OPDSBrowser:editServerFromInput(fields, item)
    local new_server = {
        title     = fields[1],
        url       = fields[2]:match("^%a+://") and fields[2] or "http://" .. fields[2],
        username  = fields[3] ~= "" and fields[3] or nil,
        password  = fields[4] ~= "" and fields[4] or nil,
    }
    local new_item = buildRootEntry(new_server)
    local new_idx, itemnumber

    -- Initialize servers table if it doesn't exist
    if not self.servers then
        self.servers = {}
    end

    if item then
        new_idx = item.idx
        itemnumber = -1
    else
        new_idx = #self.servers + 1
        itemnumber = new_idx
    end
    self.servers[new_idx] = new_server
    self.item_table[new_idx] = new_item
    self:switchItemTable(nil, self.item_table, itemnumber)
    self._manager.updated = true
end

-- Deletes catalog from the root list
function OPDSBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)
    self._manager.updated = true
end

-- Handle errors from catalog fetching
function OPDSBrowser:handleCatalogError(item_url, error_msg)
    logger.info("Cannot get catalog info from", item_url, error_msg)
    UIManager:show(InfoMessage:new{
        text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
    })
end

-- Generates menu items from the fetched list of catalog entries
function OPDSBrowser:genItemTableFromURL(item_url)
    local item_table, facet_groups, search_url, error_msg, opensearch = self.catalog_manager:genItemTableFromURL(
        item_url, self.root_catalog_username, self.root_catalog_password)

    if not item_table then
        self:handleCatalogError(item_url, error_msg)
        return {}
    end

    self.facet_groups = facet_groups
    self.search_url = search_url
    return item_table, facet_groups, search_url, error_msg, opensearch
end

-- Requests and shows updated list of catalog entries
function OPDSBrowser:updateCatalog(item_url, paths_updated)
    -- Show loading message for multi-page fetches
    local loading_msg = InfoMessage:new{
        text = _("Loading..."),
        timeout = 0,
    }
    UIManager:show(loading_msg)
    UIManager:forceRePaint()

    local menu_table, facet_groups, search_url, error_msg, opensearch = self:genItemTableFromURL(item_url)

    UIManager:close(loading_msg)

    if not menu_table then
        self:handleCatalogError(item_url, error_msg)
        return
    end

    if #menu_table > 0 or facet_groups or search_url then
        if not paths_updated then
            table.insert(self.paths, {
                url   = item_url,
                title = self.catalog_title,
                author = self.catalog_author,
            })
        end

        self.facet_groups = facet_groups
        self.search_url = search_url
        self.opensearch = opensearch

        self:switchItemTable(self.catalog_title, menu_table, nil, nil, self.catalog_author)

        -- Set appropriate title bar icon based on content
        if self.facet_groups or self.search_url then
            self:setTitleBarLeftIcon("appbar.menu")
            self.onLeftButtonTap = function()
                self:showFacetMenu()
            end
        end
    end
end

-- Requests and adds more catalog entries to fill out the page
function OPDSBrowser:appendCatalog(item_url)
    local menu_table, facet_groups, search_url = self.catalog_manager:genItemTableFromURL(
        item_url, self.root_catalog_username, self.root_catalog_password)

    if menu_table and #menu_table > 0 then
        for __, item in ipairs(menu_table) do
            table.insert(self.item_table, item)
        end
        self.item_table.hrefs = menu_table.hrefs
        self:switchItemTable(self.catalog_title, self.item_table, -1)
        return true
    end
end

-- Shows dialog to search in catalog
function OPDSBrowser:searchCatalog(item_url)
    local dialog
    dialog = InputDialog:new{
        title = _("Search Kavita catalog"),
        input_hint = _("RuriDragon"),
        description = _("Enter search terms to find manga in the catalog."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self.catalog_title = _("Search results")
                        local search_str = util.urlEncode(dialog:getInputText())
                        -- Use function replacement to avoid % being treated as capture refs
                        self:updateCatalog(item_url:gsub("%%s", function() return search_str end))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows a page number input dialog for page streaming
function OPDSBrowser:showPageNumberDialog(total_pages, callback)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter page number"),
        input_type = "number",
        input_hint = "(" .. "1 - " .. total_pages .. ")",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if callback then callback(nil) end
                    end,
                },
                {
                    text = _("Stream"),
                    is_enter_default = true,
                    callback = function()
                        local page_num = input_dialog:getInputValue()
                        UIManager:close(input_dialog)
                        if callback then callback(page_num) end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Launches the KamareImageViewer with OPDS streaming data
function OPDSBrowser:launchStreamViewer(remote_url, count, username, password, start_page, item)
    local opds_client = OPDSClient:new()
    local page_table, total_pages = opds_client:streamPages(remote_url, count, username, password)

    local KamareImageViewer = require("kamareimageviewer")
    local viewer = KamareImageViewer:new{
        images_list_data = page_table,
        title = item and item.text or "Manga",
        fullscreen = true,
        with_title_bar = false, -- We'll handle title bar manually
        image_disposable = false, -- page_table has image_disposable = true
        images_list_nb = total_pages,
        metadata = item,
        start_page = start_page or 1, -- Pass start page to constructor
        on_close_callback = function(current_page, total_pages)
            logger.dbg("Stream viewer closed - ended at page", current_page, "of", total_pages)
            -- Optional: Store last read position for resume functionality
            self.last_streamed_page = current_page
            self.last_streamed_total = total_pages

            -- Reload current catalog to update read status
            if self.paths and #self.paths > 0 then
                local current_catalog_url = self.paths[#self.paths].url
                logger.dbg("Reloading catalog from", current_catalog_url, "to update read status")
                self:updateCatalog(current_catalog_url, false)
            end
        end,
    }

    UIManager:show(viewer)
    return viewer
end

-- Shows a single cover image in KamareImageViewer
function OPDSBrowser:showCoverImage(cover_url, username, password)
    local opds_client = OPDSClient:new()
    local cover_table, total_pages = opds_client:streamPages(cover_url, 1, username, password)

    local KamareImageViewer = require("kamareimageviewer")
    local viewer = KamareImageViewer:new{
        image = cover_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- cover_table has image_disposable = true
        images_list_nb = total_pages,
        on_close_callback = function(current_page, total_pages)
            logger.dbg("Cover viewer closed - viewed page", current_page, "of", total_pages)
        end,
    }

    UIManager:show(viewer)
    return viewer
end

-- Shows dialog to stream a book
function OPDSBrowser:showStreamOptions(item)
    local acquisitions = item.acquisitions
    local buttons = {} -- buttons for ButtonDialog
    local stream_buttons -- page stream buttons

    for i, acquisition in ipairs(acquisitions) do
        if acquisition.count then
            stream_buttons = {
                {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{23EE} " .. _("Read from Start"), -- prepend BLACK LEFT-POINTING DOUBLE TRIANGLE WITH BAR
                        callback = function()
                            self:launchStreamViewer(acquisition.href, acquisition.count, self.root_catalog_username, self.root_catalog_password, 1, item)
                            UIManager:close(self.stream_dialog)
                        end,
                    },
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = _("Read from page") .. " \u{23E9}", -- append BLACK RIGHT-POINTING DOUBLE TRIANGLE
                        callback = function()
                            self:showPageNumberDialog(acquisition.count, function(page_num)
                                if page_num then
                                    self:launchStreamViewer(acquisition.href, acquisition.count, self.root_catalog_username, self.root_catalog_password, page_num, item)
                                end
                            end)
                            UIManager:close(self.stream_dialog)
                        end,
                    },
                },
            }

            if acquisition.last_read then
                table.insert(stream_buttons, {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{25B6} " .. _("Resume from page") .. " " .. acquisition.last_read, -- prepend BLACK RIGHT-POINTING TRIANGLE
                        callback = function()
                            self:launchStreamViewer(acquisition.href, acquisition.count, self.root_catalog_username, self.root_catalog_password, acquisition.last_read, item)
                            UIManager:close(self.stream_dialog)
                        end,
                    },
                })
            end
        end
    end

    if stream_buttons then
        for _, button_list in ipairs(stream_buttons) do
            table.insert(buttons, button_list)
        end
        table.insert(buttons, {}) -- separator
    end

    local cover_link = item.image or item.thumbnail
    table.insert(buttons, {
        {
            text = _("Book cover"),
            enabled = cover_link and true or false,
            callback = function()
                UIManager:close(self.stream_dialog)
                self:showCoverImage(cover_link, self.root_catalog_username, self.root_catalog_password)
            end,
        },
        {
            text = _("Book information"),
            enabled = type(item.content) == "string",
            callback = function()
                UIManager:show(TextViewer:new{
                    title = item.text,
                    title_multilines = true,
                    text = util.htmlToPlainTextIfHtml(item.content),
                    text_type = "book_info",
                })
            end,
        },
    })

    self.stream_dialog = ButtonDialog:new{
        title = item.text,
        title_multilines = true,
        buttons = buttons,
    }
    UIManager:show(self.stream_dialog)
end



-- Menu action on item tap (Stream a book / Show subcatalog / Search in catalog)
function OPDSBrowser:onMenuSelect(item)
    if item.acquisitions and item.acquisitions[1] then -- book
        logger.dbg("Stream options available:", item)
        self:showStreamOptions(item)
    else -- catalog or Search item
        if #self.paths == 0 then -- root list
            self.root_catalog_title     = item.text
            self.root_catalog_username  = item.username
            self.root_catalog_password  = item.password
        end
        local connect_callback
        if item.searchable then
            connect_callback = function()
                self:searchCatalog(item.url)
            end
        else
            self.catalog_title = item.text or self.catalog_title or self.root_catalog_title
            self.catalog_author = item.author
            connect_callback = function()
                self:updateCatalog(item.url)
            end
        end
        NetworkMgr:runWhenConnected(connect_callback)
    end
    return true
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function OPDSBrowser:onMenuHold(item)
    if #self.paths > 0 then return true end -- not root list
    local dialog
    dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete Kavita server?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                self:deleteCatalog(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditServer(item)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on previous-page chevron tap
function OPDSBrowser:onPrevPage()
    return Menu.onPrevPage(self)
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function OPDSBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        -- return to last path
        self.catalog_title = path.title
        self.catalog_author = path.author
        self:updateCatalog(path.url, true)
    else
        -- return to root path, we simply reinit opdsbrowser
        self:init()
    end
    return true
end


-- Menu action on return-arrow long-press (return to root path)
function OPDSBrowser:onHoldReturn()
    self:init()
    return true
end

-- Menu action on next-page chevron tap
function OPDSBrowser:onNextPage(fill_only)
    if fill_only then return true end
    return Menu.onNextPage(self)
end


return OPDSBrowser
