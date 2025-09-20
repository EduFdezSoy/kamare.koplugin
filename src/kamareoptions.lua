local _ = require("gettext")

local KamareOptions = {
    prefix = "kamare",
    {
        icon = "appbar.settings",
        options = {
            {
                name = "footer_mode",
                name_text = _("Footer Display"),
                toggle = {_("Off"), _("Progress"), _("Pages left"), _("Time")},
                values = {0, 1, 2, 3},
                args = {0, 1, 2, 3},
                event = "SetFooterMode",
                help_text = _("Choose what information to display in the footer."),
            }
        }
    }
}

return KamareOptions
