# ONE·一个 KOReader 插件 API 文档

> **重大更新（2026-07-08）**：发现 **`v3.wufazhuce.com:8000` 官方 JSON API 完全可用**，此为首选路径。之前"只能靠 HTML 抓站"的判断作废，PC HTML 现在退居备用（当 v3 端点未来失效时兜底）。

面向 KOReader 插件开发的接口规范。基于 2026-07-08 实测。

---

## 0. 接入方式对比与选型

| 接入 | 状态 | 备注 |
|---|---|---|
| **`v3.wufazhuce.com:8000/api/*`（ONE App v3.5 API）** | **可用 ✓** | 官方 JSON，无鉴权，字段完整含日期 |
| `wufazhuce.com/`（PC HTML） | 可用 ✓ | 备用路径 |
| `api.wufazhuce.com` | DNS 无 | 不可用 |
| `m.wufazhuce.com/one` | 页面自身坏 | ajaxlist 缺 page，mixed-content |
| `app.wufazhuce.com/api/*` | 404 | 不可用 |

**选型：主用 v3 JSON API，PC HTML 作为兜底解析器保留（第 12 节）。**

**为什么优先 v3**：
- 直接 JSON，无需 HTML 正则；解析器代码量减 80%
- 每条内容自带 `hp_makettime` / `question_makettime` 字段（PC HTML 里问答/文章页无日期）
- 提供官方"按天倒序聚合流"`/api/reading/index/{offset}`，天然支持历史内容访问
- `previous_id`/`next_id` 双向链表，链式遍历稳定

---

## 1. v3 API 基本约定

**Host**：`http://v3.wufazhuce.com:8000`（**明文 HTTP，非 https**）

**必带查询参数**：`?version=3.5.0&platform=android`

**通用响应结构**：
```json
{ "res": 0, "data": <object|array|list> }
{ "res": 1, "msg": "wrong args" }        // 参数错误
{ "res": 0, "msg": "success" }           // 存在但空（404 语义）
```

**无鉴权**：无 cookie / token / referer / UA 校验。任意 UA 可用。

**注意**：
- 服务端返回的 JSON 里 URL 都是 `http://image.wufazhuce.com/...`（明文），插件里应该把图片 URL 改写为 `https://` 前访问，避免 e-reader 上的 mixed-content。
- 部分字段带控制字符（早期数据），JSON 解析时用 `strict=false` 或先清洗。

---

## 2. 三类内容 & ID 体系

| 类型 | 中文名 | 详情端点 | ID 字段 | 日期字段 |
|---|---|---|---|---|
| **hp**（图文） | 图文 | `/api/hp/detail/{id}` | `hpcontent_id` | `hp_makettime` |
| **essay**（文章） | 文章 | `/api/essay/{id}` | `content_id` | `hp_makettime` |
| **question**（问答） | 问答 | `/api/question/{id}` | `question_id` | `question_makettime` |
| serial（连载·可选） | 连载 | `/api/serialcontent/{id}` | `id` | `maketime` |

**ID 空间独立、严格递增**（不能跨类推导）。

**当前上限**（2026-07-07，VOL.5022）：
- `hpcontent_id ≈ 5147`（图文页 `hp_title="VOL.5022"`）
- `content_id ≈ 7281`（文章）
- `question_id ≈ 4656`（问答）

---

## 3. 首页 / 今日内容

### 3.1 今日推荐（essay + question + serial）

```
GET /api/reading/index/0?version=3.5.0&platform=android
```

**注意**：**必须带路径参数**（page），不能省略。`/api/reading/index/`（缺路径）会返回 `wrong args`。

**响应结构**（截取，see §7 for full）：
```json
{
  "res": 0,
  "data": [
    { "date": "2026-07-07", "items": [
        {"time": "...", "type": 1, "content": {essay 字段}},
        {"time": "...", "type": 3, "content": {question 字段}}
      ] },
    { "date": "2026-07-06", "items": [...] },
    ...  // 一次约 4-5 天
  ]
}
```

**注意**：此端点**不含图文（hp）**，图文要走 §4 / §8。

### 3.2 图文今日 & 近期

