import os
import shutil
import uuid
import requests
from pathlib import Path
from urllib.parse import urlparse

# 全局配置
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

def validate_url(url):
    """
    验证 URL 有效性
    :param url: 输入 URL
    :return: (bool, str) -> (是否有效, 错误信息)
    """
    if not url:
        return False, "URL 不能为空"
        
    # 1. 格式检查
    try:
        parsed = urlparse(url)
        if not all([parsed.scheme, parsed.netloc]):
            return False, "URL 格式不正确 (需包含 http/https)"
        if parsed.scheme not in ['http', 'https']:
            return False, "仅支持 http 或 https 协议"
    except Exception:
        return False, "URL 解析失败"

    # 2. 连通性检查 (HEAD 请求)
    try:
        response = requests.head(url, headers=HEADERS, timeout=5, allow_redirects=True)
        # 405 Method Not Allowed 有时会对 HEAD 返回，尝试 GET
        if response.status_code == 405:
            response = requests.get(url, headers=HEADERS, timeout=5, stream=True)
            response.close()
            
        if 400 <= response.status_code < 600:
            return False, f"URL 无法访问，状态码: {response.status_code}"
            
    except requests.RequestException as e:
        return False, f"连接失败: {str(e)}"

    return True, "URL 有效"

def get_download_dir(subdir="tx"):
    """获取下载目录，确保存在"""
    download_dir = Path.home() / "Downloads" / subdir
    download_dir.mkdir(parents=True, exist_ok=True)
    return download_dir

def create_temp_dir(base_dir):
    """创建临时目录"""
    temp_dir = base_dir / f"temp_{uuid.uuid4().hex}"
    temp_dir.mkdir(exist_ok=True)
    return temp_dir

def clean_dir(dir_path):
    """清理目录"""
    if dir_path.exists():
        shutil.rmtree(dir_path)
        print(f"临时文件已清理: {dir_path}")

def generate_filename(ext=".mp4"):
    """生成随机文件名"""
    return f"{uuid.uuid4().hex}{ext}"
