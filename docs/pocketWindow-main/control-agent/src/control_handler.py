"""
控制指令处理器 - 接收并执行来自手机端的控制命令
"""

import win32gui
import win32con
import time
import pyperclip
from typing import Optional


class ControlHandler:
    """控制指令处理器"""

    def __init__(self):
        self.current_hwnd = None

    def set_target_window(self, hwnd: int):
        """设置目标窗口"""
        self.current_hwnd = hwnd

    def mouse_move(self, x: int, y: int):
        """鼠标移动到指定坐标（相对窗口客户区）"""
        if self.current_hwnd:
            # 合成坐标
            pos = (y << 16) | x
            win32gui.PostMessage(self.current_hwnd, win32con.WM_MOUSEMOVE, 0, pos)

    def mouse_click(self, x: int, y: int, button: str = 'left'):
        """鼠标点击"""
        if self.current_hwnd:
            # 先移动鼠标
            self.mouse_move(x, y)
            time.sleep(0.02)

            # 发送点击消息
            if button == 'left':
                pos = (y << 16) | x
                win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONDOWN, 0, pos)
                win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONUP, 0, pos)
            elif button == 'right':
                pos = (y << 16) | x
                win32gui.PostMessage(self.current_hwnd, win32con.WM_RBUTTONDOWN, 0, pos)
                win32gui.PostMessage(self.current_hwnd, win32con.WM_RBUTTONUP, 0, pos)
            elif button == 'double':
                pos = (y << 16) | x
                for _ in range(2):
                    win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONDOWN, 0, pos)
                    win32gui.PostMessage(self.current_hwnd, win32con.WM_LBUTTONUP, 0, pos)
                    time.sleep(0.05)

    def key_press(self, key_code: int):
        """键盘按键（VK 码）"""
        if self.current_hwnd:
            win32gui.PostMessage(self.current_hwnd, win32con.WM_KEYDOWN, key_code, 0)
            win32gui.PostMessage(self.current_hwnd, win32con.WM_KEYUP, key_code, 0)

    def key_type(self, text: str):
        """输入文本（模拟键盘）"""
        if self.current_hwnd:
            # 简单实现：发送每个字符的按键消息
            for char in text:
                # 这里需要更复杂的实现来支持中文
                # 简单起见，建议使用剪贴板 + 粘贴
                pass

    def paste_text(self, text: str):
        """粘贴文本到目标窗口"""
        try:
            # 保存当前剪贴板内容
            original_clipboard = pyperclip.paste()

            # 设置新内容到剪贴板
            pyperclip.copy(text)

            # 模拟 Ctrl+V
            self.key_press(0x11)  # Ctrl
            time.sleep(0.05)
            self.key_press(0x56)  # V

            # 恢复剪贴板
            time.sleep(0.1)
            pyperclip.copy(original_clipboard)

        except Exception as e:
            print(f"Paste error: {e}")

    def scroll(self, hwnd: int, x: int, y: int, wheels: int):
        """滚轮滚动"""
        if hwnd:
            pos = (y << 16) | x
            wheel_msg = win32con.WM_MOUSEWHEEL
            # wheels > 0 向上滚动, < 0 向下滚动
            delta = wheels * 120
            win32gui.PostMessage(hwnd, wheel_msg, delta, pos)

    def window_action(self, hwnd: int, action: str):
        """窗口操作"""
        actions = {
            'minimize': win32con.SW_MINIMIZE,
            'maximize': win32con.SW_MAXIMIZE,
            'restore': win32con.SW_RESTORE,
            'show': win32con.SW_SHOW,
            'hide': win32con.SW_HIDE
        }

        if action in actions:
            win32gui.ShowWindow(hwnd, actions[action])