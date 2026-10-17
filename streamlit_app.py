import streamlit as st
from pathlib import Path

from core.extractor import WebExtractor
from core.queue import DownloadQueue
from core.utils import validate_url

st.set_page_config(page_title="M3U8 智能下载器", page_icon="🎬")

st.title("🎬 M3U8 智能下载器")
st.markdown("输入视频 m3u8 地址或网页地址（支持多行批量），一键下载视频到本地。")

# 初始化 session state
if 'output_dir' not in st.session_state:
    st.session_state.output_dir = str(Path.home() / "Downloads" / "tx")
if 'queue' not in st.session_state:
    st.session_state.queue = None

# 1. 参数设置
with st.container():
    col1, col2 = st.columns([3, 2])
    with col1:
        url_text = st.text_area(
            "视频地址 (必填，每行一个，支持批量)",
            placeholder="https://example.com/video.m3u8\nhttps://example.com/page.html",
            height=120,
        )
    with col2:
        st.text_input("保存目录", key="output_dir",
                      help=f"安全限制：只能选择 {Path.home()} 下的目录")
        jobs = st.number_input("同时下载任务数", min_value=1, max_value=5, value=1, step=1)
        st.caption(f"⚠️ 仅限用户目录\n例如：\n- {Path.home()}/Downloads")

# 2. 状态与进度显示区域
status_container = st.empty()


def render_tasks():
    """渲染任务列表实时状态 (下载中显示进度条)"""
    queue = st.session_state.queue
    if not queue:
        return
    tasks = queue.get_tasks()
    if not tasks:
        return
    lines = []
    bars = []
    for t in tasks:
        name = t['title'] or t['url']
        icon = {'pending': '⏳', 'downloading': '⬇️', 'done': '✅', 'error': '❌'}[t['state']]
        if t['state'] == 'downloading' and t['total']:
            lines.append(f"{icon} {name} — {t['current']}/{t['total']}")
            bars.append(t['current'] / t['total'])
        elif t['state'] == 'done':
            lines.append(f"{icon} {name} — 已保存到 {t['output']}")
        elif t['state'] == 'error':
            lines.append(f"{icon} {name} — {t['error']}")
        else:
            lines.append(f"{icon} {name}")
    st.markdown("\n\n".join(lines))


# 3. 核心逻辑
if st.button("🚀 开始下载", type="primary"):
    urls = [u.strip() for u in url_text.splitlines() if u.strip()]
    if not urls:
        st.error("❌ 请输入视频地址")
    else:
        # 3.1 逐个预检 + 解析网页
        targets = []
        for u in urls:
            status_container.info(f"正在验证: {u[:80]}")
            is_valid, msg = validate_url(u)
            if not is_valid:
                st.error(f"❌ URL 无效: {msg} ({u[:60]})")
                continue

            if ".m3u8" in u and not u.strip().endswith(".html"):
                targets.append((u, None))
            else:
                status_container.warning(f"正在启动浏览器解析 (可能需要几秒钟): {u[:60]}")
                extractor = WebExtractor()
                extracted, title = extractor.extract_m3u8(u)
                if extracted:
                    targets.append((extracted, title))
                else:
                    st.error(f"❌ 未能在网页中找到 m3u8 链接: {u[:60]}")

        if not targets:
            st.stop()

        # 3.2 入队并启动 (非阻塞)
        queue = DownloadQueue(max_parallel=int(jobs), show_progress=False)
        for m3u8_url, title in targets:
            queue.add(m3u8_url, title=title, output_dir=st.session_state.output_dir)
        st.session_state.queue = queue
        queue.run(wait=False)
        status_container.info(f"🚀 已入队 {len(targets)} 个任务，实时进度如下 (刷新页面可查看最新状态)")

# 4. 任务列表区 (运行中/结束后持续展示)
render_tasks()
if st.session_state.queue and st.session_state.queue.is_running():
    st.autorefresh(interval=1000) if hasattr(st, 'autorefresh') else None
    # 无 st.autorefresh 依赖时，用户手动刷新页面即可更新进度

# 页脚
st.markdown("---")
st.caption("Powered by Streamlit & Python | v1.1")