```
GET /api/hp/idlist/0?version=3.5.0&platform=android
→ { "res":0, "data":["5147","5177","5175","5165","5163","5144","5173","5175","5177","5187"] }
```

返回 10 个当前"精选"图文 id（**顺序看起来无规律，是运营挑选的推荐位**，不是简单最新 10）。要拿今日最新那张，取 `sorted(ids)[-1]` 或直接抓 `hp_makettime` 最大的。

**更稳的方法**：拿 `data` 里的 id 之一走 `/api/hp/detail/{id}` → 读 `hpcontent_id` 减 1 逐步倒推，直到 `hp_makettime` = 今天。

---

## 4. 图文详情

```
GET /api/hp/detail/{hpcontent_id}?version=3.5.0&platform=android
```

**关键字段**：
```json
{
  "hpcontent_id": "5147",
  "hp_title": "VOL.5022",               // 期号
  "hp_img_url": "http://image...",       // 图片 URL
  "hp_img_original_url": "http://...",   // 原图（高清）
  "hp_content": "如果你把无知隐藏起来…… by 雷·布拉德伯里",  // 一句话
  "hp_makettime": "2026-07-07 06:00:00", // 发布时间（关键）
  "hp_author": "摄影＆Wal_ 作品",         // 图片作者标注
  "image_authors": "Wal_",
  "text_author_name": "雷·布拉德伯里",
  "text_author_work": "from 《华氏451》",
  "text_author_desc": "...",
  "web_url": "http://m.wufazhuce.com/one/5147"
}
```

**不存在的 id**：返回 `{"res":0,"msg":"success"}`（data 缺失）。抓取时用 `data ~= nil` 判断。

---

## 5. 文章详情

```
GET /api/essay/{content_id}?version=3.5.0&platform=android
```

**关键字段**：
```json
{
  "content_id": "7281",
  "hp_title": "女杀手有一件事",
  "hp_author": "蓝天雨",
  "auth_it": "野生写手，居家厨妹。",
  "hp_author_introduce": "（责任编辑：专三千 zengkaimiao@wufazhuce.com）",
  "hp_content": "<p>…HTML 正文…</p>",     // 富文本（含 <p><br><img>）
  "hp_makettime": "2026-07-07 08:00:00",   // 关键
  "guide_word": "冷尸横陈，血已是死血。",     // 引言
  "next_id": "7282",                        // 下一篇（0 = 没有）
  "previous_id": "7280",                    // 上一篇
  "top_media_type": 0,                      // 顶部媒体类型
  "top_media_image": "http://image..."      // 顶部大图
}
```

`hp_content` 是清洁 HTML（无 script/link），可直接嵌进 EPUB 章节 xhtml。但要：
1. 图片 `<img src="http://...">` 全部改写为 `https://` 并本地化到 `images/`
2. XML 转义引号（已 escape 过一层，但 XHTML 里再确认一次）

---

## 6. 问答详情

```
GET /api/question/{question_id}?version=3.5.0&platform=android
```

**关键字段**：
```json
{
  "question_id": "4656",
  "question_title": "囤积癖会摧毁日常生活吗？",
  "question_content": "囤积癖会摧毁日常生活吗？",
  "answer_content": "<div class=\"one-img-container...\">…HTML…</div>",  // 富文本
  "question_makettime": "2026-07-07 08:00:00",
  "guide_word": "他们畏惧失去，害怕变数。",
  "next_id": 0,          // 0 = 最新
  "previous_id": "4655",
  "answerer": { user_name, desc, ... },
  "asker": { user_name, ... }
}
```

`answer_content` 已是清洁 HTML，处理方式与 essay 一致。

---

## 7. 按日期倒序分页（历史内容访问的正解）⭐

```
GET /api/reading/index/{page}?version=3.5.0&platform=android
```

**重要：path 参数是"分页游标"，不是"距今天数"。** 每页固定返回 **1 到 5 天** 的数据（大多 5 天，偶尔 1-4 天，取决于该时段真实更新数）。

**响应结构**：
```json
{
  "res": 0,
  "data": [
    {
      "date": "2026-07-07",
      "items": [
        { "time": "...", "type": 1, "content": { essay 完整字段 } },
        { "time": "...", "type": 3, "content": { question 完整字段 } }
      ]
    },
    { "date": "2026-07-06", "items": [ ... ] },
    ...
  ]
}
```

