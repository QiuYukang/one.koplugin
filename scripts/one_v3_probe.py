#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
one_v3_probe.py — ONE·一个 v3 JSON API 官方验证脚本

数据源：http://v3.wufazhuce.com:8000  （HTTP 8000 端口，非 HTTPS 443）
所有请求必须带 ?version=3.5.0&platform=android
无鉴权、无 UA 校验、无 referer 校验

用法:
    python3 one_v3_probe.py                 # 抓今日一期（图文+文章+问答）
    python3 one_v3_probe.py hp 5147         # 抓图文详情
    python3 one_v3_probe.py essay 7281      # 抓文章详情
    python3 one_v3_probe.py question 4656   # 抓问答详情
    python3 one_v3_probe.py index 0         # 抓 reading 时间线第 0 页
    python3 one_v3_probe.py idlist 0        # 抓图文 id 列表 offset=0
    python3 one_v3_probe.py find 2020-01-01 # 按日期反查 article_id
    python3 one_v3_probe.py all             # 一次跑完所有验证

需要 Python >= 3.8。不依赖任何三方库。
"""

import json
import sys
import time
import urllib.request

BASE = "http://v3.wufazhuce.com:8000"
COMMON_QS = "?version=3.5.0&platform=android"
TIMEOUT = 15


# ------------------------- HTTP 基础 -------------------------

def _get(path: str, timeout: int = TIMEOUT) -> dict:
    """GET 一个 v3 端点，自动拼版本参数，返回解析后的 JSON dict。"""
    url = BASE + path + COMMON_QS
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    return json.loads(body)


# ------------------------- 端点封装 -------------------------

def get_hp_detail(image_id: int) -> dict:
    """图文详情。data.hp_title='VOL.N'，data.hp_makettime='YYYY-MM-DD HH:MM:SS'。"""
    return _get(f"/api/hp/detail/{image_id}")


def get_essay(article_id: int) -> dict:
    """文章详情。data.hp_content 是干净 HTML，可直接塞进 EPUB 章节。
       data.previous_id / data.next_id 用于线性翻页（0 表示尽头）。"""
    return _get(f"/api/essay/{article_id}")


def get_question(question_id: int) -> dict:
    """问答详情。data.answer_content 是干净 HTML。
       question_id < 约 4000 会返回 res!=0（问答系统 2018 年才上线）。"""
    return _get(f"/api/question/{question_id}")


def get_reading_index(page: int) -> dict:
    """按页返回若干天（4-5 天/页，不固定）的 essay/question/serial 索引。
       重要：page 是**分页游标**，不是"距今天数"。page=0 是今天起 5 天；
       page 每增 1 大约往前 4-5 天。约 page=1000 到 2012 年，page=1050 已越界。"""
    return _get(f"/api/reading/index/{page}")


def get_hp_idlist(offset: int) -> dict:
    """返回 10 个图文 id（字符串数组）。offset=0 是最新一批；
       offset 数值近似对应 image_id（内部作为游标使用）。"""
    return _get(f"/api/hp/idlist/{offset}")


# ------------------------- 组合业务 -------------------------

def get_today_bundle() -> dict:
    """一次拿到今天的 (image_id, article_id, question_id) 及三份详情。
       策略：hp/idlist/0 取最新图文 id；reading/index/0 首日拿 essay + question。"""
    idl = get_hp_idlist(0)
    if idl.get("res") != 0 or not idl.get("data"):
        raise RuntimeError(f"hp/idlist failed: {idl}")
    image_id = int(idl["data"][0])

    idx = get_reading_index(0)
    if idx.get("res") != 0 or not idx.get("data"):
        raise RuntimeError(f"reading/index failed: {idx}")
    today = idx["data"][0]  # {'date': 'YYYY-MM-DD', 'items': [...]}

    essay_id = question_id = None
    for it in today.get("items") or []:
        c = it.get("content") or {}
        t = it.get("type")
        if t == 1 and essay_id is None:
            essay_id = int(c.get("content_id"))
        elif t == 3 and question_id is None:
            question_id = int(c.get("question_id"))

    hp = get_hp_detail(image_id)
    essay = get_essay(essay_id) if essay_id else None
    question = get_question(question_id) if question_id else None
    return {
        "date": today.get("date"),
        "image_id": image_id,
        "article_id": essay_id,
        "question_id": question_id,
        "hp": hp,
        "essay": essay,
        "question": question,
    }


def _reading_page_first_date(page: int):
    try:
        d = get_reading_index(page)
        data = d.get("data") or []
        if data:
            return data[0]["date"], data[-1]["date"], data
    except Exception:
        pass
    return None, None, []


def find_essay_by_date(target_date: str) -> int:
    """按日期定位 article_id。target_date='YYYY-MM-DD'。返回 0 表示未找到。

    策略：
    1. 平均约 4.6 天/页，先按 (today - target)/4.6 估算起始 page，跳过前面几百页
    2. 在估算点附近前后微调（reading/index 有 0-15 连空页，需容忍）
    3. 命中日期区间后精确取 type==1 的 essay id
    """
    from datetime import date
    y, m, d0 = map(int, target_date.split("-"))
    days_diff = (date.today() - date(y, m, d0)).days
    if days_diff < 0:
        return 0
    est_page = max(0, days_diff // 5 - 2)  # 稍微保守往新的方向偏移

    # 从估算点开始向前（更早日期方向）扫，遇空跳，遇错跳，命中即返回
    page = est_page
    empty_streak = 0
    while page < 1200:
        first, last, data = _reading_page_first_date(page)
        if not data:
            empty_streak += 1
            if empty_streak >= 20:
                # 也许估算过大，回退到 0 从头扫（兜底，极少走到）
                if page > est_page + 20:
                    return 0
            page += 1
            time.sleep(0.15)
            continue
        empty_streak = 0
        if last <= target_date <= first:
            for day in data:
                if day["date"] == target_date:
                    for it in day.get("items") or []:
                        if it.get("type") == 1:
                            return int(it["content"]["content_id"])
                    return 0
            return 0
        if first < target_date:
            # 估算过深，往回退
            page = max(0, page - 5)
            # 二次防止死循环
            if page == 0:
                break
            time.sleep(0.15)
            continue
        # last > target_date：目标在更早，前进
        page += 1
        time.sleep(0.15)
    return 0


# ------------------------- 打印工具 -------------------------

def _brief_hp(d):
    x = (d or {}).get("data") or {}
    return {
        "hpcontent_id": x.get("hpcontent_id"),
        "hp_title": x.get("hp_title"),
        "hp_makettime": x.get("hp_makettime"),
        "hp_author": x.get("hp_author"),
        "hp_img_url": x.get("hp_img_url"),
        "hp_content": (x.get("hp_content") or "")[:80],
    }


def _brief_essay(d):
    x = (d or {}).get("data") or {}
    return {
        "content_id": x.get("content_id"),
        "hp_title": x.get("hp_title"),
        "hp_makettime": x.get("hp_makettime"),
        "hp_author": x.get("hp_author"),
        "previous_id": x.get("previous_id"),
        "next_id": x.get("next_id"),
        "hp_content_len": len(x.get("hp_content") or ""),
    }


def _brief_question(d):
    x = (d or {}).get("data") or {}
    return {
        "question_id": x.get("question_id"),
        "question_title": x.get("question_title"),
        "question_makettime": x.get("question_makettime"),
        "previous_id": x.get("previous_id"),
        "next_id": x.get("next_id"),
        "answer_content_len": len(x.get("answer_content") or ""),
    }


def _print(tag, obj):
    print(f"\n=== {tag} ===")
    print(json.dumps(obj, ensure_ascii=False, indent=2, default=str))


# ------------------------- CLI -------------------------

def main(argv):
    if not argv or argv[0] == "today":
        b = get_today_bundle()
        _print("Today bundle", {
            "date": b["date"],
            "image_id": b["image_id"],
            "article_id": b["article_id"],
            "question_id": b["question_id"],
            "hp": _brief_hp(b["hp"]),
            "essay": _brief_essay(b["essay"]),
            "question": _brief_question(b["question"]),
        })
        return

    cmd = argv[0]
    if cmd == "hp":
        _print(f"hp/detail/{argv[1]}", _brief_hp(get_hp_detail(int(argv[1]))))
    elif cmd == "essay":
        _print(f"essay/{argv[1]}", _brief_essay(get_essay(int(argv[1]))))
    elif cmd == "question":
        _print(f"question/{argv[1]}", _brief_question(get_question(int(argv[1]))))
    elif cmd == "index":
        page = int(argv[1]) if len(argv) > 1 else 0
        d = get_reading_index(page)
        summary = []
        for day in d.get("data") or []:
            row = {"date": day.get("date"), "items": []}
            for it in day.get("items") or []:
                c = it.get("content") or {}
                row["items"].append({
                    "type": it.get("type"),
                    "id": c.get("content_id") or c.get("question_id"),
                    "title": c.get("hp_title") or c.get("question_title"),
                })
            summary.append(row)
        _print(f"reading/index/{page}", summary)
    elif cmd == "idlist":
        offset = int(argv[1]) if len(argv) > 1 else 0
        d = get_hp_idlist(offset)
        _print(f"hp/idlist/{offset}", d.get("data"))
    elif cmd == "find":
        aid = find_essay_by_date(argv[1])
        _print(f"find_essay_by_date({argv[1]})", {"article_id": aid})
    elif cmd == "all":
        _print("hp/detail/5147", _brief_hp(get_hp_detail(5147))); time.sleep(0.3)
        _print("essay/7281", _brief_essay(get_essay(7281))); time.sleep(0.3)
        _print("question/4656", _brief_question(get_question(4656))); time.sleep(0.3)
        d = get_reading_index(0)
        _print("reading/index/0 dates",
               [x.get("date") for x in (d.get("data") or [])]); time.sleep(0.3)
        _print("hp/idlist/0", get_hp_idlist(0).get("data"))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
