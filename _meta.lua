local I18n = require("one_reader.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    name = "one",
    fullname = _("ONE · 一个"),
    description = _([[Read the daily image, article and question from ONE (wufazhuce.com) offline in KOReader as a per-issue EPUB.]]),
    version = "0.3.0",
}
