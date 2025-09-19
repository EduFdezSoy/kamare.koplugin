local OPDSClient = require("opdsclient")
local url = require("socket.url")
local util = require("util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")

local CatalogManager = {}

CatalogManager.acquisition_rel = "^http://opds%-spec%.org/acquisition"
CatalogManager.borrow_rel = "http://opds-spec.org/acquisition/borrow"
CatalogManager.stream_rel = "http://vaemendis.net/opds-pse/stream"
CatalogManager.facet_rel = "http://opds-spec.org/facet"
CatalogManager.image_rel = {
    ["http://opds-spec.org/image"] = true,
    ["http://opds-spec.org/cover"] = true, -- ManyBooks.net, not in spec
    ["x-stanza-cover-image"] = true,
}
CatalogManager.thumbnail_rel = {
    ["http://opds-spec.org/image/thumbnail"] = true,
    ["http://opds-spec.org/thumbnail"] = true, -- ManyBooks.net, not in spec
    ["x-stanza-cover-image-thumbnail"] = true,
}

-- Special feed identifiers for Kavita OPDS server
CatalogManager.special_feeds = {
    on_deck = "onDeck",
    recently_updated = "recentlyUpdated",
    recently_added = "recentlyAdded",
    reading_lists = "readingList",
    want_to_read = "wantToRead",
    all_libraries = "allLibraries",
    all_collections = "allCollections",
}

function CatalogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.client = OPDSClient:new()
    return o
end

-- Generates catalog item table and processes OPDS facets/search links
function CatalogManager:genItemTableFromCatalog(catalog, item_url)
    local item_table = {}
    local facet_groups = nil
    local search_url = nil

    if not catalog then
        return item_table, facet_groups, search_url
    end

    local feed = catalog.feed or catalog
    facet_groups = {} -- Initialize table to store facet groups

    local function build_href(href)
        return url.absolute(item_url, href)
    end

    local has_opensearch = false
    local hrefs = {}
    if feed.link then
        for __, link in ipairs(feed.link) do
            if link.type ~= nil and link.rel and link.href then
                local link_href = build_href(link.href)
                
                -- Always add the link to hrefs if it has a rel and href
                -- Navigation links (prev, next, start, first, last) take priority
                -- and won't be overwritten by later processing of the same rel
                if not hrefs[link.rel] then
                    hrefs[link.rel] = link_href
                end
                
                -- OpenSearch
                if link.type:find(self.client.search_type) then
                    if link.href then
                        search_url = build_href(self.client:getSearchTemplate(build_href(link.href)))
                        has_opensearch = true
                    end
                end
                -- Calibre search (also matches the actual template for OpenSearch!)
                if link.type:find(self.client.search_template_type) and link.rel and link.rel:find("search") then
                    if link.href and not has_opensearch then
                        search_url = build_href(link.href:gsub("{searchTerms}", "%%s"))
                    end
                end
                -- Process OPDS facets
                if link.rel == self.facet_rel then
                    local group_name = link["opds:facetGroup"] or _("Filters")
                    if not facet_groups[group_name] then
                        facet_groups[group_name] = {}
                    end
                    table.insert(facet_groups[group_name], link)
                end
            end
        end
    end
    item_table.hrefs = hrefs

    for __, entry in ipairs(feed.entry or {}) do
        local item = {}
        item.acquisitions = {}
        if entry.link then
            for ___, link in ipairs(entry.link) do
                local link_href = build_href(link.href)
                if link.type and link.type:find(self.client.catalog_type)
                    and (not link.rel
                    or link.rel == "subsection"
                    or link.rel == "http://opds-spec.org/subsection"
                    or link.rel == "http://opds-spec.org/sort/popular"
                    or link.rel == "http://opds-spec.org/sort/new") then
                    item.url = link_href
                end
                -- Process streaming and display links only
                if link.rel or link.title then
                    if link.rel == self.stream_rel then
                        -- https://vaemendis.net/opds-pse/
                        -- «count» MUST provide the number of pages of the document
                        -- namespace may be not "pse"
                        local count, last_read
                        for k, v in pairs(link) do
                            if k:sub(-6) == ":count" then
                                count = tonumber(v)
                            elseif k:sub(-9) == ":lastRead" then
                                last_read = tonumber(v)
                            end
                        end
                        if count then
                            table.insert(item.acquisitions, {
                                type  = link.type,
                                href  = link_href,
                                title = link.title,
                                count = count,
                                last_read = last_read and last_read > 0 and last_read or nil
                            })
                        end
                    elseif self.thumbnail_rel[link.rel] then
                        item.thumbnail = link_href
                    elseif self.image_rel[link.rel] then
                        item.image = link_href
                    end
                end
            end
        end
        local title = _("Unknown")
        if type(entry.title) == "string" then
            title = entry.title
        elseif type(entry.title) == "table" then
            if type(entry.title.type) == "string" and entry.title.div ~= "" then
                title = entry.title.div
            end
        end
        item.text = title
        local author = _("")
        if type(entry.author) == "table" and entry.author.name then
            author = entry.author.name
            if type(author) == "table" then
                if #author > 0 then
                    author = table.concat(author, ", ")
                else
                    -- we may get an empty table on https://gallica.bnf.fr/opds
                    author = nil
                end
            end
        end
        item.text = title  -- Just use the title, author will be shown as subtitle
        item.title = title
        item.author = author
        item.content = entry.content or entry.summary

        -- Add type determination and reading status
        local has_streaming = false
        local reading_status = nil  -- nil = read, "unread", "started"

        for _, acquisition in ipairs(item.acquisitions) do
            if acquisition.count then
                has_streaming = true
                -- Determine reading status
                if not acquisition.last_read or acquisition.last_read == 0 then
                    reading_status = "unread"
                elseif acquisition.last_read > 0 and acquisition.last_read < acquisition.count then
                    reading_status = "started"
                else
                    reading_status = nil  -- read (completed)
                end
                break
            end
        end

        item.type = has_streaming and "stream" or "normal"

        -- Set symbol based on reading status
        if reading_status == "unread" then
            item.mandatory = "●"
        elseif reading_status == "started" then
            item.mandatory = "◒"
        end
        -- No symbol for read status

        table.insert(item_table, item)
    end

    if next(facet_groups) == nil then facet_groups = nil end -- Clear if empty

    return item_table, facet_groups, search_url
