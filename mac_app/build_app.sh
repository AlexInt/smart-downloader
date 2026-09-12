#!/bin/bash
# Mac App 一键构建脚本
# 产物: dist/Smart Downloader.app
set -e
cd "$(dirname "$0")"

PYTHON=${PYTHON:-python3}
CONDA_LIB="$(dirname "$(dirname "$($PYTHON -c 'import sys; print(sys.executable)')")")/lib"

echo "==> 清理旧构建"
rm -rf build dist

echo "==> py2app 构建"
"$PYTHON" setup.py py2app

APP="dist/Smart Downloader.app"
LIB_DIR="$APP/Contents/Resources/lib"

echo "==> 补齐 conda 环境动态库 (py2app 不会自动打包)"
for so in "$LIB_DIR/python3.12/lib-dynload/"*.so; do
    otool -L "$so" 2>/dev/null | grep '@rpath' | sed 's/.*@rpath\///; s/ .*//'
done | sort -u | while read -r dylib; do
    if [ ! -f "$LIB_DIR/$dylib" ] && [ -f "$CONDA_LIB/$dylib" ]; then
        cp "$CONDA_LIB/$dylib" "$LIB_DIR/"
        echo "    已补: $dylib"
    fi
done

echo "==> 构建完成: $APP"
du -sh "$APP"
