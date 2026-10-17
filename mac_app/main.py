"""Smart Downloader Mac App 入口

内嵌浏览器访问视频网页，自动嗅探 m3u8 并一键下载。
- 开发运行: python3 mac_app/main.py
- 打包分发: cd mac_app && python3 setup.py py2app
"""
import os
import sys
from pathlib import Path

import webview

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent
# 源码运行时把项目根目录加入 sys.path 以导入 core 包 (py2app 打包后由 bundle 提供)
if (PROJECT_ROOT / 'core').is_dir():
    sys.path.insert(0, str(PROJECT_ROOT))

from api import AppApi


def resource_path(name: str) -> Path:
    """兼容源码运行与 py2app 打包后的资源文件路径"""
    candidates = []
    rp = os.environ.get('RESOURCEPATH')  # py2app 启动时设置，指向 Contents/Resources
    if rp:
        candidates.append(Path(rp) / name)
    candidates += [BASE_DIR / name, PROJECT_ROOT / 'mac_app' / name]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError(f'资源文件不存在: {name}')


SNIFFER_JS = resource_path('sniffer.js').read_text(encoding='utf-8')
HOME_URL = resource_path('index.html').as_uri()


def on_loaded():
    """每次页面加载完成后注入 m3u8 嗅探脚本 (本地首页除外)"""
    window = webview.windows[0]
    url = window.get_current_url() or ''
    if url.startswith('file://'):
        return
    window.evaluate_js(SNIFFER_JS)


def main():
    api = AppApi()
    window = webview.create_window(
        'Smart Downloader',
        url=HOME_URL,
        js_api=api,
        width=1100,
        height=720,
        min_size=(800, 500),
    )
    window.events.loaded += on_loaded
    webview.start()


if __name__ == '__main__':
    main()
