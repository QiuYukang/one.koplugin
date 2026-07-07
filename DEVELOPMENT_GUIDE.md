# one.koplugin 开发指南

面向 AI Agent 的完整开发说明。读完本文件 + `docs/one-api-reference.md` + `design/mockup.html` 后，应能独立完成插件开发。

---

## 1. 项目目标

KOReader 插件 `one.koplugin`：在 e-ink 阅读器上离线阅读「ONE·一个」（wufazhuce.com）每日更新的**图文 / 文章 / 问答**三类内容。

**核心策略**：每期动态生成一本 EPUB（三章 TOC），用 `ReaderUI:showReader()` 打开 → 直接享受 KOReader 全套阅读能力（字体/字号/夜间/朗读/词典/高亮/笔记/阅读进度/KOSync）。

**为什么走 EPUB 而不是自绘 UI**：KOReader 菜单只能显示列表条目，无法自绘富文本内容页。所有 InfoMessage/TextViewer 都撑不住图文混排。EPUB 是唯一能拿到完整阅读体验的路径。

---

## 2. 目录结构（按此布局实现）

```
one.koplugin/
├── _meta.lua               插件元信息（KOReader 插件规范必需）
├── main.lua                入口：UI 菜单、业务编排（预计 800-1200 行）
├── config.example.lua      配置模板（可选，若需常量集中管理）
├── lib/
│   ├── client.lua          HTTP 抓取（socket.http；v3 端点为纯 HTTP，不需 ssl.https）
│   ├── parser.lua          JSON 解析 + HTML 清洗（essay/question 的 hp_content 是 HTML）
│   ├── epub_builder.lua    EPUB 组装（zlib + 手写 zip writer；mimetype 首个且 STORE）
│   ├── image_cache.lua     图片下载 + LRU 缓存
│   ├── date_index.lua      image_id ↔ VOL ↔ date 换算（锚点插值 + parse-adjust）
│   ├── settings.lua        设置持久化（LuaSettings 封装）
│   ├── cleanup.lua         启动自动清理逻辑
│   └── i18n.lua            中文翻译字典 + _() 包装
├── scripts/
│   ├── one_v3_probe.py     ⭐ v3 JSON API 参考实现（首选，对拍 Lua 客户端）
│   └── one_api_probe.py    PC HTML 抓站参考实现（备用，v3 挂了才用）
├── docs/
│   └── one-api-reference.md   接口文档（v3 JSON API 为主，HTML 兜底）
├── design/
│   └── mockup.html         交互设计 mockup v3（UI 参照物）
└── DEVELOPMENT_GUIDE.md    本文件
```

---

## 3. 语言与约定

- 代码/变量名/注释/commit message：**English**
- 用户可见文案：`_()` 包裹，中文翻译放 `lib/i18n.lua` 的 zh 表
- 与开发者/用户沟通：**简体中文**
- 循环变量用 `_i` 而非 `_`（`_` 是翻译函数）
- Lua 5.1 语法（KOReader 用 LuaJIT）

---

## 4. 关键实现路径（按优先级）

### 4.1 Milestone 1：能打开今日一期（MVP）

按顺序完成：

1. **`lib/client.lua`**：`http_get(url, timeout)` 封装 `socket.http.request`，返回 `body, status`。v3 端点全部走明文 HTTP:8000，**不需要 ssl.https**（HTML 兜底才需要）
2. **`lib/parser.lua`**：JSON 反序列化（用 KOReader 内置 `rapidjson` 或 `cjson`）+ HTML 清洗器（essay/question 的 `hp_content`/`answer_content` 是干净 HTML，只需图片本地化）。对拍见 `scripts/one_v3_probe.py`
3. **`lib/image_cache.lua`**：`get(url)` → 本地路径。文件名 = `sha256(url).jpg`（sha256 可从 crypto 库或自实现），落到 `<data_dir>/one/img/`
4. **`lib/epub_builder.lua`**：核心，见下节
5. **`main.lua`** 骨架：注册 tools 菜单 → 「今日一期」→ 抓 index → 抓 3 详情 → 拼 EPUB → `ReaderUI:showReader(epub_path)`

### 4.2 EPUB 组装细节（`lib/epub_builder.lua`）

**这是最容易踩坑的部分**。EPUB = zip 包 + 特定文件结构 + XML 元数据。KOReader 用 crengine 解析，容错性不算好。

**文件清单**（顺序不能错）：

