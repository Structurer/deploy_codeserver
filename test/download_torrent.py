#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
种子文件下载脚本（兼容版）

使用 libtorrent 库的基本 API 实现 BT 下载功能
适用于大多数 libtorrent 版本
"""

import os
import sys
import time
import libtorrent as lt

def download_torrent(torrent_source, save_path=None, timeout=3600):
    """
    通过种子文件或磁力链接下载内容
    使用最基本的 API 以提高兼容性
    """
    try:
        # 创建会话
        ses = lt.session()
        
        # 设置保存路径
        if save_path is None:
            save_path = os.path.join(os.getcwd(), "downloads")
        
        # 确保保存目录存在
        os.makedirs(save_path, exist_ok=True)
        
        print(f"开始下载，保存路径: {save_path}")
        
        # 添加下载任务
        if torrent_source.startswith('magnet:'):
            # 使用磁力链接
            # 使用最基本的参数格式
            params = {
                'save_path': save_path,
            }
            
            # 尝试不同的添加磁力链接方法
            try:
                # 方法1: 使用 add_torrent
                handle = ses.add_torrent({
                    'url': torrent_source,
                    'save_path': save_path,
                })
                print("添加磁力链接成功（方法1）")
            except Exception as e1:
                try:
                    # 方法2: 使用 add_magnet_uri（旧版本）
                    handle = ses.add_magnet_uri(torrent_source, params)
                    print("添加磁力链接成功（方法2）")
                except Exception as e2:
                    print(f"添加磁力链接失败: {e1}, {e2}")
                    return False
            
            # 等待元数据下载完成
            print("正在获取种子元数据...")
            while not handle.has_metadata():
                time.sleep(1)
            print("获取元数据完成")
        else:
            # 使用种子文件
            if not os.path.exists(torrent_source):
                print(f"错误：种子文件不存在: {torrent_source}")
                return False
            
            # 加载种子文件
            torrent_info = lt.torrent_info(torrent_source)
            
            # 添加下载任务
            try:
                handle = ses.add_torrent({
                    'ti': torrent_info,
                    'save_path': save_path,
                })
                print(f"添加种子文件成功: {os.path.basename(torrent_source)}")
            except Exception as e:
                print(f"添加种子文件失败: {e}")
                return False
        
        # 获取 torrent 信息
        torrent_name = handle.name()
        print(f"下载内容: {torrent_name}")
        
        # 开始下载
        print("开始下载...")
        start_time = time.time()
        
        # 显示下载进度
        while True:
            status = handle.status()
            
            # 检查是否完成
            if status.is_seeding:
                break
            
            # 计算下载进度
            progress = status.progress * 100
            download_rate = status.download_rate / 1024 / 1024  # MB/s
            upload_rate = status.upload_rate / 1024 / 1024  # MB/s
            peers = status.num_peers
            
            # 计算剩余时间
            if status.download_rate > 0:
                remaining_bytes = status.total_wanted - status.total_done
                remaining_time = remaining_bytes / status.download_rate
                remaining_str = time.strftime('%H:%M:%S', time.gmtime(remaining_time))
            else:
                remaining_str = "未知"
            
            # 清除当前行并显示新进度
            sys.stdout.write('\r')
            sys.stdout.flush()
            sys.stdout.write(f"进度: {progress:.2f}% | 下载: {download_rate:.2f} MB/s | 上传: {upload_rate:.2f} MB/s |  peers: {peers} | 剩余时间: {remaining_str}")
            sys.stdout.flush()
            
            # 检查超时
            if time.time() - start_time > timeout:
                print("\n错误：下载超时")
                return False
            
            time.sleep(1)
        
        print("\n下载完成！")
        print(f"内容已保存到: {save_path}")
        
        return True
        
    except ImportError:
        print("错误：未安装 libtorrent 库")
        print("请运行: pip install libtorrent-python")
        return False
    except Exception as e:
        print(f"\n下载失败: {e}")
        print("提示：不同版本的 libtorrent API 可能有差异")
        print("建议尝试使用其他版本的 libtorrent 或使用专用的 BT 客户端")
        return False

if __name__ == "__main__":
    print("种子文件下载脚本（兼容版）")
    print("=" * 50)
    
    # 示例：Ubuntu 24.04 LTS 桌面版（合法开源软件）
    example_magnet_link = "magnet:?xt=urn:btih:4b3c6f9a0c2e8e5f9b8d7a6c5d4e3f2a1b0c9d8e7f6e5d4c3b2a1&dn=ubuntu-24.04-desktop-amd64.iso&tr=http://tracker.example.com/announce"
    
    print("示例种子：Ubuntu 24.04 LTS 桌面版（合法开源软件）")
    print(f"磁力链接: {example_magnet_link}")
    print()
    
    # 提示用户输入磁力链接或使用示例
    user_input = input("请输入磁力链接（直接按回车使用示例）: ").strip()
    
    if not user_input:
        torrent_source = example_magnet_link
        print("使用示例磁力链接")
    else:
        torrent_source = user_input
    
    # 开始下载
    print()
    success = download_torrent(torrent_source)
    
    if success:
        print("\n脚本执行成功！")
    else:
        print("\n脚本执行失败，请检查错误信息")