import streamlit as st
import time
import tkinter as tk
from tkinter import filedialog
from core.extractor import WebExtractor
from core.downloader import M3U8Downloader
from core.utils import validate_url
from pathlib import Path

st.set_page_config(page_title="M3U8 智能下载器", page_icon="🎬")

st.title("🎬 M3U8 智能下载器")
st.markdown("输入视频 m3u8 地址或网页地址，一键下载视频到本地。")

# 初始化 session state
if 'output_dir' not in st.session_state:
    st.session_state.output_dir = str(Path.home() / "Downloads" / "tx")

# 1. 参数设置
with st.container():
    col1, col2, col3 = st.columns([3, 2, 1])
    with col1:
        url = st.text_input("视频地址 (必填)", placeholder="https://example.com/video.m3u8 或 网页URL")
    
    with col2:
        # 显示当前目录，允许手动修改
        st.text_input("保存目录", key="output_dir", help="安全限制：只能选择 /Users/abc 下的目录")
    
    with col3:
        st.write("") # 占位，让按钮对齐
        st.write("") 
        st.caption("⚠️ 仅限用户目录\n\n例如：\n- /Users/abc/Downloads\n- /Users/abc/Movies")
        # macOS 上 Streamlit 运行在子线程，直接调用 Tkinter 会导致 crash (NSWindow should only be instantiated on the main thread)
        # 临时移除 Tkinter 目录选择功能，改用手动输入
        # if st.button("📂 选择文件夹"): ... 

# 2. 状态显示区域
status_container = st.empty()
progress_bar = st.empty()

# 3. 核心逻辑
if st.button("🚀 开始下载", type="primary"):
    if not url:
        st.error("❌ 请输入视频地址")
    else:
        # 0. 验证 URL
        status_container.info("正在验证 URL...")
        is_valid, msg = validate_url(url)
        
        if not is_valid:
            st.error(f"❌ URL 无效: {msg}")
        else:
            try:
                # 1. 解析 (如果是网页)
                target_url = url
                video_title = None
                
                if ".m3u8" not in url or url.strip().endswith(".html"):
                    status_container.warning("识别为网页，正在启动浏览器解析 (可能需要几秒钟)...")
                    extractor = WebExtractor()
                    extracted, title = extractor.extract_m3u8(url)
                    if extracted:
                        target_url = extracted
                        video_title = title
                        st.success(f"✅ 成功提取 m3u8: {target_url}")
                        if title:
                            st.info(f"📄 识别到视频标题: {title}")
                    else:
                        st.error("❌ 未能在网页中找到 m3u8 链接")
                        st.stop()

                # 2. 下载
                status_container.info("正在准备下载...")
                
                # 定义进度回调
                p_bar = progress_bar.progress(0)
                
                def on_progress(current, total):
                    percent = int(current / total * 100)
                    p_bar.progress(percent)
                    status_container.info(f"⬇️ 正在下载切片: {current}/{total} ({percent}%)")

                downloader = M3U8Downloader(target_url, output_dir=st.session_state.output_dir, output_filename=video_title)
                result_path, error_msg = downloader.run(progress_callback=on_progress)
                
                if result_path:
                    p_bar.progress(100)
                    status_container.empty()
                    st.success(f"🎉 下载完成！")
                    st.balloons()
                    st.code(result_path, language="bash")
                    st.info(f"文件已保存到: {st.session_state.output_dir}")
                else:
                    st.error(f"❌ 下载失败: {error_msg}")
                    with st.expander("可能有用的排查建议"):
                        st.markdown("""
                        1. 检查网络连接是否正常
                        2. 确认视频地址是否已失效（有些 m3u8 有时效性）
                        3. 如果是加密视频，可能需要特定的 Headers 或 Key
                        """)

            except PermissionError as e:
                st.error(str(e))
                st.toast("⚠️ 目录权限错误，请检查路径", icon="🚫")
            except Exception as e:
                st.error(f"❌ 发生未知错误: {str(e)}")
                with st.expander("查看详细错误信息"):
                    st.exception(e)

# 页脚
st.markdown("---")
st.caption("Powered by Streamlit & Python | v1.0")
