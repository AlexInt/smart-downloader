import argparse
import sys
from core.extractor import WebExtractor
from core.downloader import M3U8Downloader
from core.utils import validate_url

def main():
    parser = argparse.ArgumentParser(description="智能 m3u8 下载器 (模块化版)")
    parser.add_argument("input", help="m3u8 URL 或 包含视频的网页 URL")
    args = parser.parse_args()
    
    target_url = args.input
    
    # 0. 基础有效性检测
    print("正在检查 URL 有效性...")
    is_valid, message = validate_url(target_url)
    if not is_valid:
        print(f"❌ URL 无效: {message}")
        sys.exit(1)
    print("✅ URL 格式与连通性检查通过")

    # 1. 输入处理
    if ".m3u8" in target_url and not target_url.strip().endswith(".html"):
        print("识别为直接 m3u8 链接")
    else:
        print("识别为网页链接，开始尝试解析...")
        extractor = WebExtractor()
        extracted_url = extractor.extract_m3u8(target_url)
        
        if extracted_url:
            print(f"✅ 成功提取 m3u8 URL: {extracted_url}")
            target_url = extracted_url
        else:
            print("❌ 未能在网页中找到 m3u8 链接。")
            sys.exit(1)
            
    # 2. 执行下载
    print("-" * 30)
    print("启动下载流程...")
    
    downloader = M3U8Downloader(target_url)
    result = downloader.run()
    
    if result:
        print(f"🎉 任务全部完成！文件位于: {result}")
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()
