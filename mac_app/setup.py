"""py2app 打包配置

构建 .app:
    cd mac_app && python3 setup.py py2app

产物: mac_app/dist/Smart Downloader.app
"""
import sys
from pathlib import Path

# 让 modulefinder 能找到项目根目录下的 core 包
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from setuptools import setup

APP = ['main.py']
DATA_FILES = ['index.html', 'sniffer.js']
OPTIONS = {
    'argv_emulation': False,
    'packages': ['core'],
    'includes': ['webview', 'm3u8', 'requests', 'Crypto', 'tenacity'],
    'plist': {
        'CFBundleName': 'Smart Downloader',
        'CFBundleDisplayName': 'Smart Downloader',
        'CFBundleShortVersionString': '1.0.0',
        'CFBundleIdentifier': 'com.firefish.smart-downloader',
        'NSHumanReadableCopyright': 'For personal use only',
    },
}

setup(
    app=APP,
    name='Smart Downloader',
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