**type 枚举**：

- `1` = essay（文章）
- `2` = serial（连载章节，偶尔出现，可跳过）
- `3` = question（问答）
- **无图文 hp**（图文要单独 §4 / §8）

**实测样本**（今天 2026-07-07，一天一页递进大约 4.6 天）：

| page | first_date | last_date | days |
|---:|---|---|---:|
| 0 | 2026-07-07 | 2026-07-03 | 5 |
| 1 | 2026-07-02 | 2026-06-29 | 4 |
| 50 | 2025-10-30 | 2025-10-26 | 5 |
| 100 | 2025-02-22 | 2025-02-18 | 5 |
| 200 | 2023-10-11 | 2023-10-07 | 5 |
| 400 | 2021-01-14 | 2021-01-10 | 5 |
| 730 | 2016-07-09 | 2016-07-05 | 5 |
| 1000 | 2012-10-28 | 2012-10-24 | 5 |
| 1050 | — | — | 0 |

**边界与坑**：

- 越界（page 太大）返回 `data: []`
- 早期数据（约 page 326+ 起）有零星"空页集群"：某些 page 返回 0 天但下一 page 又有数据。实测最长连续空页 ~7-15 页。**扫描算法必须容忍连续空页 ≥ 20 才判定越界**。
- 个别 page 返回 HTTP 500，重试或跳过即可。
- 服务器覆盖到 2012-10 起源。约 1000 页可全量遍历完整个 15 年的 essay + question。

**估算映射**（今天回退 N 天 → page 约 = N / 4.6，再前后微调）：

```lua
-- page ≈ (today - target).days / 4.6
-- 实践：先 page = days_diff // 5，命中若 first_date > target，则 page++；若 last_date < target，则 page--
```

---

## 8. 图文（hp）历史访问

图文**不在** `/api/reading/index`。三种历史访问方式：

### 8.1 精选列表分页

```
GET /api/hp/idlist/{offset}?version=3.5.0&platform=android
```

**offset 语义**：**返回 id 小于 offset 且最近的 10 个精选图文 id**（近似"page marker"）。

实测：
- `offset=5147` → `[5187, 5177, 5175, 5173, 5165, 5163, 5161, 5157, 5155, 5144]`
- `offset=5144` → 下一页
- `offset=5000` → `[5048, 5038, ... 5009]`
- `offset=100` → `[99, 98, ... 90]`

**注意**：返回的 id 是"运营精选"，**不是全部**。要拿到某天的图文，最好用 §8.2。

### 8.2 按日期定位图文（推荐）

**规律**：`hp_title = "VOL.N"`，VOL.1 = 2012-10-08，每日 +1，无中断。
所以 `VOL_target = 1 + (target_date - 2012-10-08).days`。

但 `hpcontent_id ≠ VOL`：有跳号（~3%）、早期 offset 大（VOL.8 → id=14 → offset 6，VOL.5022 → id=5147 → offset 125）。

**锚点表**（实测于 2026-07-08）：

| hpcontent_id | hp_title | hp_makettime | 累积 offset |
|---:|---|---|---:|
| 14 | VOL.8 | 2012-10-14 22:00:00 | +6 |
| 15 | VOL.9 | 2012-10-15 22:00:00 | +6 |
| 20 | VOL.14 | 2012-10-20 22:00:00 | +6 |
| 30 | VOL.24 | 2012-10-30 22:00:00 | +6 |
| 50 | VOL.44 | 2012-11-19 22:00:00 | +6 |
| 100 | VOL.86 | 2012-12-31 22:00:00 | +14 |
| 500 | VOL.486 | 2014-02-04 22:00:00 | +14 |
| 1000 | VOL.980 | 2015-06-13 22:00:00 | +20 |
| 2000 | VOL.1970 | 2018-02-27 06:00:00 | +30 |
| 3000 | VOL.2958 | 2020-11-11 06:00:00 | +42 |
| 5000 | VOL.4876 | 2026-02-11 06:00:00 | +124 |
| 5147 | VOL.5022 | 2026-07-07 06:00:00 | +125 |

