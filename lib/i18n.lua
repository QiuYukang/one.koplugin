local I18n = {}

-- Simplified-Chinese dictionary. Keys are the English source strings passed to
-- `_()`; missing keys fall back to the English text, so English is always usable.
local zh = {
    ["ONE · 一个"] = "ONE · 一个",
    ["Read the daily image, article and question from ONE (wufazhuce.com) offline in KOReader as a per-issue EPUB."] =
        "在 KOReader 中离线阅读「ONE·一个」（wufazhuce.com）每日的图文、文章与问答，每期生成一本 EPUB。",

    -- Main menu
    ["Today's issue"] = "今日一期",
    ["Recent 7 days"] = "最近 7 天",
    ["Browse by date"] = "按日期查看",
    ["Cached content"] = "已缓存内容",
    ["Settings"] = "设置",
    ["About"] = "关于",
    ["About (v%1)"] = "关于（v%1）",

    -- Chapters / content
    ["Image"] = "图文",
    ["Article"] = "文章",
    ["Question"] = "问答",
    ["Editor: %1"] = "责任编辑：%1",
    ["Author: %1"] = "作者：%1",
    ["VOL.%1"] = "VOL.%1",
    ["Untitled"] = "无标题",

    -- Fetch / progress
    ["Fetching today's issue..."] = "正在获取今日一期……",
    ["Fetching VOL.%1..."] = "正在获取 VOL.%1……",
    ["Fetching index..."] = "正在获取首页……",
    ["Fetching image..."] = "正在获取图文……",
    ["Fetching article..."] = "正在获取文章……",
    ["Fetching question..."] = "正在获取问答……",
    ["Downloading images (%1/%2)..."] = "正在下载图片（%1/%2）……",
    ["Building EPUB..."] = "正在生成 EPUB……",
    ["Fetching %1/%2..."] = "正在获取 %1/%2……",
    ["Locating date..."] = "正在定位日期……",
    ["Please wait..."] = "请稍候……",
    ["Tap to cancel"] = "点击可取消",

    -- Recent / list
    ["Combine these %1 issues into one collection"] = "把这 %1 期合成一本合集",
    ["today"] = "今日",
    ["read"] = "已读",
    ["cached"] = "已缓存",
    ["%1 days ago"] = "%1 天前",
    ["1 day ago"] = "1 天前",

    -- Browse by date
    ["Yesterday"] = "昨天",
    ["Last week"] = "上周今天",
    ["A month ago"] = "一个月前",
    ["A year ago"] = "一年前",
    ["Pick a date..."] = "输入日期…",
    ["Pick a date range..."] = "按日期区间…",
    ["Select date"] = "选择日期",
    ["Start date"] = "起始日期",
    ["End date"] = "结束日期",
    ["This date is in the future."] = "该日期在未来。",
    ["ONE started on 2012-10-07; earlier dates do not exist."] = "「ONE·一个」创刊于 2012-10-07，更早的日期不存在。",
    ["Could not locate an issue for that date."] = "无法定位该日期对应的期号。",
    ["Download %1 issues (%2)?"] = "将下载 %1 期内容（约 %2），是否继续？",
    ["Combine into one collection"] = "合成一本合集",
    ["Download and generate"] = "下载并生成",

    -- Cached
    ["%1 issues · %2"] = "%1 期 · %2",
    ["No cached content yet."] = "还没有缓存内容。",
    ["Collection"] = "合集",
    ["Delete this issue?"] = "删除这一期？",
    ["Delete"] = "删除",

    -- Settings
    ["Content settings"] = "内容设置",
    ["Cache management"] = "缓存管理",
    ["Open plugin to today's issue"] = "打开插件时默认今日一期",
    ["Image quality"] = "图片质量",
    ["Original"] = "原图",
    ["600px"] = "600px",
    ["900px"] = "900px",
    ["1080px"] = "1080px",
    ["Cache directory"] = "缓存目录",
    ["Cache directory: %1"] = "缓存目录：%1",
    ["Cache directory set to:\n%1"] = "缓存目录已设置为：\n%1",
    ["Directory is not writable."] = "目录不可写。",
    ["Auto cleanup on start"] = "启动时自动清理",
    ["Cleanup threshold"] = "清理阈值",
    ["Last auto cleanup: %1"] = "上次自动清理：%1",
    ["never"] = "从不",
    ["Run cleanup now"] = "立即执行一次",
    ["Manual cleanup..."] = "手动清理…",
    ["Keep how long?"] = "保留最近多久的缓存？",
    ["%1 days"] = "%1 天",
    ["Never clean"] = "从不清理",
    ["Custom days..."] = "自定义天数…",
    ["Clear all cache (%1)"] = "全部清空（%1）",
    ["Clear image cache (%1)"] = "清空图片缓存（%1）",
    ["Clear generated EPUBs (%1)"] = "清空生成的 EPUB（%1）",
    ["Clear everything (including JSON)"] = "清空全部（含 JSON）",
    ["Clear image cache? Generated EPUBs and metadata stay."] = "清空图片缓存？已生成的 EPUB 和元数据会保留。",
    ["Clear all generated EPUBs? They can be rebuilt from cached metadata."] = "清空所有生成的 EPUB？可从缓存的元数据重建。",
    ["Clear everything, including metadata JSON? This cannot be undone."] = "清空全部内容（含元数据 JSON）？此操作不可撤销。",
    ["Cleaned cache older than %1 days.\nRemoved %2 images, %3 EPUBs, freed %4."] =
        "已清理 %1 天前缓存。\n删除 %2 张图片、%3 本 EPUB，释放 %4。",
    ["Nothing to clean."] = "没有可清理的内容。",
    ["Cleared."] = "已清空。",

    -- About
    ["Version"] = "版本",
    ["Data source"] = "数据来源",
    ["Project home"] = "项目主页",
    ["License"] = "许可",
    ["ONE · 一个 v%1\n\nOffline reader for wufazhuce.com daily content.\nThis project is for personal learning only. Please respect ONE's terms of use and applicable laws.\n\nData source: wufazhuce.com\nLicense: MIT"] =
        "ONE · 一个 v%1\n\nwufazhuce.com 每日内容的离线阅读器。\n本项目仅供个人学习使用，请遵守「ONE·一个」的用户协议和相关法律法规。\n\n数据来源：wufazhuce.com\n许可：MIT",

    -- In-book navigation actions
    ["Next issue"] = "下一期",
    ["Previous issue"] = "上一期",
    ["Back to ONE menu"] = "返回 ONE 主菜单",
    ["This is the latest issue."] = "已经是最新一期了。",

    -- Errors
    ["No network connection. Please connect Wi-Fi and try again."] = "当前没有网络连接，请连接 Wi-Fi 后重试。",
    ["%1 failed:\n%2"] = "%1 失败：\n%2",
    ["The site structure may have changed. Please wait for a plugin update."] = "站点结构可能已改版，请等待插件更新。",
    ["No content."] = "没有内容。",
    ["Cancel"] = "取消",
    ["OK"] = "确定",
    ["Confirm"] = "确认",
}

function I18n.language()
    local lang
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language")
    end
    return lang or "en"
end

function I18n.is_zh()
    return tostring(I18n.language()):lower():match("^zh") ~= nil
end

function I18n.tr(text)
    if I18n.is_zh() then
        return zh[text] or text
    end
    return text
end

return I18n
