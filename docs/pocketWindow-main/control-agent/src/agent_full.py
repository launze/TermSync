"""
PocketWindow - 完整被控端程序（优化版）
整合所有模块：窗口选择、ScreenCapture、WebRTC Agent、Control Handler
支持：配置文件、后台运行、控制指令处理
"""

import argparse
import asyncio
import json
import logging
import sys
import time
import threading
from typing import Optional, Callable

from window_selector import WindowSelector
from screen_capture import ScreenCapture
from control_handler import ControlHandler
from webrtc_agent import WebRTCAgent

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class PocketWindowAgent:
    """PocketWindow 被控端主类"""

    def __init__(self, signaling_host: str = 'localhost', signaling_port: int = 58080):
        self.signaling_host = signaling_host
        self.signaling_port = signaling_port

        # 初始化模块
        self.window_selector = WindowSelector()
        self.capture = ScreenCapture()
        self.control_handler = ControlHandler()

        # WebRTC Agent
        self.agent = WebRTCAgent(signaling_host, signaling_port)
        self.agent.set_capture_callback(self._capture_frame)
        self.agent.on_connected = self._on_connected
        self.agent.on_disconnected = self._on_disconnected

        # 状态
        self.target_hwnd: Optional[int] = None
        self.target_title: Optional[str] = None
        self.capture_region: Optional[tuple] = None  # (x, y, width, height)
        self.running = False
        self.connection_start_time = None

        # 窗口列表缓存
        self._windows_cache = []
        self._last_frame_time = 0
        self._frame_interval = 0.1  # 10 FPS

        # 配置
        self.config = {
            'jpeg_quality': 70,
            'frame_interval': 0.1,
            'auto_select_first_window': False,
            'capture_region': None
        }

    def load_config(self, config_path: str = 'config.json'):
        """加载配置文件"""
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                loaded_config = json.load(f)
                self.config.update(loaded_config)
                logger.info(f"配置已加载: {config_path}")
        except FileNotFoundError:
            logger.warning(f"配置文件不存在: {config_path}，使用默认配置")
        except json.JSONDecodeError:
            logger.warning(f"配置文件格式错误: {config_path}")

    def save_config(self, config_path: str = 'config.json'):
        """保存配置文件"""
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(self.config, f, indent=2)
        logger.info(f"配置已保存: {config_path}")

    def _capture_frame(self) -> Optional[bytes]:
        """捕获帧 - 供 WebRTC Agent 调用"""
        if not self.target_hwnd:
            return None

        # 控制帧率
        current_time = time.time()
        if current_time - self._last_frame_time < self._frame_interval:
            return None
        self._last_frame_time = current_time

        try:
            if self.capture_region:
                frame = self.capture.capture_region(self.target_hwnd, self.capture_region)
            else:
                frame = self.capture.capture_window(self.target_hwnd)

            if frame is not None:
                # 压缩为 JPEG
                quality = self.config.get('jpeg_quality', 70)
                _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
                return buffer.tobytes()
        except Exception as e:
            logger.error(f"Capture error: {e}")

        return None

    def _on_connected(self):
        """连接建立回调"""
        logger.info("========================================")
        logger.info("已连接到手机端")
        logger.info(f"目标窗口: [{self.target_title}] (HWND: {self.target_hwnd})")
        if self.capture_region:
            logger.info(f"监控区域: {self.capture_region}")
        logger.info("========================================")
        self.running = True
        self.connection_start_time = time.time()

    def _on_disconnected(self):
        """连接断开回调"""
        logger.info("手机端已断开连接")
        self.running = False

    async def _capture_loop(self):
        """捕获循环 - 单独线程运行"""
        logger.info("图像捕获循环启动")
        while self.running:
            try:
                frame = self._capture_frame()
                if frame is not None:
                    # 可以在这里添加图像处理逻辑
                    # 例如：区域变更检测、截图保存等
                    pass
                await asyncio.sleep(0.01)
            except Exception as e:
                logger.error(f"Capture loop error: {e}")
                await asyncio.sleep(1)

    async def run(self, window_title: Optional[str] = None, headless: bool = False):
        """运行主循环"""
        logger.info("PocketWindow 被控端启动")
        logger.info(f"信令服务器: {self.signaling_host}:{self.signaling_port}")

        # 加载配置
        self.load_config()

        # 如果有捕获区域配置
        if self.config.get('capture_region'):
            region = self.config['capture_region']
            self.capture_region = (
                region['x'], region['y'], region['width'], region['height']
            )
            logger.info(f"监控区域: {self.capture_region}")

        # 如果没有指定窗口，显示列表
        if not window_title:
            self._windows_cache = self.window_selector.get_windows()
            logger.info(f"发现 {len(self._windows_cache)} 个窗口")

            if not headless:
                print("\n可用窗口:")
                for i, w in enumerate(self._windows_cache[:20]):
                    print(f"{i+1:3d}. [{w.title}]")

                if len(self._windows_cache) > 20:
                    print(f"     ... 还有 {len(self._windows_cache) - 20} 个窗口")

            # 自动选择第一个窗口
            if self.config.get('auto_select_first_window') and self._windows_cache:
                self.target_hwnd = self._windows_cache[0].hwnd
                self.target_title = self._windows_cache[0].title
                logger.info(f"自动选择窗口: [{self.target_title}]")

            elif not headless:
                # 获取用户选择
                try:
                    choice = input("\n选择窗口编号 (或输入回车跳过): ").strip()
                    if choice:
                        idx = int(choice) - 1
                        if 0 <= idx < len(self._windows_cache):
                            self.target_hwnd = self._windows_cache[idx].hwnd
                            self.target_title = self._windows_cache[idx].title
                            print(f"已选择: [{self.target_title}]")
                except (ValueError, KeyboardInterrupt):
                    pass
        else:
            # 按标题查找窗口
            window = self.window_selector.find_window(window_title)
            if window:
                self.target_hwnd = window.hwnd
                self.target_title = window.title
                print(f"已找到窗口: [{window.title}]")
            else:
                logger.error(f"未找到窗口: {window_title}")
                return

        # 如果还没有选择窗口，提示输入
        while not self.target_hwnd and not headless:
            try:
                choice = input("\n输入窗口编号或标题选择目标窗口: ").strip()
                if choice:
                    # 尝试作为索引
                    try:
                        idx = int(choice) - 1
                        if 0 <= idx < len(self._windows_cache):
                            self.target_hwnd = self._windows_cache[idx].hwnd
                            self.target_title = self._windows_cache[idx].title
                            print(f"已选择: [{self._windows_cache[idx].title}]")
                    except ValueError:
                        # 按关键词查找
                        window = self.window_selector.find_window(choice)
                        if window:
                            self.target_hwnd = window.hwnd
                            self.target_title = window.title
                            print(f"已选择: [{window.title}]")
                        else:
                            print("未找到窗口")
            except (ValueError, KeyboardInterrupt):
                break

        # 配置 WebRTC Agent
        if self.target_hwnd:
            self.control_handler.set_target_window(self.target_hwnd)
        if self.capture_region:
            self.agent.capture_region = self.capture_region

        # 连接信令服务器
        logger.info("正在连接信令服务器...")
        try:
            await self.agent.connect()
        except Exception as e:
            logger.error(f"连接失败: {e}")
            return

        # 启动捕获循环
        capture_task = asyncio.create_task(self._capture_loop())

        try:
            # 等待连接完成
            while self.agent.running:
                await asyncio.sleep(1)

                # 定期检查窗口有效性
                if self.target_hwnd and not self._is_window_valid(self.target_hwnd):
                    logger.warning("目标窗口已关闭或无效")
                    self.target_hwnd = None
                    self.target_title = None
        except KeyboardInterrupt:
            logger.info("用户中断")
        finally:
            capture_task.cancel()
            await self.agent.disconnect()
            logger.info("退出")

    def _is_window_valid(self, hwnd: int) -> bool:
        """检查窗口是否仍然有效"""
        try:
            return win32gui.IsWindow(hwnd)
        except:
            return False

    # Window Selector 引用（用于验证窗口）
    @property
    def window_selector(self):
        return self._window_selector

    @window_selector.setter
    def window_selector(self, value):
        self._window_selector = value


