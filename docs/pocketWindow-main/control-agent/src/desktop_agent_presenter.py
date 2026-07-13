from typing import Optional

from desktop_agent_ui import format_timestamp


def _normalize_name(name: str) -> str:
    return str(name or '').strip()


def _is_placeholder_name(name: str) -> bool:
    normalized = _normalize_name(name)
    if not normalized:
        return True
    if normalized in {'????', '??????', '未命名手机'}:
        return True
    if all(ch in {'?', '�'} for ch in normalized):
        return True
    return False


class DesktopAgentPresenter:
    @staticmethod
    def build_status_snapshot(
        server: str,
        port: int,
        signaling_room_id: Optional[str],
        device_id: str,
        version: str,
        build: int,
        channel: str,
        signaling_connected: bool,
        client_connected: bool,
        target_mode: str,
        target_window_title: Optional[str],
        target_hwnd: Optional[int],
        stream_profile_id: str,
        capture_path: str,
        capture_error: str,
        capture_size: tuple[int, int],
        stream_size: tuple[int, int],
        capture_frames_sent: int,
        capture_frames_skipped: int,
        capture_empty_frames: int,
        cursor_updates_sent: int,
    ) -> str:
        connection = '已连接' if signaling_connected else '未连接'
        mobile = '已连接' if client_connected else '未连接'
        mode = '桌面' if target_mode == 'desktop' else '窗口'
        selected_title = target_window_title or '未选择'
        selected_hwnd = target_hwnd if target_hwnd is not None else '-'
        capture_size_text = f'{capture_size[0]}x{capture_size[1]}'
        stream_size_text = f'{stream_size[0]}x{stream_size[1]}'
        version_text = version or '0.0.0'
        if build > 0:
            version_text = f'{version_text} (build {build})'
        if channel and channel != 'stable':
            version_text = f'{version_text} [{channel}]'
        return '\n'.join(
            [
                f'服务器        {server}:{port}',
                f'服务器连接    {connection}',
                f'手机连接      {mobile}',
                f'房间号        {signaling_room_id or "-"}',
                f'设备 ID       {device_id}',
                f'当前版本      {version_text}',
                f'控制模式      {mode}',
                f'当前窗口      {selected_title}',
                f'窗口句柄      {selected_hwnd}',
                f'画质档位      {stream_profile_id}',
                f'采集路径      {capture_path}',
                f'采集尺寸      {capture_size_text}',
                f'传输尺寸      {stream_size_text}',
                f'已发帧数      {capture_frames_sent}',
                f'跳过帧数      {capture_frames_skipped}',
                f'空帧计数      {capture_empty_frames}',
                f'鼠标更新      {cursor_updates_sent}',
                f'最近错误      {capture_error}',
            ]
        )

    @staticmethod
    def build_trusted_clients_snapshot(
        trusted_clients: list[dict],
        client_connected: bool,
        current_client_hint_id: Optional[str],
    ) -> str:
        if not trusted_clients:
            if client_connected:
                return '当前已有手机在线，但本机还没有保存可识别的绑定记录。'
            return '暂无已绑定手机'

        visible_entries: list[dict] = []
        legacy_entries: list[dict] = []
        for item in trusted_clients:
            name = _normalize_name(item.get('client_name') or '')
            if _is_placeholder_name(name):
                legacy_entries.append(item)
            else:
                copied = dict(item)
                copied['client_name'] = name
                visible_entries.append(copied)

        online_count = 0
        lines: list[str] = []
        for item in visible_entries:
            is_online = bool(current_client_hint_id) and item['client_id'] == current_client_hint_id
            if is_online:
                online_count += 1
            status_text = '在线' if is_online else '离线'
            short_id = item['client_id'][-8:] if len(item['client_id']) > 8 else item['client_id']
            lines.append(
                f'{status_text}  {item["client_name"]}  ({short_id})\n'
                f'    绑定 {format_timestamp(int(item.get("linked_at") or 0))}  最近连接 {format_timestamp(int(item.get("last_connected_at") or 0))}'
            )

        if not visible_entries and legacy_entries:
            lines.append(
                f'共保留 {len(legacy_entries)} 条旧版绑定记录，但名称不可识别。建议用当前新版手机重新绑定一次。'
            )
        elif legacy_entries:
            lines.append(
                f'另有 {len(legacy_entries)} 条旧版绑定记录已折叠显示，它们会继续兼容，但名称暂不可识别。'
            )

        header = f'已绑定手机共 {len(trusted_clients)} 条记录，可识别设备 {len(visible_entries)} 台'
        if client_connected:
            if current_client_hint_id:
                header += f'，当前在线 1 台'
            else:
                header += '，当前已有手机连接，但还未识别到具体是哪一台'
        elif online_count > 0:
            header += f'，识别到在线 {online_count} 台'
        else:
            header += '，当前无手机在线'

        details = '\n\n'.join(lines).strip()
        return header if not details else f'{header}\n\n{details}'