**算法**（parse-and-adjust）：

```lua
function find_hpcontent_id_by_date(target_date)
    -- step 1: 用锚点表插值猜 id
    local guess = interpolate_id_from_date(target_date, ANCHORS)
    -- step 2: 探测微调，每次比对 hp_makettime，最多 5 次
    for attempt = 1, 5 do
        local d = get_hp_detail(guess)
        if not d then guess = guess + 1; goto continue end   -- 跳号
        local diff = day_diff(target_date, parse_date(d.hp_makettime))
        if diff == 0 then return guess, d end
        guess = guess + diff        -- 每天平均 +1.03，直接偏移
        ::continue::
    end
    return nil
end
```

**开销**：平均 2-3 次 HTTP 请求命中。

### 8.3 图文按 VOL 号定位

用户输入 VOL 号 → 计算目标日期 → 走 §8.2。

`target_date = 2012-10-08 + (VOL_N - 1) days`

---

## 9. 完整的"今日一期"抓取序列

给定今天日期，装配一本 EPUB 需要：

```
① reading/index/0        → 拿到今天的 essay + question (type=1, type=3, date=today)
② hp/idlist/0            → 拿到 10 个精选 hp id
③ hp/detail/{id_i}       → 循环拿 hp_makettime，找到今天的那张
④ 组装 EPUB(hp + essay + question)
```

**优化**：把 ② + ③ 换成"从上次记录的 hpcontent_id + 1 探测"，避免每次都跑 10 次 detail。缓存 `last_seen_hp_id`，插件里持续维护。

---

## 10. 按日期区间抓取（合集 EPUB）

给定 `[start_date, end_date]`：

```lua
function fetch_range(start_date, end_date)
    local out = {}
    -- 从估算 page 开始，容忍空页集群
    local page = math.floor(day_diff(today, end_date) / 4.6)
    local empty_streak = 0
    while page < 1200 do
        local data = get_reading_index(page)
        if #data == 0 then
            empty_streak = empty_streak + 1
            if empty_streak >= 20 then break end
            page = page + 1
        else
            empty_streak = 0
            for _, group in ipairs(data) do
                local d = parse_date(group.date)
                if d < start_date then return out end
                if d <= end_date then
                    local essay, question
                    for _, it in ipairs(group.items) do
                        if it.type == 1 and not essay then essay = it.content end
                        if it.type == 3 and not question then question = it.content end
                    end
                    -- 图文按日期反查
                    local hp_id = find_hpcontent_id_by_date(d)
                    local hp = hp_id and get_hp_detail(hp_id) or nil
                    table.insert(out, { date = d, hp = hp, essay = essay, question = question })
                end
            end
            page = page + 1
        end
    end
    return out
end
```

**开销估算**：区间 N 天 → reading/index 请求约 `N/4.6` 次 + 图文反查约 `2*N` 次 = 约 `2.2*N` 请求（含 hp 探测的 2 次/天）。

---

## 11. 缓存 & 抓取策略

1. 三类详情本地存 `koreader/cache/one/<type>_<id>.json`（永久，一个 5-30 KB）
2. 图片存 `koreader/cache/one/img/<sha256>.jpg`（LRU 200MB）
3. 生成的 EPUB 存 `koreader/settings/one/books/`
4. `hp/idlist/*` 和 `reading/index/*` 是元数据流，缓存 24h 即可
5. 网络失败 → 优先读本地缓存，标"离线"
6. 每次抓取加限流：并发 ≤ 2，间隔 ≥ 200ms（对服务端友好）

---

## 12. 兜底：PC HTML 抓站方案

当 v3 API 未来某天挂了，切换到 PC HTML 抓取。参考 `scripts/one_api_probe.py`（老版，正则从 wufazhuce.com/ 和 /one/{id} /article/{id} /question/{id} 解析）。

关键差异：
- 文章/问答 HTML 页面**无发布日期字段**，只能"跟随首页 3 元组"
- 问答页有两个同名 `cuestion-contenido` div → 按 `<hr />` 切 body 后再匹配

**首版插件不必实现，v3 挂了再补。**

---

## 13. 端点速查表

