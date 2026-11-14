import concurrent.futures
import ipaddress
import shutil
import socket
import subprocess
from urllib.parse import urljoin, urlunparse, urlparse

import m3u8
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from pathlib import Path
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from core.utils import HEADERS, get_download_dir, create_temp_dir, clean_dir, generate_filename
from core.decrypter import Decrypter

# MARK: IP 直连降级（iOS Downloader.fetchIPDirect 同步，2026-11-14）
#
# 部分网络环境（蜂窝 / 防火墙）按 ClientHello 的 SNI 域名掐连接（握手期 RST）。
# 对策：域名解析成 IP 后直接连 IP —— TLS 层不携带 SNI（CPython ssl 对 IP 字面量
# 不发送 SNI 扩展），Host 头回填原域名供 CDN 路由；证书与 IP 不匹配由 verify=False
# 兜底（iOS 侧 TrustAll 等价）。
# 注意：按 TLS 指纹（ClientHello 特征）拦截此法无效——requests 的指纹不随 URL 改写
# 变化；该场景 iOS 走 WebKit 兜底，Python 无对应通道，失败消息给出换网提示。
# 进程级 sticky：已证实 IP 直连可用的域名，后续请求直接走，省去必败的常规连接。
# 并发切片线程共享以下三个结构，良性竞争不加锁（iOS 同款注释；CPython set/dict
# 的单条 add/赋值在 GIL 下原子）。
_IP_DIRECT_HOSTS = set()
_DNS_CACHE = {}
# 失败告警只打一次（切片级重试会让同一域名的失败刷屏），成功后移除恢复告警
_IP_DIRECT_WARNED = set()