```
mimetype                    # 必须首个，STORE 方式（无压缩），内容严格为 "application/epub+zip" 且无换行
META-INF/container.xml      # 指向 content.opf 位置
OEBPS/content.opf           # 元数据 + manifest + spine
OEBPS/toc.ncx               # 旧版目录（crengine 主要用这个）
OEBPS/nav.xhtml             # EPUB3 目录
OEBPS/chapter1.xhtml        # 图文
OEBPS/chapter2.xhtml        # 文章
OEBPS/chapter3.xhtml        # 问答
OEBPS/style.css             # 排版样式（简单即可）
OEBPS/images/cover.jpg
OEBPS/images/one.jpg        # 图文大图
OEBPS/images/*.jpg          # 文章/问答内嵌图（可选）
```

**Zip 打包**：不要引入第三方 zip 库。KOReader 已内置 `ffi/zlib`。手写一个最小 zip writer：

- Local file header + file data + central directory
- **mimetype 必须 STORE（method=0）且是第一个 entry**（EPUB 规范硬性要求，否则 iBooks/crengine 都可能报错）
- 其他文件用 DEFLATE（method=8）
- 参考：`weread.koplugin/lib/content.lua` 可能已有类似实现

**元数据字段**（`content.opf` 的 `<metadata>`）：

```xml
<dc:title>ONE VOL.5022 · 2026-07-07</dc:title>
<dc:creator>ONE · 一个</dc:creator>
<dc:date>2026-07-07</dc:date>       <!-- KOReader 书架按此排序 -->
<dc:identifier id="BookId">one-vol-5022</dc:identifier>
<dc:language>zh-CN</dc:language>
<meta name="cover" content="cover-image"/>
```

**章节 XHTML 模板**（chapter1.xhtml 举例）：

```html
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>图文</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
  <h1>图文</h1>
  <p class="meta">VOL.5022 · 2026-07-07</p>
  <div class="one-image"><img src="images/one.jpg" alt="图"/></div>
  <p class="cita">如果你把无知隐藏起来……</p>
</body>
</html>
```

**XML 转义**：内容里的 `< > & " '` 必须转义，否则 crengine 解析失败。写一个 `escape_xml(s)` 工具函数。

### 4.3 Milestone 2：菜单结构 + 缓存

参照 `design/mockup.html` §2 菜单树，实现：

- 今日一期 / 最近 7 天 / 按日期查看 / 已缓存内容 / 设置
- 每个菜单项对应 KOReader `Menu:new{}` 或 `sub_item_table_func`
- 首次抓取用 `Trapper:info()` 显示进度条

### 4.4 Milestone 3：历史日期查询

**v3 API 已彻底解决历史查询问题**，所有内容类型都有明确日期字段。参考实现见 **`scripts/one_v3_probe.py`**（Python 实测通过），Lua 端 `lib/date_index.lua` 照移植即可。

**推荐路径**：

- **给定任意日期 → 拿当天 essay + question**：调 `GET /api/reading/index/{page}`。**注意 path 是分页游标，不是"距今天数"**——每页返回 1-5 天。用 `page ≈ (today - target).days / 4.6` 估算起点，命中不到再前后微调 ±1。essay/question 从返回的 `items[].content` 里按 `type=1/3` 挑。
- **给定日期 → 拿图文**：`reading/index` 不含图文。用 `hp_makettime` 锚点表（12 数据点，image_id 14→5147，2012-10-14→2026-07-07）线性插值猜起点，再抓 `hp/detail` 读实际 `hp_makettime` 迭代收敛，2-3 次命中。详见 `docs/one-api-reference.md` §8.2 + 附录 A.4。
- **前后翻页**：essay/question 详情返回的 `previous_id`/`next_id` 直接给相邻期，`0` 表示尽头，无需算日期。

**限制与坑**：

- `reading/index` 在 page ≥ 326 后出现零星"空页集群"（个别 page 返回 0 天但下一 page 又有），扫描算法必须容忍连续 20 页空页才判定越界；个别页返回 500，跳过即可
- `question_id < ~4000` 返回 "wrong args"（问答系统 2018 年才上线），早期日期只能出 essay+图文，无问答
- 图文有约 3% id 跳号（内容删除），反查算法震荡时返回最近邻近期（diff ≤ 1）即可

### 4.5 Milestone 4：设置 + 缓存清理

参照 `design/mockup.html` 屏 16-22 实现。

**关键**：

- `启动时自动清理` 逻辑放在 `onDispatcherRegisterActions` 或首次进入 ONE 菜单时触发一次（不能每次 flush 触发）
- 用 lua-filetime + `lfs.attributes(path, "modification")` 判断文件年龄
- 清 img 和 EPUB，**保留 JSON 元数据**（几 KB / 期，随时可重建 EPUB）
- 完成后 `Notification:notify("已清理 X 天前缓存……")` 非阻塞提示

