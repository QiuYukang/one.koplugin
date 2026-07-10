#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_hp_index.py — 生成 lib/hp_index.lua 的密集 SEED 断点表

原理见 lib/hp_index.lua 顶部注释：
  * 日期 <-> VOL 是纯算术（VOL.1 = 2012-10-08，每天 +1，永不跳号）。
  * VOL -> image_id 单调递增、每天约 +1、约 3% 跳号。
  * 于是只需在“跳号发生处”存一个 (vol, id) 断点，两断点间用 id=前+差 直接算，零探测。

本脚本顺序遍历 image_id，读每条的 hp_title(=VOL.N)，检测“下一个 id 的 VOL 不是
+1”的位置作为断点，最后打印成可直接粘进 lib/hp_index.lua 的 Lua SEED 表。

⚠️ 开销：一次全量约等于 (最新 id) 次请求（现约 5000+），限速 0.2s ≈ 20 分钟。
   属于一次性离线任务；请勿频繁运行，尊重 wufazhuce.com。

用法:
    python3 build_hp_index.py                 # 全量 14..最新
    python3 build_hp_index.py 14 5147         # 指定 id 区间
    python3 build_hp_index.py --sleep 0.3     # 自定义限速（秒）

需要 Python >= 3.8，无三方依赖。
"""

import json
import re
import sys
import time
import urllib.request

BASE = "http://v3.wufazhuce.com:8000"
COMMON_QS = "?version=3.5.0&platform=android"
TIMEOUT = 15
VOL_RE = re.compile(r"VOL\.(\d+)")


def get_hp_detail(image_id: int):
    """返回 (vol, iso_date) 或 None（404 / 缺字段）。"""
    url = f"{BASE}/api/hp/detail/{image_id}{COMMON_QS}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.loads(r.read())
    except Exception:
        return None
    if data.get("res") != 0 or not data.get("data"):
        return None
    d = data["data"]
    m = VOL_RE.search(d.get("hp_title") or "")
    if not m:
        return None
    iso = (d.get("hp_makettime") or "")[:10] or None
    return int(m.group(1)), iso


def latest_id() -> int:
    """hp/idlist/0 里最大的 id，作为遍历上界。"""
    url = f"{BASE}/api/hp/idlist/0{COMMON_QS}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = json.loads(r.read())
    return max(int(x) for x in data["data"])


def build(start_id: int, end_id: int, sleep: float):
    """遍历 [start_id, end_id]，返回断点列表 [(vol, id), ...]（含每段起点）。"""
    points = []
    prev = None  # (vol, id)
    for image_id in range(start_id, end_id + 1):
        res = get_hp_detail(image_id)
        time.sleep(sleep)
        if res is None:
            continue  # 跳号 id：不存在，跳过
        vol, iso = res
        if prev is None:
            points.append((vol, image_id))  # 第一个锚点
        else:
            pvol, pid = prev
            # 期望连续：id 每 +1，VOL 也 +1。偏离即为断点。
            if vol - pvol != image_id - pid:
                points.append((vol, image_id))
        prev = (vol, image_id)
        if image_id % 200 == 0:
            sys.stderr.write(f"  ... id={image_id} VOL.{vol} ({iso}) 断点数={len(points)}\n")
    # 始终带上最后一个点作为上界锚，便于近期外推。
    if prev and (not points or points[-1] != prev):
        points.append(prev)
    return points


def main(argv):
    sleep = 0.2
    if "--sleep" in argv:
        i = argv.index("--sleep")
        sleep = float(argv[i + 1])
        del argv[i:i + 2]

    start_id = int(argv[0]) if len(argv) > 0 else 14
    end_id = int(argv[1]) if len(argv) > 1 else latest_id()
    sys.stderr.write(f"遍历 id {start_id}..{end_id}，限速 {sleep}s/次\n")

    points = build(start_id, end_id, sleep)

    print("-- 由 scripts/build_hp_index.py 生成，实测于运行日。")
    print("-- 把这段替换 lib/hp_index.lua 里的 SEED。")
    print("local SEED = {")
    for vol, image_id in points:
        print(f"    {{ vol = {vol},{' ' * max(1, 6 - len(str(vol)))}id = {image_id} }},")
    print("}")
    sys.stderr.write(f"完成：{len(points)} 个断点。\n")


if __name__ == "__main__":
    main(sys.argv[1:])
