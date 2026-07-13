"""
窗口选择器 - 枚举和选择目标窗口
"""

import win32gui
import win32ui
import win32con
import numpy as np
from PIL import Image
import cv2
from typing import Optional, List, Tuple


class WindowInfo:
    """窗口信息"""

    def __init__(self, hwnd: int, title: str, class_name: str, rect: Tuple[int, int, int, int]):
        self.hwnd = hwnd
        self.title = title
        self.class_name = class_name
        self.rect = rect

    def to_dict(self):
        return {
            'hwnd': self.hwnd,
            'title': self.title,
            'class_name': self.class_name,
            'rect': self.rect
        }

    def __repr__(self):
        return f"WindowInfo(hwnd={self.hwnd}, title='{self.title}')"


class WindowSelector:
    """窗口选择器 - 枚举和选择目标窗口"""

    @staticmethod
    def enum_windows_callback(hwnd, windows):
        """枚举窗口回调"""
        if win32gui.IsWindowVisible(hwnd):
            title = win32gui.GetWindowText(hwnd)
            class_name = win32gui.GetClassName(hwnd)
            rect = win32gui.GetWindowRect(hwnd)

            if title:  # 只保留有标题的窗口
                windows.append(WindowInfo(hwnd, title, class_name, rect))

    @classmethod
    def get_windows(cls) -> List[WindowInfo]:
        """获取所有可见窗口"""
        windows = []
        win32gui.EnumWindows(cls.enum_windows_callback, windows)
        return windows

    @classmethod
    def find_window(cls, title_pattern: str) -> Optional[WindowInfo]:
        """根据标题查找窗口（部分匹配）"""
        windows = cls.get_windows()
        for window in windows:
            if title_pattern.lower() in window.title.lower():
                return window
        return None

    @classmethod
    def find_window_exact(cls, title: str) -> Optional[WindowInfo]:
        """根据标题精确查找"""
        windows = cls.get_windows()
        for window in windows:
            if window.title == title:
                return window
        return None

    @classmethod
    def find_window_by_class(cls, class_name: str) -> Optional[WindowInfo]:
        """根据窗口类名查找"""
        windows = cls.get_windows()
        for window in windows:
            if class_name in window.class_name:
                return window
        return None