async def main():
    """主函数"""
    parser = argparse.ArgumentParser(
        description='PocketWindow - Windows 窗口远程控制被控端',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python agent_full.py                          # 交互式运行
  python agent_full.py -w "VSCode"              # 指定窗口
  python agent_full.py -s your-nas-ip -p 58080   # 指定信令服务器
  python agent_full.py --headless               # 后台运行
        """
    )
    parser.add_argument('--server', '-s', default='localhost',
                        help='信令服务器地址 (默认: localhost)')
    parser.add_argument('--port', '-p', type=int, default=58080,
                        help='信令服务器端口 (默认: 58080)')
    parser.add_argument('--window', '-w', default=None,
                        help='目标窗口标题关键词')
    parser.add_argument('--region', '-R', default=None,
                        help='监控区域 x,y,width,height (例如: 0,0,800,600)')
    parser.add_argument('--config', '-c', default='config.json',
                        help='配置文件路径')
    parser.add_argument('--headless', action='store_true',
                        help='后台运行模式（不显示UI）')
    parser.add_argument('--save-config', action='store_true',
                        help='保存当前配置到配置文件')

    args = parser.parse_args()

    # 加载配置
    config = {}
    try:
        with open(args.config, 'r', encoding='utf-8') as f:
            config = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    # 命令行参数覆盖
    if args.server != 'localhost':
        config['signaling_host'] = args.server
    if args.port != 58080:
        config['signaling_port'] = args.port
    if args.window:
        config['window_title'] = args.window
    if args.region:
        try:
            parts = [int(x) for x in args.region.split(',')]
            if len(parts) == 4:
                config['capture_region'] = {
                    'x': parts[0], 'y': parts[1],
                    'width': parts[2], 'height': parts[3]
                }
        except ValueError:
            logger.warning(f"无效的区域参数: {args.region}")

    # 创建并运行 Agent
    agent = PocketWindowAgent(
        signaling_host=config.get('signaling_host', 'localhost'),
        signaling_port=config.get('signaling_port', 58080)
    )

    # 设置 capture_region
    if config.get('capture_region'):
        region = config['capture_region']
        agent.capture_region = (
            region['x'], region['y'], region['width'], region['height']
        )

    try:
        await agent.run(
            window_title=config.get('window_title'),
            headless=args.headless
        )
    except KeyboardInterrupt:
        logger.info("用户中断")
    except Exception as e:
        logger.error(f"运行错误: {e}")
        import traceback
        traceback.print_exc()
    finally:
        if args.save_config:
            agent.save_config()


if __name__ == '__main__':
    # 检查依赖
    try:
        import cv2
        import numpy as np
        from PIL import Image
        import win32gui
    except ImportError as e:
        print(f"缺少依赖: {e}")
        print("请运行: pip install -r requirements.txt")
        sys.exit(1)

    asyncio.run(main())
