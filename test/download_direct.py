#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
B站 Windows 客户端下载脚本

此脚本用于自动下载 B 站 Windows 客户端安装包
下载链接: https://dl.hdslb.com/mobile/fixed/bili_win/bili_win-install.exe?v=1.17.5-4&spm_id_from=333.47.b_646f776e6c6f61642d6c696e6b.9
"""

import os
import requests
from tqdm import tqdm


def download_file(url, save_path=None, chunk_size=1024):
    """
    下载文件并显示进度
    
    Args:
        url (str): 下载链接
        save_path (str): 保存路径，默认保存在当前目录
        chunk_size (int): 分块大小，默认 1024 bytes
        
    Returns:
        str: 下载完成后的文件路径
    """
    try:
        # 发送 HEAD 请求获取文件信息
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
        }
        
        response = requests.head(url, headers=headers, allow_redirects=True)
        response.raise_for_status()
        
        # 获取文件名
        if save_path is None:
            # 从 URL 中提取文件名
            if 'filename=' in response.headers.get('Content-Disposition', ''):
                filename = response.headers['Content-Disposition'].split('filename=')[1].strip('"')
            else:
                filename = url.split('/')[-1].split('?')[0]
            save_path = os.path.join(os.getcwd(), filename)
        
        # 获取文件大小
        file_size = int(response.headers.get('Content-Length', 0))
        
        print(f"开始下载文件: {os.path.basename(save_path)}")
        print(f"文件大小: {file_size / (1024 * 1024):.2f} MB")
        print(f"保存路径: {save_path}")
        
        # 发送 GET 请求下载文件
        response = requests.get(url, headers=headers, stream=True, allow_redirects=True)
        response.raise_for_status()
        
        # 确保目录存在
        os.makedirs(os.path.dirname(save_path), exist_ok=True)
        
        # 下载文件并显示进度
        with open(save_path, 'wb') as file, tqdm(
            desc=os.path.basename(save_path),
            total=file_size,
            unit='B',
            unit_scale=True,
            unit_divisor=1024,
            leave=True
        ) as pbar:
            for data in response.iter_content(chunk_size=chunk_size):
                file.write(data)
                pbar.update(len(data))
        
        print(f"\n下载完成！文件保存在: {save_path}")
        return save_path
        
    except requests.exceptions.RequestException as e:
        print(f"下载失败: {e}")
        return None
    except Exception as e:
        print(f"发生错误: {e}")
        return None


if __name__ == "__main__":
    # 下载链接
    bili_download_url = "https://dl.hdslb.com/mobile/fixed/bili_win/bili_win-install.exe?v=1.17.5-4&spm_id_from=333.47.b_646f776e6c6f61642d6c696e6b.9"
    
    # 执行下载
    print("B站 Windows 客户端下载脚本")
    print("=" * 50)
    
    # 检查是否安装了 tqdm
    try:
        from tqdm import tqdm
    except ImportError:
        print("正在安装 tqdm 库（用于显示下载进度）...")
        import subprocess
        import sys
        subprocess.check_call([sys.executable, "-m", "pip", "install", "tqdm"])
        print("tqdm 安装完成！")
    
    # 开始下载
    download_file(bili_download_url)
    
    print("\n脚本执行完成！")
