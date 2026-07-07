#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
「ONE · 一个」网页站点接口回放验证脚本。

用于给 KOReader 插件预研，仅使用 stdlib (urllib + re + html)，
避免依赖 requests / bs4 —— KOReader Lua 环境里也是 socket + luasec，
先在 Python 里跑通所有正则/字段抽取，再翻译成 Lua 即可。

用法：
    python3 one_api_probe.py            # 抓最新一期
    python3 one_api_probe.py 5177       # 抓指定 VOL（图文 id）
"""

from __future__ import annotations

import html
import json
import re
import sys
import urllib.request
from typing import Any, Dict, Optional, Set


BASE = "https://wufazhuce.com"
UA = "Mozilla/5.0 (X11; Linux; KOReader) AppleWebKit/537.36"


def http_get(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read()
    # 网站声明 utf-8
    return raw.decode("utf-8", errors="replace")


# ---------- 首页：拿到当日 image_id / article_id / question_id ----------

def parse_index() -> dict:
    body = http_get(BASE + "/")
    # 首页把三类内容分别放在 /one/<id>、/article/<id>、/question/<id>
    image_ids = _uniq(re.findall(r"/one/(\d+)", body))
    article_ids = _uniq(re.findall(r"/article/(\d+)", body))
    question_ids = _uniq(re.findall(r"/question/(\d+)", body))
    return {
        "url": BASE + "/",
        "images": image_ids,
        "articles": article_ids,
        "questions": question_ids,
        "today": {
            "image_id": image_ids[0] if image_ids else None,
            "article_id": article_ids[0] if article_ids else None,
            "question_id": question_ids[0] if question_ids else None,
        },
    }


def _uniq(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ---------- 图文详情：/one/<id> ----------

def parse_image(image_id: str) -> dict:
    url = f"{BASE}/one/{image_id}"
    body = http_get(url)
    # <title>VOL.5021 - ...</title>
    vol = _search(r"<title>\s*VOL\.(\d+)", body)
    # <div class="one-imagen"><img src="..." />
    img = _search(r'class="one-imagen">\s*<img[^>]+src="([^"]+)"', body)
    # <div class="one-imagen-leyenda">摄影<br />
    category = _search(r'class="one-imagen-leyenda">\s*([^<\n]+?)\s*<', body)
    # <div class="one-cita"> 正文 </div>
    text = _search(r'class="one-cita">\s*([\s\S]*?)\s*</div>', body)
    # <p class="dom">6</p><p class="may">Jul 2026</p>
    dom = _search(r'class="dom">\s*(\d+)\s*</p>', body)
    mon = _search(r'class="may">\s*([^<]+?)\s*</p>', body)
    return {
        "endpoint": url,
        "image_id": image_id,
        "vol": vol,
        "category": _clean(category),
        "text": _clean(text),
        "image_url": img,
        "date": f"{dom} {mon}" if dom and mon else None,
    }


# ---------- 文章：/article/<id> ----------

def parse_article(article_id: str) -> dict:
    url = f"{BASE}/article/{article_id}"
    body = http_get(url)
    title = _search(r'<h2 class="articulo-titulo">\s*([\s\S]*?)\s*</h2>', body)
    author = _search(r'<p class="articulo-autor">\s*([\s\S]*?)\s*</p>', body)
    forward = _search(r'class="comilla-cerrar">\s*([\s\S]*?)\s*</div>', body)
    # 正文 HTML 块（保留段落，交给 KOReader 渲染）
    content_html = _search(
        r'<div class="articulo-contenido">([\s\S]*?)</div>\s*<div class="articulo-extra">',
        body,
    ) or _search(r'<div class="articulo-contenido">([\s\S]*?)</div>\s*<script', body)
    return {
        "endpoint": url,
        "article_id": article_id,
        "title": _clean(title),
        "author": _clean(author),
        "forward": _clean(forward),
        "content_html": content_html,
        "content_text": _html_to_text(content_html or ""),
    }


# ---------- 问答：/question/<id> ----------

def parse_question(question_id: str) -> dict:
    url = f"{BASE}/question/{question_id}"
    body = http_get(url)
    q_title = _search(r'<h4>\s*([\s\S]*?)\s*</h4>', body)

    # 结构：cuestion-contenido(问题) </div> <hr /> cuestion-a-icono <h4> </h4>
    # cuestion-contenido(答案，内含嵌套 div) </div> <p class="cuestion-editor">责任编辑：xx</p>
    # 用 <hr /> 切开
    parts = re.split(r'<hr\s*/>', body, maxsplit=1)
    question_html = None
    answer_html = None
    editor = None
    if len(parts) == 2:
        pre, post = parts
        question_html = _search(
            r'<div class="cuestion-contenido">([\s\S]*?)</div>', pre
        )
        # 答案 div 内嵌了 img div，需要贪婪匹配到 responsible editor / share 之前的最后一个 </div>
        answer_html = _search(
            r'<div class="cuestion-contenido">([\s\S]*)</div>\s*'
            r'(?:<p class="cuestion-editor"|<div class="cuestion-compartir"|<div class="one-comentarios")',
            post,
        )
        editor = _search(
            r'<p class="cuestion-editor">\s*([\s\S]*?)\s*</p>', post
        )

    return {
        "endpoint": url,
        "question_id": question_id,
        "title": _clean(q_title),
        "editor": _clean(editor),
        "question_text": _html_to_text(question_html or ""),
        "answer_html": answer_html,
        "answer_text": _html_to_text(answer_html or ""),
    }


# ---------- helpers ----------

def _search(pattern: str, text: str) -> str | None:
    m = re.search(pattern, text)
    return m.group(1) if m else None


def _clean(s: str | None) -> str | None:
    if s is None:
        return None
    s = html.unescape(s)
    s = re.sub(r"<[^>]+>", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s or None


def _html_to_text(s: str) -> str:
    s = re.sub(r"<img[^>]+src=\"([^\"]+)\"[^>]*>", r"[IMG: \1]", s)
    s = re.sub(r"<br\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"</p>", "\n\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    s = re.sub(r"\n{3,}", "\n\n", s).strip()
    return s


def main():
    idx = parse_index()
    print("=" * 60)
    print("首页 today =", idx["today"])
    print("=" * 60)

    override = sys.argv[1] if len(sys.argv) > 1 else None
    image_id = override or idx["today"]["image_id"]
    article_id = idx["today"]["article_id"]
    question_id = idx["today"]["question_id"]

    result: dict[str, Any] = {"index": idx}

    if image_id:
        print(f"\n--- IMAGE /one/{image_id} ---")
        img = parse_image(image_id)
        result["image"] = img
        _preview(img)

    if article_id:
        print(f"\n--- ARTICLE /article/{article_id} ---")
        art = parse_article(article_id)
        result["article"] = art
        _preview(art, long_keys={"content_html", "content_text"})

    if question_id:
        print(f"\n--- QUESTION /question/{question_id} ---")
        q = parse_question(question_id)
        result["question"] = q
        _preview(q, long_keys={"answer_html", "answer_text"})

    out = "/tmp/one_api_probe_result.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"\n完整结果已写入 {out}")


def _preview(d: dict, long_keys: set[str] = frozenset()):
    for k, v in d.items():
        if v is None:
            print(f"  {k}: <None>")
        elif k in long_keys and isinstance(v, str):
            print(f"  {k}: ({len(v)} chars) {v[:200]}...")
        else:
            s = str(v)
            print(f"  {k}: {s[:220]}")


if __name__ == "__main__":
    main()