def _is_ip_literal(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def _resolve_host(host):
    """域名 -> [IP]（getaddrinfo 为阻塞调用，只在请求线程跑；IPv4 优先），成功后进程级缓存"""
    cached = _DNS_CACHE.get(host)
    if cached:
        return cached
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except OSError:
        return []
    ips, seen = [], set()
    for info in infos:
        ip = info[4][0]
        if ip not in seen:
            seen.add(ip)
            ips.append(ip)
    ipv4 = [ip for ip in ips if ":" not in ip]
    result = ipv4 or ips
    if result:
        _DNS_CACHE[host] = result
    return result


def _is_connection_level_error(e):
    """连接层失败：SNI/指纹拦截的典型表现（握手 RST / 无法建连 / 超时），值得尝试 IP 直连"""
    return isinstance(
        e,
        (requests.exceptions.SSLError,
         requests.exceptions.ConnectionError,
         requests.exceptions.Timeout),
    )


class M3U8Downloader:
    def __init__(self, url, output_dir=None, output_filename=None, max_workers=6,
                 log_prefix=None):
        self.url = url
        self.max_workers = max_workers
        self.download_dir = get_download_dir(custom_path=output_dir)
        self.output_filename = output_filename
        self.key_cache = {}
        # 多任务场景由队列层传入前缀 (如 "[2/5]")，避免输出互相穿插
        self.log_prefix = f"{log_prefix} " if log_prefix else ""
        self.session = self._make_session()

    def _make_session(self):
        """创建带传输层重试的 Session，自动处理被服务器掐断的连接"""
        session = requests.Session()
        session.verify = False
        session.headers.update(HEADERS)
        transport_retry = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            # None = 对所有方法（含 POST/GET）都重试
            allowed_methods=None,
            # 连接读取出错/被断开时自动重试
            raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=transport_retry, pool_maxsize=self.max_workers + 5)
        session.mount('https://', adapter)
        session.mount('http://', adapter)
        return session

    def _request(self, url, **kwargs):
        """统一请求入口。

        降级链（iOS fetchData 同步）：常规请求 → 连接层失败时 IP 直连 → 成功后该域名
        sticky，后续请求直接走 IP。SSL 被服务器断开时仍先丢弃连接池（换新连接重试语义
        保留），随后同样尝试 IP 直连。所有上层（切片/密钥/播放列表/初始化段）自动受益。
        """
        kwargs.setdefault('timeout', 30)
        kwargs.setdefault('verify', False)
        host = urlparse(url).hostname
        # 该域名已证实需 IP 直连（常规连接被网络侧掐），直接走，省去必败的常规连接
        if host in _IP_DIRECT_HOSTS:
            resp = self._ip_direct_fetch(url, **kwargs)
            if resp is not None:
                return resp
        try:
            return self.session.get(url, **kwargs)
        except requests.exceptions.SSLError:
            self._log("⚠️ SSL 连接被服务器断开，重建连接后重试...")
            self.session = self._make_session()
            # SSL 失败也值得试 IP 直连：证书类问题由 verify=False 兜底，
            # SNI 类问题由无 SNI 直连解决
            resp = self._ip_direct_fetch(url, **kwargs)
            if resp is not None:
                return resp
            raise
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
            # 连接层失败（按 SNI/目的地址拦截常见）：尝试 IP 直连降级
            resp = self._ip_direct_fetch(url, **kwargs)
            if resp is not None:
                return resp
            raise

    def _ip_direct_fetch(self, url, **kwargs):
        """IP 直连尝试：域名解析成 IP 直连（无 SNI）+ Host 头回填，成功后 sticky。

        逐个尝试解析出的 IP（最多 3 个）；失败返回 None（调用方走原异常路径，
        由 tenacity 继续重试）。
        """
        parsed = urlparse(url)
        host = parsed.hostname
        if not host or _is_ip_literal(host):
            return None
        ips = _resolve_host(host)
        if not ips:
            if host not in _IP_DIRECT_WARNED:
                _IP_DIRECT_WARNED.add(host)
                self._log(f"⚠️ IP 直连跳过: {host} DNS 解析不到地址")
            return None
        headers = dict(kwargs.pop("headers", None) or HEADERS)
        headers["Host"] = host          # CDN 按原域名路由站点
        kwargs.pop("verify", None)      # 统一 verify=False（证书与 IP 不匹配，TrustAll 等价）
        timeout = kwargs.pop("timeout", 30)
        last_error = None
        for ip in ips[:3]:
            ip_host = f"[{ip}]" if ":" in ip else ip
            netloc = ip_host if parsed.port is None else f"{ip_host}:{parsed.port}"
            ip_url = urlunparse(parsed._replace(netloc=netloc))
            try:
                resp = requests.get(ip_url, headers=headers, timeout=timeout, verify=False)
                if 200 <= resp.status_code < 300:
                    # 成功日志仅首次置位时打：sticky 路径每次请求都会进来，逐条刷屏
                    #（iOS 侧 sticky 路径同样静默）
                    if host not in _IP_DIRECT_HOSTS:
                        _IP_DIRECT_HOSTS.add(host)
                        _IP_DIRECT_WARNED.discard(host)
                        self._log(f"✅ IP 直连成功 ({host} -> {ip})，该域名后续请求直接走 IP")
                    return resp
                last_error = f"HTTP {resp.status_code}"
            except requests.exceptions.RequestException as e:
                last_error = str(e)
                continue  # 该 IP 不行，换下一个
        if host not in _IP_DIRECT_WARNED:
            _IP_DIRECT_WARNED.add(host)
            self._log(f"⚠️ IP 直连失败 ({host}): {last_error}")
        return None

    def _log(self, message):
        print(f"{self.log_prefix}{message}")

    def run(self, progress_callback=None):
        """
        执行下载流程
        :param progress_callback: 回调函数，接收 (current, total) 参数
        """
        temp_dir = create_temp_dir(self.download_dir)
        try:
            # 1. 解析 m3u8
            playlist, base_uri = self._load_playlist(self.url)
            media_sequence = playlist.media_sequence or 0

            # 2. 下载 fMP4 初始化段 (EXT-X-MAP，若存在)
            init_file = self._download_init_section(playlist, base_uri, temp_dir)

            # 3. 下载切片
            self._log(f"找到 {len(playlist.segments)} 个切片，开始下载...")
            ts_files, failed_segments = self._download_segments(
                playlist.segments, base_uri, temp_dir, progress_callback,
                media_sequence=media_sequence)

            # 4. 合并文件。任一切片重试后仍失败 -> 整任务失败，不做缺洞合并
            #（iOS 侧同策略：缺洞文件播放会花屏/卡顿，产出比不产出更糟）
            if failed_segments:
                sample = ", ".join(str(i) for i in sorted(failed_segments)[:8])
                more = "..." if len(failed_segments) > 8 else ""
                msg = (f"❌ {len(failed_segments)} 个切片重试后仍失败 (序号: {sample}{more})；"
                       f"缺洞合并会产生花屏/卡顿的文件，已放弃")
                self._log(msg)
                return None, msg
            if ts_files:
                output_path = self._merge_files(ts_files)
                self._log(f"✅ 合并完成: {output_path}")
                return str(output_path), None
            else:
                msg = "❌ 没有下载到任何切片，可能是视频源不可用或解密失败"
                self._log(msg)
                return None, msg

        except Exception as e:
            msg = f"下载过程出错: {str(e)}"
            # 连接层失败几乎必然是网络路径被 CDN/WAF 拦截（IP 直连降级也未通过），
            # 此时网页内视频同样播不出来，给出可操作提示（iOS 侧同文案逻辑）
            if _is_connection_level_error(e):
                msg += ("；当前网络无法连接该视频源（SNI/TLS 拦截常见，IP 直连降级也未通过），"
                        "请换 WiFi 或使用代理后重试")
            self._log(f"❌ {msg}")
            return None, msg
        finally:
            clean_dir(temp_dir)

    @retry(
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=20),
        retry=retry_if_exception_type((requests.exceptions.RequestException, Exception)),
        reraise=True
    )
    def _load_playlist(self, url):
        """加载并解析 m3u8，处理多级列表（最多 3 层，iOS 同步——
        旧实现只走 1 层，master->variant->media 三层结构的源会在第二层断掉）"""
        self._log(f"解析 m3u8: {url}")

        response = self._request(url, timeout=15)
        response.raise_for_status()
        playlist = m3u8.loads(response.text, uri=url)
        base_uri = url

        for level in range(3):
            if not playlist.is_variant:
                break
            self._log(f"检测到第 {level + 1} 级播放列表，选择最高带宽流...")
            best_stream = max(playlist.playlists,
                              key=lambda p: p.stream_info.bandwidth or 0)
            self._log(f"选择流: {best_stream.uri}")

            sub_url = urljoin(base_uri, best_stream.uri)
            self._log(f"子列表完整 URL: {sub_url}")

            sub_response = self._request(sub_url, timeout=15)
            sub_response.raise_for_status()
            playlist = m3u8.loads(sub_response.text, uri=sub_url)
            base_uri = sub_url

        return playlist, base_uri

    def _download_segments(self, segments, base_uri, temp_dir, progress_callback=None,
                           media_sequence=0):
        """并发下载切片。

        返回 (成功文件列表, 失败序号列表)。失败不再静默跳过：由 run() 决定
        整任务失败（缺洞合并策略与 iOS 对齐）。
        """
        ts_files = []
        failed_segments = []
        total_segments = len(segments)
        success_count = 0
        # BYTERANGE 缺省 offset 时，接续同一 URI 上一段的结束位置 (RFC 8216)；
        # 切片线程共享只读常量 + 原子写，良性竞争
        next_offsets = {}

        with concurrent.futures.ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = [
                executor.submit(self._process_segment, seg, base_uri, temp_dir, idx,
                                media_sequence + idx, next_offsets)
                for idx, seg in enumerate(segments)
            ]

            for i, future in enumerate(futures):
                try:
                    path, seg_idx = future.result()
                    if path:
                        ts_files.append((seg_idx, path))
                        success_count += 1
                    else:
                        failed_segments.append(seg_idx)
                except Exception as e:
                    failed_segments.append(i)

                if progress_callback:
                    # 有回调时静默，进度由上层 (队列/GUI) 展示
                    progress_callback(i + 1, total_segments)
                else:
                    print(f"\r进度: {i+1}/{total_segments} | 成功: {success_count}", end="", flush=True)

        if not progress_callback:
            print("")  # 结束单行刷新，换行

        if failed_segments:
            self._log(f"⚠️  有 {len(failed_segments)} 个切片下载失败")

        ts_files.sort(key=lambda x: x[0])
        return [path for _, path in ts_files], failed_segments

    @retry(
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=20),
        retry=retry_if_exception_type((requests.exceptions.RequestException, Exception)),
        reraise=True
    )
    def _download_init_section(self, playlist, base_uri, temp_dir):
        """下载 fMP4 初始化段 (EXT-X-MAP)，返回本地路径；不存在则返回 None"""
        init_section = next(
            (s.init_section for s in playlist.segments if s.init_section), None
        )
        if not init_section:
            return None

        self._log("检测到 fMP4 流 (EXT-X-MAP)，下载初始化段...")
        init_url = urljoin(base_uri, init_section.uri)
        response = self._request(init_url)
        response.raise_for_status()

        init_path = temp_dir / "seg_init.mp4"
        with open(init_path, 'wb') as f:
            f.write(response.content)
        return init_path

    @retry(
        stop=stop_after_attempt(5),
        wait=wait_exponential(multiplier=1, min=2, max=20),
        retry=retry_if_exception_type((requests.exceptions.RequestException, Exception)),
        reraise=True
    )
    def _process_segment(self, segment, base_uri, temp_dir, seg_idx, seg_seq, next_offsets):
        """处理单个切片：下载（支持 BYTERANGE，iOS 同步） -> 解密 -> 保存"""
        try:
            seg_url = urljoin(base_uri, segment.uri)

            headers = None
            byterange = self._parse_byterange(segment.byterange)
            if byterange:
                length, offset = byterange
                if offset is None:
                    # 规范缺省：接续同一 URI 上一段的结束位置；首个该 URI 段从 0 起
                    offset = next_offsets.get(seg_url, 0)
                next_offsets[seg_url] = offset + length
                headers = {"Range": f"bytes={offset}-{offset + length - 1}"}

            response = self._request(seg_url, headers=headers)
            if response.status_code == 206:
                content = response.content
                if len(content) < length:
                    raise requests.exceptions.RequestException(
                        f"BYTERANGE 响应不足: 期望 {length} 字节, 实得 {len(content)}")
            elif response.status_code == 200 and byterange:
                # 服务器忽略 Range 返回全量：按绝对偏移截取所需段（offset 已含
                # 缺省接续；iOS 侧 trimToRange 只 prefix(length)，offset>0 时会截错，
                # 此处按规范完整实现）
                content = response.content[offset: offset + length]
                if len(content) < length:
                    raise requests.exceptions.RequestException(
                        f"服务器未支持 Range 且文件不足: 期望 {length}@{offset}, "
                        f"实得 {len(content)}")
            else:
                response.raise_for_status()
                content = response.content

            if segment.key and segment.key.method != 'NONE':
                # m3u8 库对 EXT-X-KEY:METHOD=NONE 生成 Key(method='NONE', uri=None)
                # 挂到后续段（对象非 None），必须同时看 method，否则明文段误进解密
                content = self._decrypt_content(content, segment, base_uri, seg_seq)

            temp_path = temp_dir / f"seg_{seg_idx:04d}.ts"
            with open(temp_path, 'wb') as f:
                f.write(content)
            return temp_path, seg_idx

        except Exception as e:
            print(f"\n切片 {seg_idx} 处理失败: {e}")
            raise

    @staticmethod
    def _parse_byterange(raw):
        """解析 #EXT-X-BYTERANGE:<n>[@<o>]（m3u8 库以字符串给出）；
        返回 (length, offset)，offset 缺省为 None（接续语义由调用方处理）；无值返回 None"""
        if not raw:
            return None
        text = raw.strip().strip('"')
        length_s, _, offset_s = text.partition("@")
        try:
            length = int(length_s)
        except ValueError:
            return None
        if length <= 0:
            return None
        try:
            offset = int(offset_s) if offset_s else None
        except ValueError:
            offset = None
        return length, offset

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        reraise=True
    )
    def _decrypt_content(self, content, segment, base_uri, seg_seq):
        """解密切片内容。KEY 未声明 IV 时按 RFC 8216 用 media sequence number 派生
        （iOS 侧已修正的缺省 IV bug，此为同步——旧实现传 None 落到全 0 IV）"""
        key_uri = segment.key.uri
        if not key_uri.startswith('http'):
             key_uri = urljoin(base_uri, key_uri)

        if key_uri not in self.key_cache:
            key_resp = self._request(key_uri)
            key_resp.raise_for_status()
            self.key_cache[key_uri] = key_resp.content

        key = self.key_cache[key_uri]
        if segment.key.iv:
            iv = bytes.fromhex(segment.key.iv.replace("0x", ""))
        else:
            iv = Decrypter.sequence_iv(seg_seq)

        return Decrypter.decrypt_aes_128(content, key, iv)

    def _merge_files(self, ts_files):
        """合并文件"""
        output_filename = generate_filename(
            title=self.output_filename, ext=".mp4", output_dir=self.download_dir
        )
        output_path = self.download_dir / output_filename

        with open(output_path, 'wb') as outfile:
            for ts_path in ts_files:
                with open(ts_path, 'rb') as infile:
                    outfile.write(infile.read())

        # TS 流重封装为标准 MP4（Preview/QuickTime 不支持裸 TS 流）
        self._remux_if_ts(output_path)
        return output_path

    def _remux_if_ts(self, output_path):
        """若合并结果是 MPEG-TS 流，用 ffmpeg 无损重封装为 MP4"""
        with open(output_path, 'rb') as f:
            head = f.read(189)
        if len(head) < 189 or head[0] != 0x47 or head[188] != 0x47:
            return  # 不是 TS 流（如 fMP4），无需处理

        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            self._log("⚠️ 未检测到 ffmpeg，输出为 TS 流，Preview/QuickTime 可能无法播放 (brew install ffmpeg)")
            return

        self._log("检测到 TS 流，使用 ffmpeg 无损重封装为 MP4...")
        tmp_path = output_path.with_name(output_path.stem + "_remux.mp4")
        cmd = [ffmpeg, '-y', '-loglevel', 'error', '-i', str(output_path),
               '-c', 'copy', '-bsf:a', 'aac_adtstoasc', str(tmp_path)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and tmp_path.exists() and tmp_path.stat().st_size > 0:
            tmp_path.replace(output_path)
            self._log("✅ 重封装完成，可被 Preview/QuickTime 直接播放")
        else:
            if tmp_path.exists():
                tmp_path.unlink()
            self._log(f"⚠️ ffmpeg 重封装失败，保留原始拼接结果: {result.stderr[:200]}")
