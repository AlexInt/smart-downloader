import os
import shutil
import uuid
import requests
import urllib3
from pathlib import Path
from urllib.parse import urlparse

# 禁用 SSL 警告
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

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

    # 2. 连通性检查
    # 某些服务器反爬严格，需要更完整的 Headers
    check_headers = HEADERS.copy()
    check_headers.update({
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1"
    })
    
    try:
        # 增加超时时间到 15秒，并禁用 verify (应对自签名证书)
        response = requests.get(
            url, 
            headers=check_headers, 
            timeout=15, 
            stream=True, 
            verify=False 
        )
        response.close() # 只要能建立连接即可，不需要下载内容
            
        if 400 <= response.status_code < 600:
            # 403/404 可能是反爬误判，如果是网页，放行让 Selenium 尝试
            if response.status_code == 403 and (".html" in url or ".php" in url):
                print(f"⚠️ 检测到 403，但可能是反爬，放行尝试: {url}")
                return True, "403但放行"
            return False, f"URL 无法访问，状态码: {response.status_code}"
            
    except requests.exceptions.SSLError:
        print("⚠️ SSL 验证失败，尝试忽略证书错误...")
        return True, "SSL警告" # 忽略 SSL 错误，继续尝试
    except requests.RequestException as e:
        # 即使 requests 失败，如果是 ReadTimeout，可能是服务器响应慢，也可以尝试放行
        if "Read timed out" in str(e):
             print(f"⚠️ 连接超时，但尝试强制放行: {url}")
             return True, "超时强制放行"
        return False, f"连接失败: {str(e)}"

    return True, "URL 有效"

def get_download_dir(custom_path=None, subdir="tx"):
    """
    获取下载目录，会自动创建不存在的目录
    :param custom_path: 用户指定的绝对或相对路径
    :param subdir: 默认子目录（仅在无 custom_path 时生效）
    :return: Path 对象
    :raises: OSError 如果无法创建目录
    """
    if custom_path:
        download_dir = Path(custom_path).expanduser().resolve()
    else:
        download_dir = Path.home() / "Downloads" / subdir

    # 安全检查：限制在用户主目录下
    allowed_root = Path.home().resolve()
    try:
        # 使用 is_relative_to (Python 3.9+) 或 relative_to
        download_dir.relative_to(allowed_root)
    except ValueError:
        raise PermissionError(f"❌ 安全限制：只允许在 {allowed_root} 目录下保存文件，您指定的目录是: {download_dir}")
        
    try:
        download_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"❌ 无法创建下载目录 {download_dir}: {e}")
        # 如果无法创建，回退到系统临时目录或抛出异常
        raise e
        
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

import time
from pathlib import Path

# ... (保留其他 import)

# 全局计数器，用于防止同一秒内文件名冲突
_filename_counter = 0

def generate_filename(title=None, ext=".mp4"):
    """
    生成文件名
    :param title: 网页标题（可选）
    :param ext: 扩展名
    """
    global _filename_counter
    
    # 1. 如果有标题，优先使用标题
    if title:
        # 确保标题中没有非法字符 (在 extractor 中已经处理过一部分，这里兜底)
        safe_title = "".join([c for c in title if c.isalnum() or c in "._- "]).strip()
        if safe_title:
            return f"{safe_title}{ext}"
            
    # 2. 如果没有标题，使用时间戳+序号 (YYYYMMDD_HHMMSS_001)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    _filename_counter = (_filename_counter + 1) % 1000
    return f"{timestamp}_{_filename_counter:03d}{ext}"
