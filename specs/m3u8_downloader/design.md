# 技术方案设计

## 介绍

本方案描述了如何实现一个 Python 脚本，用于下载 m3u8 视频流并将其保存为 MP4 格式，文件名随机生成，保存位置为 `~/Downloads/tx`。

## 架构设计

### 核心流程

1.  **输入解析**: 脚本接收命令行参数（m3u8 URL）。
2.  **环境准备**: 检查并创建目标目录 `~/Downloads/tx`。
3.  **文件名生成**: 使用 UUID 库生成唯一文件名。
4.  **下载执行**: 调用系统安装的 `ffmpeg` 工具进行流下载和转换。
5.  **反馈输出**: 打印下载结果或错误信息。

### 技术选型

-   **编程语言**: Python 3
    -   原因：标准库丰富（`subprocess`, `pathlib`, `uuid`），易于编写和维护，且项目已有 Python 环境。
-   **核心工具**: ffmpeg
    -   原因：业界标准的视频处理工具，支持 m3u8 流下载和容器转换（-c copy）。
-   **依赖库**:
    -   `argparse`: 用于解析命令行参数。
    -   `pathlib`: 用于跨平台路径处理。
    -   `uuid`: 用于生成随机文件名。
    -   `subprocess`: 用于调用外部 ffmpeg 命令。

## 详细设计

### 目录结构

```
downloader-py/
├── download_random_m3u8.py  # 新增脚本
├── specs/
│   └── m3u8_downloader/
│       ├── requirements.md
│       ├── design.md
│       └── tasks.md
└── ...
```

### 关键逻辑代码片段

```python
import argparse
import subprocess
import uuid
from pathlib import Path

def main():
    # 1. 解析参数
    parser = argparse.ArgumentParser(description="下载 m3u8 并保存为随机命名的 MP4")
    parser.add_argument("url", help="m3u8 视频流地址")
    args = parser.parse_args()

    # 2. 准备目录
    download_dir = Path.home() / "Downloads" / "tx"
    download_dir.mkdir(parents=True, exist_ok=True)

    # 3. 生成文件名
    filename = f"{uuid.uuid4().hex}.mp4"
    output_path = download_dir / filename

    # 4. 调用 ffmpeg
    cmd = [
        "ffmpeg",
        "-i", args.url,
        "-c", "copy",
        "-bsf:a", "aac_adtstoasc", # 可选，防止音频格式错误
        str(output_path)
    ]
    
    try:
        subprocess.run(cmd, check=True)
        print(f"下载成功: {output_path}")
    except subprocess.CalledProcessError as e:
        print(f"下载失败: {e}")

if __name__ == "__main__":
    main()
```

### 安全性与错误处理

-   **输入验证**: 简单验证 URL 是否非空。
-   **错误捕获**: 捕获 `subprocess.CalledProcessError` 以处理 ffmpeg 执行失败的情况。
-   **路径安全**: 使用 `pathlib` 确保路径拼接正确，虽然是本地脚本，但也遵循最佳实践。

## 测试策略

1.  **手动测试**: 使用公开的测试用 m3u8 链接运行脚本。
2.  **验证**: 检查 `~/Downloads/tx` 目录下是否生成了新的 MP4 文件，且能够正常播放。
