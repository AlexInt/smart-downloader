import argparse
import sys
from pathlib import Path

from core.extractor import WebExtractor
from core.queue import DownloadQueue
from core.utils import validate_url


def resolve_target(url):
    """将输入 URL 解析为 (m3u8_url, title)。网页链接先提取 m3u8，失败返回 (None, None)"""
    if ".m3u8" in url and not url.strip().endswith(".html"):
        print("识别为直接 m3u8 链接")
        return url, None

    print("识别为网页链接，开始尝试解析...")
    extractor = WebExtractor()
    extracted_url, extracted_title = extractor.extract_m3u8(url)
    if not extracted_url:
        print("❌ 未能在网页中找到 m3u8 链接。")
        return None, None
    print(f"✅ 成功提取 m3u8 URL: {extracted_url}")
    if extracted_title:
        print(f"✅ 提取到视频标题: {extracted_title}")
    return extracted_url, extracted_title


def main():
    parser = argparse.ArgumentParser(description="智能 m3u8 下载器 (模块化版)")
    parser.add_argument("input", nargs="+",
                        help="m3u8 URL 或网页 URL，支持多个，空格分隔")
    parser.add_argument("-o", "--output", help="指定输出目录 (默认: ~/Downloads/tx)", default=None)
    parser.add_argument("-f", "--file", help="从文本文件批量读取 URL (每行一个，# 开头为注释)",
                        default=None)
    parser.add_argument("-j", "--jobs", type=int, default=1,
                        help="同时下载的视频数 (任务级并行，默认 1 即串行)")
    args = parser.parse_args()

    # 汇总输入: 命令行参数 + 文件
    urls = list(args.input)
    if args.file:
        path = Path(args.file).expanduser()
        if not path.is_file():
            print(f"❌ 文件不存在: {path}")
            sys.exit(1)
        file_urls = [
            line.strip() for line in path.read_text(encoding='utf-8').splitlines()
            if line.strip() and not line.strip().startswith('#')
        ]
        print(f"从 {path} 读取到 {len(file_urls)} 个 URL")
        urls += file_urls

    if not urls:
        print("❌ 没有可下载的 URL")
        sys.exit(1)

    print(f"共 {len(urls)} 个链接，并行数: {args.jobs}")
    print("-" * 30)

    # URL 有效性预检 + 网页解析，全部转成 m3u8 直链
    targets = []
    for url in urls:
        print(f"正在检查 URL 有效性: {url[:80]}")
        is_valid, message = validate_url(url)
        if not is_valid:
            print(f"❌ URL 无效: {message}")
            continue
        print("✅ URL 格式与连通性检查通过")

        m3u8_url, title = resolve_target(url)
        if m3u8_url:
            targets.append((m3u8_url, title))

    if not targets:
        print("❌ 没有有效的下载目标")
        sys.exit(1)

    if len(targets) > 1:
        print("-" * 30)
        print(f"启动队列下载: {len(targets)} 个任务...")

    queue = DownloadQueue(max_parallel=args.jobs)
    for m3u8_url, title in targets:
        queue.add(m3u8_url, title=title, output_dir=args.output)
    queue.run(wait=True)

    # 结果汇总
    done, failed = queue.results()
    print("-" * 30)
    print(f"🎉 全部完成: 成功 {len(done)} / {len(targets)}")
    for name, output in done:
        print(f"  ✅ {name} -> {output}")
    for name, error in failed:
        print(f"  ❌ {name}: {error}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
