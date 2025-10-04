local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.pageview",
        options = {
            {
                name = "scroll_mode",
                name_text = _("View Mode"),
                toggle = {_("page"), _("scroll")},
                values = {0, 1},
                default_value = 0,
                event = "SetScrollMode",
                args = {0, 1},
                help_text = _([[- 'page' mode shows only one page of the document at a time.- 'scroll' mode allows you to scroll the pages like you would in a web browser.]]),
            }
        }
    },
    {
        icon = "appbar.pagefit",
        options = {
            {
                name = "zoom_mode_type",
                name_text = _("Fit"),
                toggle = {_("full"), _("width"), _("height")},
                values = {0,1,2},
                default_value = 0,
                event = "DefineZoom",
                args = {0,1,2},
                help_text = _([[Set how the page should be resized to fit the screen.]]),
            }
        }
    },
    {
        icon = "appbar.settings",
        options = {
            {
                name = "prefetch_pages",
                name_text = _("Prefetch Pages"),
                toggle = {_("Off"), _("1"), _("2"), _("3")},
                values = {0, 1, 2, 3},
                default_value = 1,
                event = "SetPrefetchPages",
                args = {0, 1, 2, 3},
                help_text = _([[Set how many pages to prefetch when reading.]]),
            },
            {
                name = "footer_mode",
                name_text = _("Footer Display"),
                toggle = {_("Off"), _("Progress"), _("Pages left"), _("Time")},
                values = {7, 1, 2, 3},
                args = {7, 1, 2, 3},
                default_value = 1,
                event = "SetFooterMode",
                help_text = _([[Choose what information to display in the footer.]]),
            }
        }
    }
}

return KamareOptions
