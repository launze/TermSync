"""
PocketWindow Agent - Windows 被控端主程序
支持窗口选择、区域捕获、语音输入和控制指令
"""

import argparse
import sys
import json
import time
import threading
from typing import Tuple, Optional

from window_selector import WindowSelector
from screen_capture import ScreenCapture
from control_handler import ControlHandler
from webrtc_connection import WebRTCConnection


def load_config(config_path: str = 'config.json') -> dict:
    """加载配置文件"""
    default_config = {
        'signaling_server': 'localhost',
        'port': 58080,
        'jpeg_quality': 70,
        'frame_interval': 0.1,  # 秒
        'auto_connect': False,
        'room_id': None
    }

    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
            default_config.update(config)
    except FileNotFoundError:
        print(f"配置文件 {config_path} 不存在，使用默认配置")
    except json.JSONDecodeError:
        print(f"配置文件 {config_path} 格式错误")

    return default_config


def save_config(config: dict, config_path: str = 'config.json'):
    """保存配置文件"""
    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=2)


def print_windows_list(windows: list, max_count: int = 15):
    """打印窗口列表"""
    print("\n可用窗口:")
    for i, window in enumerate(windows[:max_count]):
        print(f"{i+1:3d}. [{window.title}] {window.class_name}")

    if len(windows) > max_count:
        print(f"     ... 还有 {len(windows) - max_count} 个窗口")


def interactive_mode(selector: WindowSelector, capture: ScreenCapture, connection: WebRTCConnection):
    """交互式模式"""
    while True:
        print("\n" + "=" * 50)
        print("PocketWindow Control Agent - 菜单")
        print("=" * 50)
        print("1. 列出窗口")
        print("2. 选择窗口")
        print("3. 设置监控区域")
        print("4. 查看连接状态")
        print("5. 手动触发刷新")
        print("6. 保存配置")
        print("0. 退出")
        print("-" * 50)

        choice = input("请选择操作: ").strip()

        if choice == '1':
            windows = selector.get_windows()
            print_windows_list(windows)

        elif choice == '2':
            choice_input = input("输入窗口编号或关键词: ").strip()
            selected = None

            try:
                idx = int(choice_input) - 1
                windows = selector.get_windows()
                if 0 <= idx < len(windows):
                    selected = windows[idx]
            except ValueError:
                selected = selector.find_window(choice_input)

            if selected:
                connection.target_hwnd = selected.hwnd
                print(f"已选择: [{selected.title}] (HWND: {selected.hwnd})")
            else:
                print("未找到窗口")

        elif choice == '3':
            region_input = input("输入区域 (x,y,width,height): ").strip()
            try:
                parts = [int(x) for x in region_input.split(',')]
                if len(parts) == 4:
                    connection.capture_region = tuple(parts)
                    print(f"监控区域已设置: {connection.capture_region}")
                else:
                    print("格式错误，应为: x,y,width,height")
            except ValueError:
                print("格式错误")

        elif choice == '4':
            print(f"连接状态: {'已连接' if connection.connected else '未连接'}")
            print(f"目标窗口: {getattr(connection, 'target_hwnd', '未设置')}")
            print(f"监控区域: {getattr(connection, 'capture_region', '全窗口')}")

        elif choice == '5':
            print("触发刷新...")
            if hasattr(connection, 'target_hwnd') and connection.target_hwnd:
                frame = capture.capture_window(connection.target_hwnd)
                if frame is not None:
                    compressed = capture.compress_frame(frame)
                    print(f"图像尺寸: {frame.shape}, 压缩大小: {len(compressed)} bytes")

        elif choice == '6':
            config = {
                'signaling_server': connection.signaling_server,
                'port': connection.port,
                'room_id': getattr(connection, 'room_id', None),
                'target_hwnd': getattr(connection, 'target_hwnd', None),
                'capture_region': getattr(connection, 'capture_region', None)
            }
            save_config(config)
            print("配置已保存")

        elif choice == '0':
            print("退出")
            break

        else:
            print("无效选择")


def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='PocketWindow Control Agent')
    parser.add_argument('--config', '-c', default='config.json', help='配置文件路径')
    parser.add_argument('--server', '-s', help='信令服务器地址')
    parser.add_argument('--port', '-p', type=int, help='信令服务器端口')
    parser.add_argument('--room', '-r', help='房间 ID')
    parser.add_argument('--list', '-l', action='store_true', help='只列出窗口')
    parser.add_argument('--window', '-w', help='目标窗口标题')
    parser.add_argument('--region', '-R', help='监控区域 x,y,w,h')
    parser.add_argument('--batch', '-b', action='store_true', help='批处理模式')

    args = parser.parse_args()

    # 加载配置
    config = load_config(args.config)

    # 命令行参数覆盖
    if args.server:
        config['signaling_server'] = args.server
    if args.port:
        config['port'] = args.port
    if args.room:
        config['room_id'] = args.room

    # 初始化组件
    selector = WindowSelector()
    capture = ScreenCapture()
    connection = WebRTCConnection(config['signaling_server'], config['port'])

    # 如果只列出窗口
    if args.list:
        windows = selector.get_windows()
        print_windows_list(windows)
        return

    # 如果指定了窗口
    if args.window:
        selected = selector.find_window(args.window)
        if selected:
            connection.target_hwnd = selected.hwnd
            print(f"已选择窗口: [{selected.title}]")
        else:
            print(f"未找到窗口: {args.window}")

    # 如果指定了区域
    if args.region:
        try:
            parts = [int(x) for x in args.region.split(',')]
            if len(parts) == 4:
                connection.capture_region = tuple(parts)
        except ValueError:
            pass

    # CLI 模式
    if args.batch:
        if not connection.target_hwnd:
            print("错误: 批处理模式需要指定窗口")
            return
        if not connection.room_id:
            print("错误: 批处理模式需要指定房间 ID")
            return

        connection.connect(connection.room_id)
        time.sleep(2)

        if connection.connected:
            connection.start_image_stream(capture, connection.target_hwnd, connection.capture_region)

            try:
                while connection.connected:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass

        return

    # 详细输出
    print("=" * 50)
    print("PocketWindow Control Agent")
    print("=" * 50)
    print(f"信令服务器: {config['signaling_server']}:{config['port']}")

    # 连接
    connection.connect(config['room_id'])

    print(f"\n请在手机端输入房间 ID: {connection.room_id}")
    print("按 Ctrl+C 退出")

    # 交互式模式（如果在终端运行）
    if sys.stdin.isatty() and not args.window:
        try:
            interactive_mode(selector, capture, connection)
        except KeyboardInterrupt:
            print("\n退出")
    else:
        # 自动模式
        try:
            while connection.connected:
                time.sleep(1)
        except KeyboardInterrupt:
            print("\n退出")


if __name__ == '__main__':
    main()
