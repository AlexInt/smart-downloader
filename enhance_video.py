#!/usr/bin/env python3
"""
视频增强工具 - 使用 Real-ESRGAN 进行超分辨率处理
支持 Mac M3 Pro GPU 加速
"""

import os
import sys
import subprocess
import argparse
import shutil
from pathlib import Path
import tempfile


class VideoEnhancer:
    def __init__(self):
        self.project_root = Path(__file__).parent
        self.realesrgan_path = self.project_root / "tools/realesrgan/realesrgan-ncnn-vulkan"
        self.models_path = self.project_root / "tools/realesrgan/models"
        
        if not self.realesrgan_path.exists():
            raise FileNotFoundError(
                f"Real-ESRGAN 未安装，请先运行:\n"
                f"cd tools && mkdir -p realesrgan && cd realesrgan\n"
                f"curl -L -o realesrgan.zip https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip\n"
                f"unzip realesrgan.zip"
            )
        
        if not shutil.which("ffmpeg"):
            raise FileNotFoundError("ffmpeg 未安装，请先运行: brew install ffmpeg")
    
    def enhance_video(self, input_path: str, output_path: str = None, scale: int = 2, model: str = "realesrgan-x4plus"):
        """
        增强视频质量
        
        Args:
            input_path: 输入视频路径
            output_path: 输出视频路径（可选，默认在原文件名后添加 _enhanced）
            scale: 放大倍数 (2, 3, 4)
            model: 模型名称
                - realesrgan-x4plus: 通用模型（推荐）
                - realesrgan-x4plus-anime: 动画专用
                - realesr-animevideov3: 动画视频专用（速度快）
        """
        input_path = Path(input_path).resolve()
        
        if not input_path.exists():
            raise FileNotFoundError(f"输入文件不存在: {input_path}")
        
        if output_path is None:
            output_path = input_path.parent / f"{input_path.stem}_{scale}x_enhanced.mp4"
        else:
            output_path = Path(output_path).resolve()
        
        print(f"🎬 开始视频增强...")
        print(f"   输入: {input_path}")
        print(f"   输出: {output_path}")
        print(f"   放大倍数: {scale}x")
        print(f"   模型: {model}")
        print(f"   使用设备: Apple M3 Pro GPU")
        
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir = Path(temp_dir)
            frames_dir = temp_dir / "frames"
            enhanced_dir = temp_dir / "enhanced"
            frames_dir.mkdir()
            enhanced_dir.mkdir()
            
            print(f"\n📹 步骤 1/3: 提取视频帧...")
            cmd = [
                "ffmpeg", "-i", str(input_path),
                "-qscale:v", "2",
                str(frames_dir / "frame_%08d.png")
            ]
            subprocess.run(cmd, capture_output=True, check=True)
            
            frame_count = len(list(frames_dir.glob("*.png")))
            print(f"   提取了 {frame_count} 帧")
            
            print(f"\n🎨 步骤 2/3: AI 增强帧...")
            cmd = [
                str(self.realesrgan_path),
                "-i", str(frames_dir),
                "-o", str(enhanced_dir),
                "-s", str(scale),
                "-n", model,
                "-m", str(self.models_path),
                "-f", "png"
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"❌ 增强失败: {result.stderr}")
                return None
            
            enhanced_count = len(list(enhanced_dir.glob("*.png")))
            print(f"   增强了 {enhanced_count} 帧")
            
            print(f"\n🎬 步骤 3/3: 合成视频...")
            
            probe_cmd = [
                "ffprobe", "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=r_frame_rate,width,height",
                "-of", "csv=p=0",
                str(input_path)
            ]
            probe_result = subprocess.run(probe_cmd, capture_output=True, text=True, check=True)
            fps, orig_width, orig_height = probe_result.stdout.strip().split(',')
            
            new_width = int(orig_width) * scale
            new_height = int(orig_height) * scale
            
            cmd = [
                "ffmpeg",
                "-framerate", fps,
                "-i", str(enhanced_dir / "frame_%08d.png"),
                "-i", str(input_path),
                "-map", "0:v",
                "-map", "1:a?",
                "-c:v", "libx264",
                "-preset", "medium",
                "-crf", "23",
                "-c:a", "copy",
                "-s", f"{new_width}x{new_height}",
                "-y",
                str(output_path)
            ]
            
            subprocess.run(cmd, capture_output=True, check=True)
            
            print(f"\n✅ 视频增强完成: {output_path}")
            
            input_size = input_path.stat().st_size / (1024 * 1024)
            output_size = output_path.stat().st_size / (1024 * 1024)
            print(f"   原始大小: {input_size:.2f} MB")
            print(f"   增强后大小: {output_size:.2f} MB")
            print(f"   分辨率: {orig_width}x{orig_height} → {new_width}x{new_height}")
            
            return str(output_path)
    
    def batch_enhance(self, input_dir: str, output_dir: str = None, scale: int = 2, model: str = "realesrgan-x4plus"):
        """
        批量增强目录中的所有视频
        
        Args:
            input_dir: 输入目录
            output_dir: 输出目录（可选）
            scale: 放大倍数
            model: 模型名称
        """
        input_dir = Path(input_dir).resolve()
        
        if not input_dir.exists():
            raise FileNotFoundError(f"输入目录不存在: {input_dir}")
        
        if output_dir is None:
            output_dir = input_dir / "enhanced"
        else:
            output_dir = Path(output_dir).resolve()
        
        output_dir.mkdir(parents=True, exist_ok=True)
        
        video_extensions = ['.mp4', '.avi', '.mkv', '.mov', '.flv', '.wmv']
        video_files = []
        for ext in video_extensions:
            video_files.extend(input_dir.glob(f"*{ext}"))
        
        if not video_files:
            print(f"❌ 在 {input_dir} 中未找到视频文件")
            return
        
        print(f"🎬 找到 {len(video_files)} 个视频文件")
        
        success_count = 0
        for i, video_file in enumerate(video_files, 1):
            print(f"\n[{i}/{len(video_files)}] 处理: {video_file.name}")
            output_path = output_dir / f"{video_file.stem}_{scale}x_enhanced.mp4"
            
            result = self.enhance_video(str(video_file), str(output_path), scale, model)
            if result:
                success_count += 1
        
        print(f"\n🎉 批量处理完成: {success_count}/{len(video_files)} 成功")


def main():
    parser = argparse.ArgumentParser(description="视频增强工具 - 使用 AI 提升视频清晰度")
    parser.add_argument("input", help="输入视频文件或目录路径")
    parser.add_argument("-o", "--output", help="输出视频文件或目录路径（可选）")
    parser.add_argument("-s", "--scale", type=int, default=2, choices=[2, 3, 4], 
                       help="放大倍数 (默认: 2)")
    parser.add_argument("-m", "--model", default="realesrgan-x4plus",
                       choices=["realesrgan-x4plus", "realesrgan-x4plus-anime", "realesr-animevideov3"],
                       help="模型类型 (默认: realesrgan-x4plus)")
    parser.add_argument("-b", "--batch", action="store_true", help="批量处理目录中的所有视频")
    
    args = parser.parse_args()
    
    try:
        enhancer = VideoEnhancer()
        
        if args.batch:
            enhancer.batch_enhance(args.input, args.output, args.scale, args.model)
        else:
            enhancer.enhance_video(args.input, args.output, args.scale, args.model)
            
    except Exception as e:
        print(f"❌ 错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