end

-- Generates menu items from the fetched list of catalog entries
function CatalogManager:genItemTableFromURL(item_url, username, password)
    local all_items = {}
    local current_url = item_url
    local facet_groups, search_url, opensearch_data
    local page_count = 0
    
    while current_url do
        page_count = page_count + 1
        
        local ok, catalog = pcall(self.client.parseFeed, self.client, current_url, username, password)
        if not ok then
            if page_count == 1 then -- Only return error if first page fails
                return nil, catalog
            end
            break
        end
        if not catalog then
            if page_count == 1 then -- Only return error if first page fails
                return nil, "Failed to parse catalog"
            end
            break
        end
        
        local page_items, page_facets, page_search = self:genItemTableFromCatalog(catalog, current_url)
        
        -- Store metadata from first page only
        if not facet_groups then
            facet_groups = page_facets
            search_url = page_search
            if catalog.opensearch then
                opensearch_data = catalog.opensearch
            end
        end
        
        -- Add items from this page
        for _, item in ipairs(page_items) do
            table.insert(all_items, item)
        end
        
        -- Check for next page link
        local next_url = page_items.hrefs and page_items.hrefs.next or nil
        if next_url and next_url ~= current_url then
            current_url = next_url
        else
            current_url = nil
        end
        
        -- Safety limit to prevent infinite loops
        if page_count > 50 then
            logger.warn("CatalogManager:genItemTableFromURL - Reached safety limit of 50 pages")
            break
        end
    end
    
    return all_items, facet_groups, search_url, nil, opensearch_data
end

-- Extracts special feed URLs from root catalog
function CatalogManager:extractSpecialFeeds(catalog, base_url)
    local special_urls = {}

    if not catalog or not catalog.feed or not catalog.feed.entry then
        return special_urls
    end

    local function build_href(href)
        return url.absolute(base_url, href)
    end

    for _, entry in ipairs(catalog.feed.entry) do
        local entry_id = entry.id
        if entry_id and entry.link then
            for _, link in ipairs(entry.link) do
                if link.rel == "subsection" and link.href then
                    -- Map entry IDs to special feed types
                    for feed_type, feed_id in pairs(self.special_feeds) do
                        if entry_id == feed_id then
                            special_urls[feed_type] = build_href(link.href)
                            break
                        end
                    end
                end
            end
        end
    end

    return special_urls
end

-- Helper function to get a specific special feed
function CatalogManager:getSpecialFeed(feed_type, root_url, username, password)
    -- First get the root catalog to extract special feed URLs
    local ok, catalog = pcall(self.client.parseFeed, self.client, root_url, username, password)
    if not ok then
        return nil, catalog -- return error as second value
    end

    local special_urls = self:extractSpecialFeeds(catalog, root_url)
    local feed_url = special_urls[feed_type]

    if not feed_url then
        return nil, _("Special feed not found")
    end

    -- Now fetch the actual special feed
    return self:genItemTableFromURL(feed_url, username, password)
end

-- Convenience functions for specific feeds
function CatalogManager:getOnDeck(root_url, username, password)
    return self:getSpecialFeed("on_deck", root_url, username, password)
end

function CatalogManager:getRecentlyAdded(root_url, username, password)
    return self:getSpecialFeed("recently_added", root_url, username, password)
end

function CatalogManager:getRecentlyUpdated(root_url, username, password)
    return self:getSpecialFeed("recently_updated", root_url, username, password)
end

function CatalogManager:getReadingLists(root_url, username, password)
    return self:getSpecialFeed("reading_lists", root_url, username, password)
end

function CatalogManager:getWantToRead(root_url, username, password)
    return self:getSpecialFeed("want_to_read", root_url, username, password)
end

function CatalogManager:getAllLibraries(root_url, username, password)
    return self:getSpecialFeed("all_libraries", root_url, username, password)
end

function CatalogManager:getAllCollections(root_url, username, password)
    return self:getSpecialFeed("all_collections", root_url, username, password)
end

-- Downloads an image from the given URL using the configured authentication
function CatalogManager:downloadImage(image_url)
    local parsed = url.parse(image_url)
    if not parsed then
        return nil, "Invalid URL"
    end

    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil, "Unsupported URL scheme"
    end

    local image_data = {}
    local code, headers, status

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    code, headers, status = socket.skip(1, http.request {
        url = image_url,
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader/1.0",
            ["Accept"] = "image/*",
        },
        sink = ltn12.sink.table(image_data),
        user = self.username,
        password = self.password,
    })
    socketutil:reset_timeout()

    if code == 200 and image_data and #image_data > 0 then
        return table.concat(image_data)
    else
        return nil, "HTTP request failed with code: " .. tostring(code)
    end
end

return CatalogManager
