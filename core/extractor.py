import time
import re
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from webdriver_manager.chrome import ChromeDriverManager

class WebExtractor:
    def __init__(self, headless=True):
        self.options = Options()
        if headless:
            self.options.add_argument("--headless")
        self.options.add_argument("--no-sandbox")
        self.options.add_argument("--disable-dev-shm-usage")
        self.options.add_argument("user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        
    def extract_m3u8(self, url):
        """
        从网页中提取 m3u8 地址和标题
        :return: (m3u8_url, title) 或 (None, None)
        """
        print(f"正在加载网页: {url}")
        driver = None
        try:
            service = Service(ChromeDriverManager().install())
            driver = webdriver.Chrome(service=service, options=self.options)
            
            driver.get(url)
            time.sleep(5) # 等待加载
            
            # 尝试提取标题
            title = self._extract_title(driver)
            print(f"提取到的网页标题: {title}")
            
            # 策略 1: DOM 查找
            found = self._find_in_dom(driver)
            if found: return found, title
            
            # 策略 2: 源码正则
            found = self._find_in_source(driver)
            if found: return found, title
            
            return None, None
            
        except Exception as e:
            print(f"网页解析出错: {e}")
            return None, None
        finally:
            if driver:
                driver.quit()

    def _extract_title(self, driver):
        """提取网页标题作为文件名"""
        title = ""
        try:
            # 1. 优先尝试 h1 class="title"
            try:
                h1 = driver.find_element(By.CSS_SELECTOR, "h1.title")
                title = h1.text.strip()
            except:
                pass
            
            # 2. 尝试 title 标签
            if not title:
                title = driver.title.strip()
                
            # 清理非法字符
            if title:
                title = re.sub(r'[\\/*?:"<>|]', "", title) # 移除文件名非法字符
                title = title.replace(" ", "_") # 空格转下划线
                
        except:
            pass
        return title if title else None

    def _clean_url(self, url):
        """清洗 URL，处理嵌套情况"""
        # 如果 URL 包含参数且参数本身也是 url (如 ?url=http...)，提取真实地址
        if "url=" in url:
            match = re.search(r'url=(https?://.+?\.m3u8)', url)
            if match:
                cleaned = match.group(1)
                print(f"清洗 URL: 从参数中提取 -> {cleaned}")
                return cleaned
        return url

    def _find_in_dom(self, driver):
        """查找 video/source 标签"""
        print("尝试从 DOM 查找视频链接...")
        try:
            video_elements = driver.find_elements(By.TAG_NAME, "video")
            for video in video_elements:
                src = video.get_attribute("src")
                if src and ".m3u8" in src:
                    print(f"在 <video> 标签中找到: {src}")
                    return self._clean_url(src)
                
                sources = video.find_elements(By.TAG_NAME, "source")
                for source in sources:
                    src = source.get_attribute("src")
                    if src and ".m3u8" in src:
                        print(f"在 <source> 标签中找到: {src}")
                        return self._clean_url(src)
        except:
            pass
        return None

    def _find_in_source(self, driver):
        """正则匹配源码"""
        print("尝试从页面源码正则匹配...")
        page_source = driver.page_source
        
        # 标准匹配
        match = re.search(r'(https?://[^\s"\'<>]+?\.m3u8)', page_source)
        if match:
            found = match.group(1)
            print(f"正则匹配找到: {found}")
            return self._clean_url(found)
            
        # 转义匹配
        match_escaped = re.search(r'(https?:\\?/\\?/[^\s"\'<>]+?\.m3u8)', page_source)
        if match_escaped:
            found = match_escaped.group(1).replace('\\/', '/')
            print(f"正则匹配找到(转义): {found}")
            return self._clean_url(found)
            
        return None