---

## 5. KOReader 组件对应表

Mockup 屏号 → Lua 组件：

| 屏 | 组件 | 说明 |
|----|------|------|
| 02/03/04/16/17/18/20/22 | `Menu:new{items=...}` | 主要菜单，`item.mandatory` 存右侧灰字 |
| 05 | `DateTimeWidget:new{}` | 内置日期选择器 |
| 06 | `Trapper:info(text)` | 非阻塞进度提示，可被下一次 info 覆盖 |
| 08 / 14 | crengine 自动生成 | 读取 EPUB `nav.xhtml`，无需手写 |
| 13 / 19 | `ButtonDialog` / `MultiConfirmBox` | 弹窗式选择 |
| 21 | `Notification:notify(text, timeout)` | 底部 toast，1-2 秒消失 |
| 12（书内菜单） | `Dispatcher:registerAction()` + `ReaderMenu` tools 组 | 上/下一期动作 |

**菜单挂载**：

```lua
function OnePlugin:addToMainMenu(menu_items)
    menu_items.one = {
        text = _("ONE · 一个"),
        sorting_hint = "tools",         -- 挂 Tools tab
        sub_item_table_func = function()
            return self:buildMainMenu()
        end,
    }
end
```

同时注册到 `ReaderMenu` 和 `FileManagerMenu`（书内/书架都能进）。

---

## 6. API 抓取要点（详见 `docs/one-api-reference.md`）

**首选：v3 JSON API**（ONE App v3.5 后端，无鉴权、无 UA 校验，2026-07-08 实测可用）：

- 基址 `http://v3.wufazhuce.com:8000`（HTTP 8000 端口，**不是** HTTPS 443）
- 所有请求必带 `?version=3.5.0&platform=android` 查询参数
- `GET /api/hp/detail/{image_id}` → 图文 JSON（含 `hp_makettime` 日期字段）
- `GET /api/essay/{article_id}` → 文章 JSON（含 `hp_makettime` + `previous_id`/`next_id` 双向链表）
- `GET /api/question/{question_id}` → 问答 JSON（含 `question_makettime` + `previous_id`/`next_id`）
- `GET /api/reading/index/{offset}` → 分页每日时间线，offset=距今天数，每次返回 5 天，含 essay(type=1)/question(type=3)/serial(type=2)
- `GET /api/hp/idlist/{offset}` → 10 个图文 id（offset 用作页游标）

**HTML 抓取降级**（v3 API 挂了时的后备）：

- `GET https://wufazhuce.com/` → 今日 3 ID + 近 6 期列表
- `GET https://wufazhuce.com/one/<image_id>` / `/article/<aid>` / `/question/<qid>` → 单页 HTML
- 正则解析实现见 `scripts/one_api_probe.py`

**已确认不可用**：

- `api.wufazhuce.com` / `api-v3.wufazhuce.com` — DNS 无解析
- `v3.wufazhuce.com` 走 HTTPS 443 — 端口关闭；必须走 HTTP 8000
- `m.wufazhuce.com/one` — 页面自身坏（Mixed Content + ajaxlist 缺 page 参数）

**HTTP 头**：

- JSON API：不需要任何自定义头，`socket.http.request(url)` 直连即可
- HTML 降级：`User-Agent: Mozilla/5.0 (compatible; one.koplugin/0.1)`，`Accept: text/html`
- 都不需要 cookie / 鉴权

**JSON 关键字段**（详见 `docs/one-api-reference.md` §3-6）：

- 图文 `data.hp_makettime`（"YYYY-MM-DD HH:MM:SS"）、`hp_title`（"VOL.N"）、`hp_img_url`（大图）、`hp_content`（纯文字文案）
- 文章 `data.hp_makettime`、`hp_title`、`hp_content`（干净 HTML，可直接塞 EPUB 章节）
- 问答 `data.question_makettime`、`question_title`、`answer_content`（干净 HTML）

**对拍**：Lua 客户端实现完成后，用同一个 id 对比 JSON 与 `scripts/one_api_probe.py` HTML 结果，正文字段应一致。

---

## 7. Python 参考脚本用法

**v3 JSON API 参考实现** —— 首选，实测通过：