| 用途 | HTTP | 路径 | 备注 |
|---|---|---|---|
| 按天倒序历史流（essay+question+serial） | GET | `/api/reading/index/{page}?...` | page 是分页游标，非天数 |
| 图文精选 id 列表（分页） | GET | `/api/hp/idlist/{cursor}?...` | cursor 0 = 最新 10 个 |
| 图文详情 | GET | `/api/hp/detail/{hpcontent_id}?...` | 含 hp_makettime |
| 文章详情 | GET | `/api/essay/{content_id}?...` | 含 previous_id/next_id |
| 问答详情 | GET | `/api/question/{question_id}?...` | 含 previous_id/next_id |
| 连载章节详情（可选） | GET | `/api/serialcontent/{id}?...` |  |

**Base URL**：`http://v3.wufazhuce.com:8000`（**明文 HTTP，8000 端口**）

**必备查询参数**：`version=3.5.0&platform=android`（省略某项会返回 `wrong args`）

---

## 14. 首版插件抓取图 —— 精简到极致

```
「今日一期」入口
   ↓
GET /api/reading/index/0          → data[0] = 今日 date + essay + question
GET /api/hp/idlist/0              → 挑最大 id（或 hp_makettime=today 的那个）
GET /api/hp/detail/{today_hp_id}  → 得到图文
   ↓
拼 EPUB (3 章：图文/文章/问答)
   ↓
ReaderUI:showReader(epub)

「历史某天」入口
   ↓
page = (today - target).days // 5             ← 估算，非严格
GET /api/reading/index/{page}                 → 命中区间取 group.date=target
                                                → group.items 里挑 type=1/3 拿 essay+question
                                              → 未命中则 page++/-- 微调
find_hpcontent_id_by_date(target)             → 探测 2-3 次 → hp_detail
   ↓
拼 EPUB → ReaderUI:showReader
```

---

## 附录 A：Python 快速验证脚本

完整可运行版本见 **`scripts/one_v3_probe.py`**（已实测过 hp/essay/question/reading-index/hp-idlist 全部端点，含按日期反查 essay）。

用法：

```bash
python3 scripts/one_v3_probe.py                 # 抓今日一期（image+essay+question 打包）
python3 scripts/one_v3_probe.py all             # 五类端点冒烟测试
python3 scripts/one_v3_probe.py hp 5147         # 图文详情
python3 scripts/one_v3_probe.py essay 7281      # 文章详情
python3 scripts/one_v3_probe.py question 4656   # 问答详情
python3 scripts/one_v3_probe.py index 0         # reading/index 第 0 页
python3 scripts/one_v3_probe.py idlist 0        # 图文 id 列表 offset=0
python3 scripts/one_v3_probe.py find 2020-01-01 # 按日期反查 article_id
```

**运行环境**：Python 3.8+ 系统自带 stdlib，明文 HTTP 无 SSL 证书依赖。

---

### A.1 最小可用示例（去掉工程外壳）

```python
import urllib.request, json

BASE = "http://v3.wufazhuce.com:8000"
QS = "?version=3.5.0&platform=android"

def get(path: str) -> dict:
    with urllib.request.urlopen(BASE + path + QS, timeout=15) as r:
        return json.loads(r.read())

# 今日的 essay + question（reading/index/0 第一天）
today = get("/api/reading/index/0")["data"][0]
print("today =", today["date"])
for it in today["items"]:
    c = it["content"]
    if it["type"] == 1:
        print("  essay  id =", c["content_id"], "title =", c["hp_title"])
    elif it["type"] == 3:
        print("  question id =", c["question_id"], "title =", c["question_title"])

# 今日图文（最新 hp id 通常是 idlist[0]）
hp_id = get("/api/hp/idlist/0")["data"][0]
hp = get(f"/api/hp/detail/{hp_id}")["data"]
print("hp:", hp["hp_title"], hp["hp_makettime"], "→", hp["hp_img_url"])
```

---

### A.2 按日期反查文章（page 估算 + 微调）

