"""多链接下载队列

任务状态机: pending -> downloading -> done / error
支持串行或 N 路并行调度，CLI / Streamlit / mac_app 三端共用。
"""
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from core.downloader import M3U8Downloader


class DownloadTask:
    """单个下载任务的状态容器"""

    def __init__(self, url, title=None, output_dir=None):
        self.id = uuid.uuid4().hex[:8]
        self.url = url
        self.title = title
        self.output_dir = output_dir
        self.state = 'pending'      # pending / downloading / done / error
        self.current = 0
        self.total = 0
        self.output = ''
        self.error = ''
        self.started_at = None
        self.finished_at = None

    def summary(self):
        return {
            'id': self.id, 'url': self.url, 'title': self.title,
            'state': self.state, 'current': self.current, 'total': self.total,
            'output': self.output, 'error': self.error,
        }


class DownloadQueue:
    """下载任务管理器

    :param max_parallel: 同时下载的视频数 (任务级并行，区别于切片级并行)
    :param on_update: 任务状态变化回调 (task, event)，event: start/progress/finish
    """

    def __init__(self, max_parallel=1, on_update=None, show_progress=True):
        self.max_parallel = max_parallel
        self.on_update = on_update
        # CLI 场景打印带前缀的 \r 单行进度；GUI 场景置 False 由界面渲染
        self.show_progress = show_progress
        self._tasks = []
        self._lock = threading.RLock()
        self._executor = None

    def _log_prefix(self, task):
        """多任务日志前缀，如 [2/5]"""
        with self._lock:
            idx = self._tasks.index(task) + 1
            return f"[{idx}/{len(self._tasks)}]"

    # ---- 任务管理 ----

    def add(self, url, title=None, output_dir=None):
        """入队一个任务，立即返回任务对象"""
        task = DownloadTask(url, title, output_dir)
        with self._lock:
            self._tasks.append(task)
        return task

    def get_tasks(self):
        with self._lock:
            return [t.summary() for t in self._tasks]

    def _emit(self, task, event):
        if self.on_update:
            try:
                self.on_update(task, event)
            except Exception:
                pass  # 回调异常不影响下载流程

    # ---- 调度 ----

    def run(self, wait=True):
        """执行所有任务

        :param wait: True 阻塞直到全部完成 (CLI 场景)；False 立即返回 (GUI 场景，配合 is_running 轮询)
        """
        with self._lock:
            if self._executor:
                raise RuntimeError('队列已在运行中')
            pending = [t for t in self._tasks if t.state == 'pending']
            self._executor = ThreadPoolExecutor(max_workers=self.max_parallel)

        future = self._executor.map(self._run_task, pending)
        self._executor.shutdown(wait=False)

        if wait:
            list(future)  # 消费 map 迭代器，阻塞至全部完成
            with self._lock:
                self._executor = None
        return future

    def is_running(self):
        with self._lock:
            return self._executor is not None

    def _run_task(self, task):
        task.state = 'downloading'
        task.started_at = time.time()
        prefix = self._log_prefix(task)
        self._emit(task, 'start')

        def on_progress(current, total):
            task.current = current
            task.total = total
            if self.show_progress:
                pct = int(current / total * 100) if total else 0
                print(f"\r{prefix} 进度: {current}/{total} ({pct}%)", end="", flush=True)
            self._emit(task, 'progress')

        try:
            if self.show_progress:
                print(f"{prefix} 开始下载: {task.title or task.url[:80]}")
            downloader = M3U8Downloader(
                task.url, output_dir=task.output_dir, output_filename=task.title,
                log_prefix=prefix,
            )
            result, error = downloader.run(progress_callback=on_progress)
            if self.show_progress:
                print()  # 结束进度单行刷新，换行
            if result:
                task.state = 'done'
                task.output = result
                if self.show_progress:
                    print(f"{prefix} ✅ 完成 -> {result}")
            else:
                task.state = 'error'
                task.error = error or '下载失败'
        except Exception as e:
            if self.show_progress:
                print()  # 进度行换行，避免与错误信息拼接
            task.state = 'error'
            task.error = str(e)
        finally:
            task.finished_at = time.time()
            self._emit(task, 'finish')

    # ---- 结果统计 ----

    def results(self):
        """返回 (成功列表, 失败列表)"""
        with self._lock:
            done = [(t.title or t.url, t.output) for t in self._tasks if t.state == 'done']
            failed = [(t.title or t.url, t.error) for t in self._tasks if t.state == 'error']
        return done, failed
