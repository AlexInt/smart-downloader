#!/usr/bin/env python3
"""
野果短剧 (yeguodj.com) 全自动下载器（独立脚本，无需浏览器）

原理: 直接调用站点 play 接口 → AES 解密响应 → 获取含新鲜 auth_key 的 m3u8 → 复用下载核心。
auth_key 每次调用接口即时生成，无过期问题；登录 token 有效期 30 天。

用法:
  python3 yeguo_auto.py <剧集页URL>              下载指定集（默认第 1 集）
  python3 yeguo_auto.py <URL> --all              下载全剧所有可播放集
  python3 yeguo_auto.py <URL> -o ~/Downloads/tx  指定输出目录

支持 URL 形式:
  https://yeguodj.com/drama/video/3445/          第 1 集
  https://yeguodj.com/drama/video/3445/ep-3/     第 3 集
  https://yeguodj.com/drama/detail/3445/         第 1 集
"""
import argparse
import base64
import json
import re
import sys
from pathlib import Path

import requests
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad

from core.downloader import M3U8Downloader

SITE = "https://www.yeguodj.com"
USERNAME = "yeguo110"
PASSWORD = "yg123456"
AES_KEY = b"2acf7e91e9864673"
AES_IV = b"1c29882d3ddfcfd6"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Origin": SITE,
    "Referer": f"{SITE}/",
}


def decrypt_response(data):
    """解密接口响应: base64(空格还原为+) → AES-128-CBC → JSON"""
    raw = base64.b64decode(data.replace(" ", "+"))
    plain = unpad(AES.new(AES_KEY, AES.MODE_CBC, AES_IV).decrypt(raw), 16)
    return json.loads(plain)


def call_api(path, token, extra):
    form = {
        "bundleId": "com.pwa.mater", "version": "1.3.2", "oauth_type": "web",
        "language": "zh", "via": "pwa", "oauth_id": "a" * 32, "token": token,
        "trace_id": "a" * 32,
    }
    form.update(extra)
    resp = requests.post(f"{SITE}/{path}", data=form, headers=HEADERS, timeout=15).json()
    if resp.get("errcode") != 0:
        raise RuntimeError(f"接口 {path} 返回错误: errcode={resp.get('errcode')} {resp.get('msg', '')}")
    return decrypt_response(resp["data"])


def login():
    """登录获取 30 天有效期的 token；失败则降级为游客模式"""
    try:
        result = call_api("api.php/api/account/login", "", {"username": USERNAME, "password": PASSWORD})
        token = result["data"]["token"]
        print(f"✅ 已登录: {result['data']['nickname']}")
        return token
    except Exception as e:
        print(f"⚠️ 登录失败({e})，以游客模式继续（付费内容将无法解锁）")
        return ""


def fetch_drama(drama_id, token):
    """调用 play 接口，返回含全集列表的剧集数据"""
    result = call_api("api.php/api/playlet/play", token,
                      {"playlet_id": drama_id, "video_id": drama_id, "episode_id": 0})
    return result["data"]


def parse_input_url(url):
    """从 URL 提取 (剧 ID, 集数序号)；无法识别时返回 (None, None)"""
    m = re.search(r"/drama/(?:video|detail)/(\d+)(?:/ep-(\d+))?", url)
    if not m:
        return None, None
    drama_id = int(m.group(1))
    ep_no = int(m.group(2)) if m.group(2) else 1
    return drama_id, ep_no


def pick_episode(drama_id, token, episode_id):
    """按集 ID 取该集信息；每次重新调接口保证 auth_key 新鲜"""
    data = fetch_drama(drama_id, token)
    for ep in data["episodeAll"]:
        if ep.get("id") == episode_id and not ep.get("is_adv"):
            return data["drama_name"], ep
    return data["drama_name"], None


def main():
    parser = argparse.ArgumentParser(description="野果短剧 (yeguodj.com) 全自动下载器")
    parser.add_argument("url", help="剧集页/详情页 URL")
    parser.add_argument("-all", "--all", action="store_true", help="下载全剧所有可播放集")
    parser.add_argument("-o", "--output", default=None, help="输出目录 (默认: ~/Downloads/tx)")
    args = parser.parse_args()

    drama_id, ep_no = parse_input_url(args.url)
    if not drama_id:
        print(f"❌ 无法识别的 URL: {args.url}")
        sys.exit(1)

    token = login()
    data = fetch_drama(drama_id, token)
    drama_name = data["drama_name"]
    episodes = sorted([e for e in data["episodeAll"] if not e.get("is_adv")], key=lambda e: e["sort"])
    total = len(episodes)
    print(f"📺 《{drama_name}》共 {total} 集 (更新状态: {data.get('update_status', '未知')})")

    if args.all:
        targets = episodes
    else:
        targets = [e for e in episodes if e["sort"] == ep_no]
        if not targets:
            print(f"❌ 第 {ep_no} 集不存在 (全剧共 {total} 集)")
            sys.exit(1)

    locked = [e for e in targets if not e.get("access", {}).get("can_play")]
    playable = [e for e in targets if e.get("access", {}).get("can_play")]
    for ep in locked:
        print(f"🔒 第 {ep['sort']} 集无法播放 (状态: {ep.get('access', {}).get('state')})，已跳过")
    if not playable:
        print("❌ 没有可下载的集数")
        sys.exit(1)

    if args.all:
        # 全剧模式: 输出到以剧名命名的子目录
        safe_name = "".join(c for c in drama_name if c.isalnum() or c in "._- ").strip()
        base_dir = Path(args.output).expanduser() if args.output else Path.home() / "Downloads" / "tx"
        output_dir = base_dir / safe_name
        print(f"📁 全剧保存至: {output_dir}")
    else:
        output_dir = args.output

    print("-" * 30)
    done, failed = [], []
    for i, ep in enumerate(playable, 1):
        # 每集重新调接口，确保 auth_key 新鲜
        _, fresh = pick_episode(drama_id, token, ep["id"])
        if not fresh:
            failed.append((ep["sort"], "接口未返回该集信息"))
            continue
        url = fresh["video_url"] or fresh["video_url_h265"]
        if not url:
            failed.append((ep["sort"], "接口未返回播放地址"))
            continue

        name = f"{drama_name}_第{fresh['sort']:02d}集"
        print(f"[{i}/{len(playable)}] {name} ({fresh.get('resolution', '未知分辨率')})")
        output, error = M3U8Downloader(
            url, output_dir=output_dir, output_filename=name, log_prefix=f"[{i}/{len(playable)}]"
        ).run()
        if output:
            done.append((name, output))
        else:
            failed.append((fresh["sort"], error))

    print("-" * 30)
    print(f"🎉 全部完成: 成功 {len(done)} / {len(playable)}")
    for name, output in done:
        print(f"  ✅ {name} -> {output}")
    for ep, error in failed:
        print(f"  ❌ 第 {ep} 集: {error}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
