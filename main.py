import argparse
import sys
from core.extractor import WebExtractor
from core.downloader import M3U8Downloader
from core.utils import validate_url

def main():
    parser = argparse.ArgumentParser(description="智能 m3u8 下载器 (模块化版)")
    parser.add_argument("input", help="m3u8 URL 或 包含视频的网页 URL")
    parser.add_argument("-o", "--output", help="指定输出目录 (默认: ~/Downloads/tx)", default=None)
    args = parser.parse_args()
    
    target_url = args.input
    output_dir = args.output
    
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
        video_title = None # 直接 m3u8 没有标题
    else:
        print("识别为网页链接，开始尝试解析...")
        extractor = WebExtractor()
        extracted_url, extracted_title = extractor.extract_m3u8(target_url)
        
        if extracted_url:
            print(f"✅ 成功提取 m3u8 URL: {extracted_url}")
            if extracted_title:
                print(f"✅ 提取到视频标题: {extracted_title}")
            target_url = extracted_url
            video_title = extracted_title
        else:
            print("❌ 未能在网页中找到 m3u8 链接。")
            sys.exit(1)
            
    # 2. 执行下载
    print("-" * 30)
    print("启动下载流程...")
    if output_dir:
        print(f"目标输出目录: {output_dir}")
    
    downloader = M3U8Downloader(target_url, output_dir=output_dir, output_filename=video_title)
    result, error = downloader.run()
    
    if result:
        print(f"🎉 任务全部完成！文件位于: {result}")
    else:
        print(f"❌ 任务失败: {error}")
        sys.exit(1)

if __name__ == "__main__":
    main()
