"""JS <-> Python 桥接层

sniffer.js 通过 pywebview.api 调用这里的接口:
- navigate/back/forward: 浏览器导航控制
- download: 启动下载任务 (后台线程)
- get_status: 轮询下载进度
"""
import threading

import webview

from core.downloader import M3U8Downloader


class AppApi:
    def __init__(self):
        self._dl_thread = None
        self._lock = threading.Lock()
        self._status = {
            'state': 'idle',      # idle / downloading / done / error
            'current': 0,
            'total': 0,
            'message': '',
            'output': '',
        }

    # ---- 浏览器导航 ----

    def navigate(self, url):
        webview.windows[0].load_url(url)

    def back(self):
        webview.windows[0].evaluate_js('history.back()')

    def forward(self):
        webview.windows[0].evaluate_js('history.forward()')

    # ---- 下载 ----

    def download(self, url, title=None):
        """启动下载任务，立即返回；进度通过 get_status 轮询"""
        with self._lock:
            if self._dl_thread and self._dl_thread.is_alive():
                return {'ok': False, 'error': '已有下载任务进行中'}
            self._status = {
                'state': 'downloading', 'current': 0, 'total': 0,
                'message': '', 'output': '',
            }
        self._dl_thread = threading.Thread(
            target=self._run_download, args=(url, title), daemon=True
        )
        self._dl_thread.start()
        return {'ok': True}

    def _run_download(self, url, title):
        def on_progress(current, total):
            with self._lock:
                self._status['current'] = current
                self._status['total'] = total

        try:
            downloader = M3U8Downloader(url, output_filename=title)
            result, error = downloader.run(progress_callback=on_progress)
            with self._lock:
                if result:
                    self._status.update({'state': 'done', 'output': result})
                else:
                    self._status.update({'state': 'error', 'message': error or '下载失败'})
        except Exception as e:
            with self._lock:
                self._status.update({'state': 'error', 'message': str(e)})

    def get_status(self):
        with self._lock:
            return dict(self._status)