```bash
python3 scripts/one_v3_probe.py                 # 抓今日一期（image+essay+question）
python3 scripts/one_v3_probe.py all             # 五类端点冒烟测试
python3 scripts/one_v3_probe.py hp 5147         # 图文详情
python3 scripts/one_v3_probe.py essay 7281      # 文章详情
python3 scripts/one_v3_probe.py question 4656   # 问答详情
python3 scripts/one_v3_probe.py index 0         # reading/index 第 0 页
python3 scripts/one_v3_probe.py idlist 0        # 图文 id 列表 offset=0
python3 scripts/one_v3_probe.py find 2020-01-01 # 按日期反查 article_id
```

依赖：Python 3.8+ 系统 stdlib，**明文 HTTP 无 SSL 证书问题**，macOS 系统 python 直接跑即可。

**HTML 兜底参考实现**（v3 挂了才用）：

```bash
/opt/homebrew/bin/python3 scripts/one_api_probe.py         # 抓今日
/opt/homebrew/bin/python3 scripts/one_api_probe.py 5147    # 抓指定 image_id
```

结果写 `/tmp/one_api_probe_result.json`。**macOS 系统 Python 3.8 SSL 证书问题**，必须用 homebrew python3。

---

## 8. 关键坑点清单

按踩坑概率排序：

1. **EPUB mimetype 必须首个 + STORE（method=0）**：否则 crengine 打开报错。手写 zip 时先写 mimetype，再写其他 DEFLATE 文件。
2. **XML 特殊字符转义**：正文里的 `& < > "` 不转义 → 整个 EPUB 打不开。
3. **问答页解析陷阱**：同 class 名的两个 div 破坏了非贪婪匹配。按 `<hr />` 切 body 再各自贪婪匹配。见 `scripts/one_api_probe.py` `parse_question()`。
4. **Lua 循环变量**：`for _i, item in ipairs()` 不能用 `_`，会覆盖翻译函数。
5. **图片 URL 混合内容**：ONE 的 img src 可能是 http，写 EPUB 前必须改写为 https，否则 crengine 拒绝加载。
6. **KOReader UIManager**：不能在 UI 线程里长时间阻塞。抓 3 个页面 + 下载图片必须放在 `Trapper` 协程或 `NetworkMgr:runWhenOnline` 回调里。
7. **image_id 有跳号**：约 3% 的 id 是 404（内容删除）。日期反查算法必须能容错跳过 404，向前/后扩展搜索。
8. **question_id 最小约 4000**：更早 id 返回 "wrong args"，问答系统上线时间晚于图文/文章（约 2018 年）。做历史合集时对早期日期只出图文+文章，不出问答。
9. **KOReader 菜单不能自绘富文本**：所有内容页必须走 EPUB。别想着用 InfoMessage 塞图文。
10. **`Menu:new` 的 mandatory 长度**：过长会被截断，设置里数字副标题保持简短（"34 MB"、"128 期"）。

---

## 9. 开发流程建议

1. 先跑 `scripts/one_v3_probe.py all`，看输出，理解 v3 JSON 结构
2. 从 `lib/parser.lua` 开始，写 Lua 端解析器，对拍 Python 结果
3. 写 `lib/epub_builder.lua`，先手工造一份最小 EPUB，用 KOReader 打开验证格式正确
4. 拼 `main.lua` 骨架，实现「今日一期」端到端 → 这是 MVP
5. 逐个添加：最近 7 天 → 按日期查看 → 缓存管理 → 合集 EPUB
6. 每完成一个 milestone，用 `weread.koplugin` 的运行方式装到真机跑一次

---

## 10. 隐私与合规

- 不 log 用户 IP、UA 之外的信息
- 不上传任何用户行为数据
- 抓取加限流：同一秒内不超过 3 个请求，间隔至少 200ms
- 图片 / EPUB 缓存全在本地，插件删除时可选清空

---

## 11. 后续可扩展方向（非首版）

- 评论抓取（网站评论是第三方 JS 挂件，HTML 拿不到；需研究该挂件的独立接口）
- 定时后台预取明日内容（KOReader 有 scheduler，但耗电风险）
- KOSync 同步阅读进度（EPUB 本身已支持）
- 导出到 Wallabag / Instapaper（复用 KOReader News downloader 模式）

---

## 12. 参考仓库

- `weread.koplugin`（同作者）
  - 目录布局、i18n、settings、network 模式全部可直接借鉴
  - **重点参考**：`lib/i18n.lua`, `lib/settings.lua`, `main.lua` 的菜单注册和 `runNetworkAction` 模式
- KOReader 源码：`https://github.com/koreader/koreader` → `frontend/ui/widget/`
- KOReader 用户手册：`https://koreader.rocks/user_guide/`
- Menu widget 源码：`frontend/ui/widget/menu.lua`（决定 UI 长啥样）
