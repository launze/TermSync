"""
屏幕捕获 - 支持窗口级捕获和区域捕获
"""

import win32gui
import win32ui
import win32con
import numpy as np
from PIL import Image
import cv2
from typing import Optional, Tuple


class ScreenCapture:
    """屏幕捕获 - 支持窗口级捕获和区域捕获"""

    def __init__(self):
        self.last_frame = None
        self.capture_region = None  # (x, y, width, height)

    def capture_window(self, hwnd: int) -> Optional[np.ndarray]:
        """捕获指定窗口的完整内容"""
        try:
            # 获取窗口大小
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            width = right - left
            height = bottom - top

            # 获取窗口设备上下文
            hwnd_dc = win32gui.GetWindowDC(hwnd)
            mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
            save_dc = mfc_dc.CreateCompatibleDC()

            # 创建位图
            bitmap = win32ui.CreateBitmap()
            bitmap.CreateCompatibleBitmap(mfc_dc, width, height)
            save_dc.SelectObject(bitmap)

            # 复制图像
            save_dc.BitBlt((0, 0), (width, height), mfc_dc, (0, 0), win32con.SRCCOPY)

            # 转换为 PIL Image
            bmpinfo = bitmap.GetInfo()
            bmpstr = bitmap.GetBitmapBits(True)
            pil_image = Image.frombuffer(
                'RGB',
                (bmpinfo['bmWidth'], bmpinfo['bmHeight']),
                bmpstr, 'raw', 'BGRX', 0, 1
            )

            # 清理
            win32gui.DeleteObject(bitmap.GetHandle())
            save_dc.DeleteDC()
            mfc_dc.DeleteDC()
            win32gui.ReleaseDC(hwnd, hwnd_dc)

            return np.array(pil_image)

        except Exception as e:
            print(f"Capture error: {e}")
            return None

    def capture_region(self, hwnd: int, region: Tuple[int, int, int, int]) -> Optional[np.ndarray]:
        """捕获窗口指定区域"""
        full_image = self.capture_window(hwnd)
        if full_image is None:
            return None

        x, y, width, height = region
        return full_image[y:y+height, x:x+width]

    def compress_frame(self, frame: np.ndarray, quality: int = 70) -> Optional[bytes]:
        """压缩图像帧为 JPEG"""
        try:
            _, buffer = cv2.imencode(
                '.jpg',
                frame,
                [cv2.IMWRITE_JPEG_QUALITY, quality]
            )
            return buffer.tobytes()
        except Exception as e:
            print(f"Compress error: {e}")
            return None

    def get_region_diff(self, current: np.ndarray, previous: np.ndarray) -> Tuple[bool, Optional[np.ndarray]]:
        """
        检测图像变化
        返回: (是否有变化, 变化区域的裁剪图像)
        """
        if previous is None:
            return True, current

        # 简单的帧差法
        diff = cv2.absdiff(current, previous)

        # 转为灰度
        gray = cv2.cvtColor(diff, cv2.COLOR_RGB2GRAY)

        # 二值化
        _, thresh = cv2.threshold(gray, 30, 255, cv2.THRESH_BINARY)

        # 寻找变化区域
        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        # 如果有足够大的变化
        has_change = any(cv2.contourArea(c) > 100 for c in contours)

        if has_change:
            # 获取变化区域的边界框
            all_points = np.vstack([c for c in contours if cv2.contourArea(c) > 100])
            x, y, w, h = cv2.boundingRect(all_points)

            # 添加边距
            x = max(0, x - 10)
            y = max(0, y - 10)
            w = min(current.shape[1] - x, w + 20)
            h = min(current.shape[0] - y, h + 20)

            return True, current[y:y+h, x:x+w]

        return False, None
