import m3u8
import requests
import concurrent.futures
from urllib.parse import urljoin
from pathlib import Path
from core.utils import HEADERS, get_download_dir, create_temp_dir, clean_dir, generate_filename
from core.decrypter import Decrypter

class M3U8Downloader:
    def __init__(self, url, output_dir=None, output_filename=None, max_workers=10):
        self.url = url
        self.max_workers = max_workers
        self.download_dir = get_download_dir(custom_path=output_dir)
        self.output_filename = output_filename
        self.key_cache = {}

    def run(self, progress_callback=None):
        """
        执行下载流程
        :param progress_callback: 回调函数，接收 (current, total) 参数
        """
        temp_dir = create_temp_dir(self.download_dir)
        try:
            # 1. 解析 m3u8
            playlist, base_uri = self._load_playlist(self.url)
            
            # 2. 下载切片
            print(f"找到 {len(playlist.segments)} 个切片，开始下载...")
            ts_files = self._download_segments(playlist.segments, base_uri, temp_dir, progress_callback)
            
            # 3. 合并文件
            if ts_files:
                output_path = self._merge_files(ts_files)
                print(f"✅ 合并完成: {output_path}")
                return str(output_path), None
            else:
                msg = "❌ 没有下载到任何切片，可能是视频源不可用或解密失败"
                print(msg)
                return None, msg
                
        except Exception as e:
            msg = f"下载过程出错: {str(e)}"
            print(f"\n❌ {msg}")
            return None, msg
        finally:
            clean_dir(temp_dir)

    def _load_playlist(self, url):
        """加载并解析 m3u8，处理多级列表"""
        print(f"解析 m3u8: {url}")
        playlist = m3u8.load(url, headers=HEADERS)
        base_uri = url

        if playlist.is_variant:
            print("检测到多级播放列表，选择最高带宽流...")
            best_stream = max(playlist.playlists, key=lambda p: p.stream_info.bandwidth)
            print(f"选择流: {best_stream.uri}")
            
            sub_url = urljoin(url, best_stream.uri)
            print(f"子列表完整 URL: {sub_url}")
            playlist = m3u8.load(sub_url, headers=HEADERS)
            base_uri = sub_url
            
        return playlist, base_uri

    def _download_segments(self, segments, base_uri, temp_dir, progress_callback=None):
        """并发下载切片"""
        ts_files = []
        total_segments = len(segments)
        
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = [
                executor.submit(self._process_segment, seg, base_uri, temp_dir) 
                for seg in segments
            ]
            
            for i, future in enumerate(futures):
                path = future.result()
                if path:
                    ts_files.append(path)
                    print(f"\r进度: {i+1}/{total_segments}", end="", flush=True)
                    if progress_callback:
                        progress_callback(i + 1, total_segments)
                else:
                    print(f"\n切片 {i} 下载失败")
        print("") # 换行
        return ts_files

    def _process_segment(self, segment, base_uri, temp_dir):
        """处理单个切片：下载 -> 解密 -> 保存"""
        try:
            # URL 拼接
            seg_url = urljoin(base_uri, segment.uri)
            
            # 下载内容
            response = requests.get(seg_url, headers=HEADERS, timeout=10)
            response.raise_for_status()
            content = response.content
            
            # 解密处理
            if segment.key:
                content = self._decrypt_content(content, segment, base_uri)

            # 保存
            temp_path = temp_dir / f"seg_{generate_filename('.ts')}"
            with open(temp_path, 'wb') as f:
                f.write(content)
            return temp_path
            
        except Exception as e:
            print(f"切片处理失败 {segment.uri}: {e}")
            return None

    def _decrypt_content(self, content, segment, base_uri):
        """解密切片内容"""
        key_uri = segment.key.uri
        if not key_uri.startswith('http'):
             key_uri = urljoin(base_uri, key_uri)
        
        # 获取 Key (带缓存)
        if key_uri not in self.key_cache:
            key_resp = requests.get(key_uri, headers=HEADERS, timeout=10)
            key_resp.raise_for_status()
            self.key_cache[key_uri] = key_resp.content
        
        key = self.key_cache[key_uri]
        iv = bytes.fromhex(segment.key.iv.replace("0x", "")) if segment.key.iv else None
        
        return Decrypter.decrypt_aes_128(content, key, iv)

    def _merge_files(self, ts_files):
        """合并文件"""
        output_filename = generate_filename(title=self.output_filename, ext=".mp4")
        output_path = self.download_dir / output_filename

        with open(output_path, 'wb') as outfile:
            for ts_path in ts_files:
                with open(ts_path, 'rb') as infile:
                    outfile.write(infile.read())
        return output_path