```python
import urllib.request, json, time
from datetime import date

BASE, QS = "http://v3.wufazhuce.com:8000", "?version=3.5.0&platform=android"

def get(path):
    with urllib.request.urlopen(BASE + path + QS, timeout=15) as r:
        return json.loads(r.read())

def find_essay_by_date(target: str) -> int:
    """target='YYYY-MM-DD'，返回 article_id 或 0。"""
    y, m, d = map(int, target.split("-"))
    days_diff = (date.today() - date(y, m, d)).days
    if days_diff < 0: return 0
    page = max(0, days_diff // 5 - 2)   # 估算：约 4.6 天/页
    empty_streak = 0
    while page < 1200:
        try:
            data = get(f"/api/reading/index/{page}").get("data") or []
        except Exception:
            data = []                    # 个别页 500 / timeout，按空处理
        if not data:
            empty_streak += 1
            if empty_streak >= 20: return 0    # 早期数据有 7-15 连空页
            page += 1; time.sleep(0.15); continue
        empty_streak = 0
        first, last = data[0]["date"], data[-1]["date"]
        if last <= target <= first:
            for day in data:
                if day["date"] == target:
                    for it in day["items"]:
                        if it["type"] == 1:
                            return int(it["content"]["content_id"])
                    return 0             # 该日期无 essay
            return 0
        if first < target:               # 估算过深
            page = max(0, page - 5); continue
        page += 1; time.sleep(0.15)      # 目标更早
    return 0

# 实测
aid = find_essay_by_date("2020-01-01")
print("2020-01-01 →", aid)                          # → 4143
print(get(f"/api/essay/{aid}")["data"]["hp_makettime"])  # → 2020-01-01 08:00:00
```

---

### A.3 双向链表遍历

```python
# 从今天最新一篇往回一路读到底
aid = 7281
while aid and aid != 0:
    d = get(f"/api/essay/{aid}")["data"]
    print(d["hp_makettime"], aid, d["hp_title"])
    aid = int(d["previous_id"] or 0)
```

---

### A.4 图文按日期反查（parse-and-adjust）

```python
from datetime import datetime

def find_hp_by_date(target: str) -> int:
    """图文没有 date→id 索引接口，用锚点插值+探测。
    若目标日期当天无图文（约 3% 跳号），返回最接近的一个。"""
    # 锚点表（image_id, hp_makettime）— 与 §8.2 一致
    anchors = [
        (14, "2012-10-14"), (100, "2012-12-31"), (500, "2014-02-04"),
        (1000, "2015-06-13"), (2000, "2018-02-27"), (3000, "2020-11-11"),
        (5000, "2026-02-11"), (5147, "2026-07-07"),
    ]
    tgt = datetime.strptime(target, "%Y-%m-%d").date()
    guess = None
    for i in range(len(anchors) - 1):
        a_id, a_d = anchors[i]
        b_id, b_d = anchors[i + 1]
        a_date = datetime.strptime(a_d, "%Y-%m-%d").date()
        b_date = datetime.strptime(b_d, "%Y-%m-%d").date()
        if a_date <= tgt <= b_date:
            ratio = (tgt - a_date).days / max(1, (b_date - a_date).days)
            guess = int(a_id + ratio * (b_id - a_id))
            break
    if guess is None:
        return 0

    seen = {}
    best_id, best_diff = 0, 10**9
    for _ in range(8):
        d = get(f"/api/hp/detail/{guess}").get("data")
        if not d:            # 跳号
            guess += 1; continue
        got = datetime.strptime(d["hp_makettime"][:10], "%Y-%m-%d").date()
        diff = (tgt - got).days
        if diff == 0:
            return guess
        if abs(diff) < best_diff:
            best_id, best_diff = guess, abs(diff)
        if guess in seen:    # 探测已震荡 → 返回当前最优近邻
            return best_id if best_diff <= 1 else 0
        seen[guess] = diff
        guess += diff        # 平均每天 image_id +1，向 target 方向偏移
    return best_id if best_diff <= 1 else 0
```

**实测**：

- 目标当天有图文 → 1-3 次探测命中（如 2013-01-01 → id 101）
- 目标当天跳号（无图文）→ 算法震荡到邻近日期并返回最接近的 id（比如 2020-01-01 若无图文，则返回 id=2681 对应 2019-12-31，diff=1）
