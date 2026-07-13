from collections import deque
from datetime import datetime
import logging
import os
import random
import threading
from typing import Callable, Optional
import tkinter as tk
import tkinter.font as tkfont
from tkinter import messagebox, ttk

import qrcode
from PIL import ImageTk

from desktop_ui_theme import (
    NOTEBOOK_STYLE,
    THEME_COMBO_STYLE,
    configure_ttk_styles,
    resolve_theme,
)


logger = logging.getLogger(__name__)


def format_timestamp(ts: int) -> str:
    if not ts:
        return '-'
    try:
        return datetime.fromtimestamp(ts).strftime('%m-%d %H:%M')
    except Exception:
        return '-'


THEMES = {
    'classic': {
        'window_bg': '#EEF2F7',
        'panel_bg': '#FFFFFF',
        'panel_alt_bg': '#F5F7FA',
        'panel_border': '#D7DDE6',
        'text': '#1F2937',
        'muted_text': '#4B5563',
        'accent': '#2457F5',
        'accent_text': '#15328A',
        'title_font': ('Microsoft YaHei UI', 18, 'bold'),
        'heading_font': ('Microsoft YaHei UI', 11, 'bold'),
        'body_font': ('Microsoft YaHei UI', 10),
        'mono_font': ('Consolas', 11),
        'code_font': ('Consolas', 30, 'bold'),
        'theme_label': '原版',
        'hero_subtitle': '首次绑定时，用手机扫描二维码或输入配对码。',
        'pair_card_bg': '#FFFFFF',
        'pair_card_fg': '#111827',
        'badge_bg': '#E8EEFF',
        'badge_fg': '#15328A',
        'combo_bg': '#FFFFFF',
        'combo_fg': '#1F2937',
    },
    'mabinogi': {
        'window_bg': '#2A241C',
        'panel_bg': '#3A3025',
        'panel_alt_bg': '#473A2D',
        'panel_border': '#8B6B3F',
        'text': '#F5E8C8',
        'muted_text': '#D3C2A0',
        'accent': '#C59A52',
        'accent_text': '#FBE8B4',
        'title_font': ('Georgia', 20, 'bold'),
        'heading_font': ('Georgia', 11, 'bold'),
        'body_font': ('Microsoft YaHei UI', 10),
        'mono_font': ('Consolas', 11),
        'code_font': ('Georgia', 30, 'bold'),
        'theme_label': '洛奇风格',
        'hero_subtitle': '像玛奇的浮窗一样管理绑定与控制状态。',
        'pair_card_bg': '#4A3A28',
        'pair_card_fg': '#FFE7AE',
        'badge_bg': '#6E5431',
        'badge_fg': '#FFE7AE',
        'combo_bg': '#473A2D',
        'combo_fg': '#F5E8C8',
    },
}


class DesktopAgentUI:
    def __init__(
        self,
        agent,
        device_id_getter: Callable[[], str],
        room_id_getter: Callable[[], str],
        status_snapshot_getter: Callable[[], str],
        trusted_snapshot_getter: Callable[[], str],
        pair_request_approver: Callable[[str, bool], None],
        trusted_client_rememberer: Callable[[str, str], None],
        status_update_callback: Callable[[str], None],
        theme_getter: Callable[[], str],
        theme_setter: Callable[[str], None],
        startup_getter: Callable[[], bool],
        startup_setter: Callable[[bool], bool],
        app_icon_path: str = '',
        signaling_endpoints_getter: Optional[Callable[[], list[dict]]] = None,
        signaling_endpoints_setter: Optional[Callable[[list[dict]], list[dict]]] = None,
        signaling_route_getter: Optional[Callable[[], tuple[str, str, int]]] = None,
        update_check_callback: Optional[Callable[[], None]] = None,
    ):
        self._device_id_getter = device_id_getter
        self._room_id_getter = room_id_getter
        self._status_snapshot_getter = status_snapshot_getter
        self._trusted_snapshot_getter = trusted_snapshot_getter
        self._pair_request_approver = pair_request_approver
        self._trusted_client_rememberer = trusted_client_rememberer
        self._status_update_callback = status_update_callback
        self._theme_getter = theme_getter
        self._theme_setter = theme_setter
        self._startup_getter = startup_getter
        self._startup_setter = startup_setter
        self._app_icon_path = app_icon_path
        self._signaling_endpoints_getter = signaling_endpoints_getter
        self._signaling_endpoints_setter = signaling_endpoints_setter
        self._signaling_route_getter = signaling_route_getter
        self._update_check_callback = update_check_callback

        self._agent = agent
        self._pair_code = '------'
        self._pair_prompt_queue: list[dict] = []
        self._update_prompt_queue: list[dict] = []
        self._status_text = '正在连接服务器...'
        self._room_id = ''
        self._theme_name = self._theme_getter()

        self._root: Optional[tk.Tk] = None
        self._theme_var: Optional[tk.StringVar] = None
        self._startup_var: Optional[tk.BooleanVar] = None
        self._status_var: Optional[tk.StringVar] = None
        self._pair_code_var: Optional[tk.StringVar] = None
        self._room_var: Optional[tk.StringVar] = None
        self._qr_label: Optional[tk.Label] = None
        self._qr_photo: Optional[ImageTk.PhotoImage] = None
        self._hero_title_label: Optional[tk.Label] = None
        self._hero_subtitle_label: Optional[tk.Label] = None
        self._theme_badge_label: Optional[tk.Label] = None
        self._theme_picker: Optional[ttk.Combobox] = None
        self._ttk_style: Optional[ttk.Style] = None
        self._root_frame: Optional[tk.Frame] = None
        self._header_bar: Optional[tk.Frame] = None
        self._hero_frame: Optional[tk.Frame] = None
        self._hero_top_frame: Optional[tk.Frame] = None
        self._notebook: Optional[ttk.Notebook] = None
        self._pair_tab_frame: Optional[tk.Frame] = None
        self._status_tab_frame: Optional[tk.Frame] = None
        self._settings_tab_frame: Optional[tk.Frame] = None
        self._pair_card_frame: Optional[tk.Frame] = None
        self._room_row_frame: Optional[tk.Frame] = None
        self._panels_frame: Optional[tk.Frame] = None
        self._trusted_panel_frame: Optional[tk.Frame] = None
        self._settings_panel_frame: Optional[tk.Frame] = None
        self._trusted_panel: Optional[tk.Text] = None
        self._trusted_scrollbar: Optional[tk.Scrollbar] = None
        self._status_panel: Optional[tk.Label] = None
        self._startup_check: Optional[tk.Checkbutton] = None
        self._endpoints_panel_frame: Optional[tk.Frame] = None
        self._endpoints_listbox: Optional[tk.Listbox] = None
        self._endpoints_route_var: Optional[tk.StringVar] = None
        self._endpoints_buttons_frame: Optional[tk.Frame] = None
        self._endpoints_route_refresh_after_id: Optional[str] = None
        self._section_labels: list[tk.Label] = []
        self._meta_labels: list[tk.Label] = []
        self._main_thread_id: Optional[int] = None
        self._ui_tasks: deque[Callable[[], None]] = deque()
        self._ui_tasks_lock = threading.Lock()
        self._theme_apply_pending = False
        self._last_trusted_snapshot_text = ''
        self._last_status_snapshot_text = ''

        # Remote terminal tab widgets / state
        self._terminal_tab_frame: Optional[tk.Frame] = None
        self._terminal_listbox: Optional[tk.Listbox] = None
        self._terminal_text: Optional[tk.Text] = None
        self._terminal_shell_var: Optional[tk.StringVar] = None
        self._terminal_session_ids: list[str] = []
        self._terminal_selected_id: Optional[str] = None
        self._terminal_refresh_after_id: Optional[str] = None
        self._terminal_last_list_sig = ''
        self._terminal_last_cells_sig: Optional[str] = None
        self._terminal_font_size = 10
        self._terminal_min_font_size = 11
        self._terminal_text_width_px = 0
        self._terminal_text_height_px = 0
        self._terminal_body_width_px = 0
        self._terminal_view_frame: Optional[tk.Frame] = None
        self._terminal_font_metric_cache: dict[int, tuple[int, int]] = {}

    def enqueue_pair_prompt(self, payload: dict):
        self._pair_prompt_queue.append(payload)

    def enqueue_update_prompt(self, payload: dict):
        self._update_prompt_queue.append(payload)

    def create(self):
        root = tk.Tk()
        self._main_thread_id = threading.get_ident()
        root.title('PocketWindow 电脑端')
        if self._app_icon_path and os.path.exists(self._app_icon_path):
            try:
                root.iconbitmap(self._app_icon_path)
            except Exception:
                logger.debug('failed to set window icon', exc_info=True)
        root.geometry('1000x820')
        root.minsize(720, 780)

        theme_var = tk.StringVar(value=self._theme_name)
        startup_var = tk.BooleanVar(value=bool(self._startup_getter()))
        status_var = tk.StringVar(value=self._status_text)
        pair_code_var = tk.StringVar(value=self._pair_code)
        room_var = tk.StringVar(value=self._room_id or self._room_id_getter() or '')

        root_frame = tk.Frame(root, padx=18, pady=18)
        root_frame.pack(fill='both', expand=True)

        header_bar = tk.Frame(root_frame)
        header_bar.pack(fill='x')

        hero_frame = tk.Frame(root_frame, padx=18, pady=18, bd=0, highlightthickness=1)
        hero_frame.pack(fill='x', pady=(12, 14))

        hero_top = tk.Frame(hero_frame)
        hero_top.pack(fill='x')

        hero_title = tk.Label(hero_top, text='PocketWindow 电脑端')
        hero_title.pack(side='left')

        theme_badge = tk.Label(hero_top, text='')
        theme_badge.pack(side='right')

        hero_subtitle = tk.Label(hero_frame, text='', justify='left', wraplength=420)
        hero_subtitle.pack(anchor='w', pady=(8, 0))

        notebook = ttk.Notebook(root_frame, style=NOTEBOOK_STYLE)
        notebook.pack(fill='both', expand=True)

        pair_tab = tk.Frame(notebook, padx=2, pady=2)
        status_tab = tk.Frame(notebook, padx=2, pady=2)
        settings_tab = tk.Frame(notebook, padx=2, pady=2)
        notebook.add(pair_tab, text='配对')
        notebook.add(status_tab, text='状态')

        notebook.add(settings_tab, text='配置')

        # Public-direct tab (NAS frpc port-forward + TOTP). The bulk of
        # the widgets are created lazily in _build_public_direct_tab()
        # to keep create() readable.
        self._public_direct_tab = tk.Frame(notebook, padx=2, pady=2)
        notebook.add(self._public_direct_tab, text='公网直连')
        self._build_public_direct_tab(self._public_direct_tab)

        # Remote terminal tab. Sessions are owned by the agent's
        # TerminalManager (fetched lazily through the agent reference); this
        # tab makes those terminals visible and controllable on the desktop.
        self._terminal_tab_frame = tk.Frame(notebook, padx=2, pady=2)
        notebook.add(self._terminal_tab_frame, text='远程终端')
        self._build_terminal_tab(self._terminal_tab_frame)

        pair_card = tk.Frame(pair_tab, padx=16, pady=14, bd=0, highlightthickness=1)
        pair_card.pack(fill='both', expand=True)

        tk.Label(pair_card, text='配对码').pack(anchor='w')
        tk.Label(pair_card, textvariable=pair_code_var).pack(anchor='w', pady=(4, 10))

        qr_label = tk.Label(pair_card)
        qr_label.pack(anchor='center', pady=(2, 12))

        room_row = tk.Frame(pair_card)
        room_row.pack(fill='x')
        tk.Label(room_row, text='房间号').pack(side='left')
        tk.Label(room_row, textvariable=room_var).pack(side='left', padx=(10, 0))

        panels = tk.Frame(status_tab)
        panels.pack(fill='both', expand=True, pady=(14, 0))

        trusted_heading = tk.Label(panels, text='已绑定手机')
        trusted_heading.pack(anchor='w')
        trusted_panel_frame = tk.Frame(panels, bd=0, highlightthickness=1)
        trusted_panel_frame.pack(fill='x', pady=(6, 14))
        trusted_scrollbar = tk.Scrollbar(trusted_panel_frame, orient='vertical')
        trusted_scrollbar.pack(side='right', fill='y')
        trusted_panel = tk.Text(
            trusted_panel_frame,
            height=9,
            wrap='word',
            bd=0,
            padx=12,
            pady=12,
            yscrollcommand=trusted_scrollbar.set,
        )
        trusted_panel.pack(side='left', fill='both', expand=True)
        trusted_panel.configure(state='disabled')
        trusted_scrollbar.configure(command=trusted_panel.yview)

        status_heading = tk.Label(panels, text='当前控制')
        status_heading.pack(anchor='w')
        status_panel = tk.Label(
            panels,
            textvariable=status_var,
            justify='left',
            anchor='nw',
            padx=12,
            pady=12,
            wraplength=430,
            bd=0,
            highlightthickness=1,
        )
        status_panel.pack(fill='both', expand=True, pady=(6, 0))

        settings_panel = tk.Frame(settings_tab, padx=16, pady=14, bd=0, highlightthickness=1)
        settings_panel.pack(fill='x', pady=(14, 0))
        startup_check = tk.Checkbutton(
            settings_panel,
            text='开机随系统启动',
            variable=startup_var,
            command=self._on_startup_changed,
            anchor='w',
            padx=8,
            pady=8,
        )
        startup_check.pack(fill='x')
        if self._update_check_callback is not None:
            tk.Button(
                settings_panel,
                text='检查电脑端更新',
                command=self._update_check_callback,
                anchor='w',
                padx=8,
                pady=8,
            ).pack(fill='x', pady=(8, 0))

        # Signaling server panel: list, add/edit/remove, share QR.
        endpoints_panel = tk.Frame(settings_tab, padx=16, pady=14, bd=0, highlightthickness=1)
        endpoints_panel.pack(fill='both', expand=True, pady=(14, 0))

        endpoints_heading = tk.Label(endpoints_panel, text='信令服务器', anchor='w')
        endpoints_heading.pack(fill='x')

        endpoints_route_var = tk.StringVar(value='当前：未连接')
        endpoints_route_label = tk.Label(
            endpoints_panel,
            textvariable=endpoints_route_var,
            anchor='w',
            justify='left',
        )
        endpoints_route_label.pack(fill='x', pady=(4, 8))

        endpoints_listbox = tk.Listbox(
            endpoints_panel,
            height=4,
            activestyle='dotbox',
            selectmode='browse',
        )
        endpoints_listbox.pack(fill='x')

        endpoints_buttons = tk.Frame(endpoints_panel)
        endpoints_buttons.pack(fill='x', pady=(8, 0))
        tk.Button(endpoints_buttons, text='新增', command=self._on_endpoint_add).pack(side='left')
        tk.Button(endpoints_buttons, text='编辑', command=self._on_endpoint_edit).pack(side='left', padx=(6, 0))
        tk.Button(endpoints_buttons, text='删除', command=self._on_endpoint_delete).pack(side='left', padx=(6, 0))
        tk.Button(endpoints_buttons, text='上移', command=lambda: self._on_endpoint_move(-1)).pack(side='left', padx=(6, 0))
        tk.Button(endpoints_buttons, text='下移', command=lambda: self._on_endpoint_move(1)).pack(side='left', padx=(6, 0))
        tk.Button(endpoints_buttons, text='启用/停用', command=self._on_endpoint_toggle_enabled).pack(side='left', padx=(6, 0))

        theme_picker = ttk.Combobox(
            header_bar,
            textvariable=theme_var,
            state='readonly',
            width=12,
            style=THEME_COMBO_STYLE,
            values=['classic', 'mabinogi'],
        )
        theme_picker.pack(side='right')
        theme_picker.bind('<<ComboboxSelected>>', self._on_theme_changed)

        theme_hint = tk.Label(header_bar, text='外观')
        theme_hint.pack(side='right', padx=(0, 8))

        self._root = root
        self._theme_var = theme_var
        self._startup_var = startup_var
        self._status_var = status_var
        self._pair_code_var = pair_code_var
        self._room_var = room_var
        self._qr_label = qr_label
        self._hero_title_label = hero_title
        self._hero_subtitle_label = hero_subtitle
        self._theme_badge_label = theme_badge
        self._theme_picker = theme_picker
        self._ttk_style = ttk.Style(root)
        self._root_frame = root_frame
        self._header_bar = header_bar
        self._hero_frame = hero_frame
        self._hero_top_frame = hero_top
        self._notebook = notebook
        self._pair_tab_frame = pair_tab
        self._status_tab_frame = status_tab
        self._settings_tab_frame = settings_tab
        self._pair_card_frame = pair_card
        self._room_row_frame = room_row
        self._panels_frame = panels
        self._trusted_panel_frame = trusted_panel_frame
        self._settings_panel_frame = settings_panel
        self._trusted_panel = trusted_panel
        self._trusted_scrollbar = trusted_scrollbar
        self._status_panel = status_panel
        self._startup_check = startup_check
        self._endpoints_panel_frame = endpoints_panel
        self._endpoints_listbox = endpoints_listbox
        self._endpoints_route_var = endpoints_route_var
        self._endpoints_buttons_frame = endpoints_buttons
        self._section_labels = [trusted_heading, status_heading]
        self._meta_labels = [theme_hint]

        # Pairing info can arrive while the UI is still being built.
        # Re-sync visible text variables from the latest cached state once all
        # widgets and StringVars are fully attached.
        self._pair_code_var.set(self._pair_code)
        self._room_var.set(self._room_id or self._room_id_getter() or '')
        self._status_var.set(self._status_text)

        self._apply_theme()
        self.refresh_qr_image()
        self.refresh_snapshot()
        self._refresh_endpoints_list()
        self._refresh_route_label()
        self._tick()
        self._terminal_tick()

        root.mainloop()

    # --- Public direct tab ------------------------------------------
    # Lazily created so the existing __init__ signature stays
    # backward compatible with callers that don't pass public-direct
    # callbacks. The agent surface is fetched through the snapshot
    # getter that already exists on DesktopAgentUI; we re-use the
    # status_update_callback to surface errors.

    def _get_agent_public_direct(self):
        agent = getattr(self, '_agent', None)
        if agent is None:
            return {
                'enabled': False,
                'listen_host': '0.0.0.0',
                'listen_port': 0,
                'public_host': '',
                'public_port': 0,
                'totp_secret': '',
                'download_whitelist': [],
                'known_public_ips': [],
            }
        getter = getattr(agent, 'get_public_direct_settings', None)
        if callable(getter):
            return dict(getter())
        return {
            'enabled': False,
            'listen_host': '0.0.0.0',
            'listen_port': 0,
            'public_host': '',
            'public_port': 0,
            'totp_secret': '',
            'download_whitelist': [],
            'known_public_ips': [],
        }

    def _build_terminal_tab(self, parent):
        outer = tk.Frame(parent, padx=8, pady=8)
        outer.pack(fill='both', expand=True)

        body = tk.Frame(outer)
        body.pack(fill='both', expand=True)
        body.grid_rowconfigure(0, weight=1)
        body.grid_columnconfigure(0, weight=0, minsize=180)
        body.grid_columnconfigure(1, weight=1, minsize=560)
        body.bind('<Configure>', self._on_terminal_body_configure)

        left = tk.Frame(body)
        left.grid(row=0, column=0, sticky='nsew', padx=(0, 8))

        self._terminal_shell_var = tk.StringVar(value='powershell')
        tk.Label(left, text='终端类型').pack(anchor='w')
        ttk.Combobox(
            left,
            textvariable=self._terminal_shell_var,
            values=['powershell', 'pwsh', 'cmd'],
            state='readonly',
            width=12,
            style=THEME_COMBO_STYLE,
        ).pack(fill='x', pady=(4, 6))
        tk.Button(left, text='新建终端', command=self._on_terminal_create).pack(fill='x', pady=(0, 6))
        tk.Button(left, text='关闭选中', command=self._on_terminal_close).pack(fill='x', pady=(0, 10))

        tk.Label(left, text='会话列表').pack(anchor='w')
        self._terminal_listbox = tk.Listbox(left, width=18, height=12, exportselection=False)
        self._terminal_listbox.pack(fill='both', expand=True, pady=(4, 0))
        self._terminal_listbox.bind('<<ListboxSelect>>', self._on_terminal_select)

        right = tk.Frame(body)
        right.grid(row=0, column=1, sticky='nsew')
        right.grid_rowconfigure(0, weight=1)
        right.grid_columnconfigure(0, weight=1)
        self._terminal_view_frame = right
        yscroll = tk.Scrollbar(right, orient='vertical')
        xscroll = tk.Scrollbar(right, orient='horizontal')
        self._terminal_text = tk.Text(
            right,
            wrap='none',
            font=('Consolas', 10),
            bg='#1E1E1E',
            fg='#E6E6E6',
            insertbackground='#E6E6E6',
            state='disabled',
            bd=0,
            highlightthickness=0,
            padx=0,
            pady=0,
            height=24,
            yscrollcommand=yscroll.set,
            xscrollcommand=xscroll.set,
        )
        self._terminal_text.grid(row=0, column=0, sticky='nsew')
        yscroll.grid(row=0, column=1, sticky='ns')
        xscroll.grid(row=1, column=0, sticky='ew')
        yscroll.configure(command=self._terminal_text.yview)
        xscroll.configure(command=self._terminal_text.xview)
        # The phone owns the PTY size (cols/rows). The desktop never resizes the
        # PTY; instead it scales the mirror to fit the available tab area.
        self._terminal_text.bind('<Configure>', self._on_terminal_text_configure)

    def _on_terminal_body_configure(self, event):
        self._terminal_body_width_px = max(0, event.width)
        self._terminal_last_cells_sig = None

    def _on_terminal_text_configure(self, event):
        # Record available pixels; fitting happens once the selected session's
        # rows/columns are known.
        self._terminal_text_width_px = max(0, event.width)
        self._terminal_text_height_px = max(0, event.height)
        self._terminal_last_cells_sig = None

    def _fit_terminal_font(self, cols, rows):
        """Scale the desktop mirror so the full terminal grid stays visible."""
        if self._terminal_text is None or cols <= 0 or rows <= 0:
            return
        height_px = self._terminal_text_height_px
        if height_px <= 0:
            try:
                height_px = self._terminal_text.winfo_height()
            except Exception:
                return
        width_px = self._terminal_text_width_px
        if width_px <= 0:
            try:
                width_px = self._terminal_text.winfo_width()
            except Exception:
                return
        if width_px <= 1 or height_px <= 1:
            return
        body_width = self._terminal_body_width_px
        if body_width <= 0 and self._terminal_view_frame is not None:
            try:
                body_width = self._terminal_view_frame.master.winfo_width()
            except Exception:
                body_width = width_px
        max_terminal_width = max(220, body_width - 190)
        usable_height = max(1, height_px - 4)
        usable_width = max(1, max_terminal_width - 4)
        min_font = self._terminal_min_font_size
        size = min_font
        char_px = 1
        for candidate in range(40, min_font - 1, -1):
            line_px, measured_char_px = self._terminal_font_metrics(candidate)
            if line_px * rows <= usable_height and measured_char_px * cols <= usable_width:
                size = candidate
                char_px = measured_char_px
                break
        else:
            _, char_px = self._terminal_font_metrics(size)
        desired_width = min(max_terminal_width, max(220, int(char_px * cols + 4)))
        if self._terminal_view_frame is not None:
            try:
                self._terminal_view_frame.master.grid_columnconfigure(1, minsize=desired_width)
            except Exception:
                pass
        if size != self._terminal_font_size:
            self._terminal_font_size = size
            self._terminal_last_cells_sig = None  # force re-render with new font

    def _terminal_font_metrics(self, size):
        cached = self._terminal_font_metric_cache.get(size)
        if cached is not None:
            return cached
        font = tkfont.Font(family='Consolas', size=size)
        metrics = (max(1, font.metrics('linespace')), max(1, font.measure('W')))
        self._terminal_font_metric_cache[size] = metrics
        return metrics

    def _terminal_manager(self):
        agent = self._agent
        if agent is None:
            return None
        return getattr(agent, '_terminal_manager', None)

    def _on_terminal_create(self):
        manager = self._terminal_manager()
        if manager is None:
            return
        shell = self._terminal_shell_var.get() if self._terminal_shell_var else 'powershell'
        session_id, error = manager.create(shell, 100, 30)
        if session_id is None:
            messagebox.showwarning('新建终端失败', str(error or '未知错误'), parent=self._root)
            return
        self._terminal_selected_id = session_id
        self._terminal_last_list_sig = ''

    def _on_terminal_close(self):
        manager = self._terminal_manager()
        if manager is None or not self._terminal_selected_id:
            return
        manager.close(self._terminal_selected_id)
        self._terminal_selected_id = None
        self._terminal_last_list_sig = ''

    def _on_terminal_select(self, _event=None):
        if self._terminal_listbox is None:
            return
        selection = self._terminal_listbox.curselection()
        if not selection:
            return
        idx = selection[0]
        if 0 <= idx < len(self._terminal_session_ids):
            self._terminal_selected_id = self._terminal_session_ids[idx]
            self._terminal_last_list_sig = ''

    def _refresh_terminal_tab(self):
        if self._terminal_listbox is None or self._terminal_text is None:
            return
        manager = self._terminal_manager()
        sessions = manager.list_sessions() if manager is not None else []

        valid_ids = {s['id'] for s in sessions}
        if self._terminal_selected_id not in valid_ids:
            self._terminal_selected_id = sessions[0]['id'] if sessions else None

        sig = '|'.join(
            '{}:{}:{}:{}x{}'.format(s['id'], s['title'], 'A' if s['attached'] else '-', s['cols'], s['rows'])
            for s in sessions
        ) + '#' + (self._terminal_selected_id or '')
        if sig != self._terminal_last_list_sig:
            self._terminal_last_list_sig = sig
            self._terminal_session_ids = [s['id'] for s in sessions]
            self._terminal_listbox.delete(0, 'end')
            for s in sessions:
                marker = '* ' if s['attached'] else '  '
                self._terminal_listbox.insert(
                    'end', '{}{}  {}x{}'.format(marker, s['title'], s['cols'], s['rows'])
                )
            if self._terminal_selected_id in self._terminal_session_ids:
                sel_idx = self._terminal_session_ids.index(self._terminal_selected_id)
                self._terminal_listbox.selection_clear(0, 'end')
                self._terminal_listbox.selection_set(sel_idx)

        cells = manager.get_screen_cells(self._terminal_selected_id) if (manager and self._terminal_selected_id) else None
        if cells and cells[0] is not None:
            cols = sum(len(run[0]) for run in cells[0])
            self._fit_terminal_font(cols, len(cells))
        self._render_terminal_cells(cells)

    # ANSI color name -> hex (16-color palette, matching a dark terminal theme)
    _TERM_FG = {
        'default': '#E6E6E6', 'black': '#000000', 'red': '#CD3131',
        'green': '#0DBC79', 'brown': '#E5E510', 'yellow': '#E5E510',
        'blue': '#2472C8', 'magenta': '#BC3FBC', 'cyan': '#11A8CD',
        'white': '#E5E5E5', 'brightblack': '#666666', 'brightred': '#F14C4C',
        'brightgreen': '#23D18B', 'brightyellow': '#F5F543', 'brightblue': '#3B8EEA',
        'brightmagenta': '#D670D6', 'brightcyan': '#29B8DB', 'brightwhite': '#FFFFFF',
        'brightbrown': '#F5F543',
    }
    _TERM_BG = {
        'default': '#1E1E1E', 'black': '#000000', 'red': '#CD3131',
        'green': '#0DBC79', 'brown': '#E5E510', 'yellow': '#E5E510',
        'blue': '#2472C8', 'magenta': '#BC3FBC', 'cyan': '#11A8CD',
        'white': '#E5E5E5',
    }

    def _term_color(self, name, table, fallback):
        if not name:
            return fallback
        key = str(name).lower()
        if key in table:
            return table[key]
        # pyte may give a 6-hex string for 256/truecolor
        if len(key) == 6:
            try:
                int(key, 16)
                return '#' + key
            except ValueError:
                pass
        return fallback

    def _render_terminal_cells(self, cells):
        text_widget = self._terminal_text
        if text_widget is None:
            return
        sig = repr(cells)
        if sig == getattr(self, '_terminal_last_cells_sig', None):
            return
        self._terminal_last_cells_sig = sig
        text_widget.configure(state='normal')
        text_widget.delete('1.0', 'end')
        if not cells:
            text_widget.configure(state='disabled')
            return
        used_tags = set()
        for y, runs in enumerate(cells):
            if y > 0:
                text_widget.insert('end', '\n')
            for run in runs:
                run_text = run[0]
                fg_name, bg_name, bold, reverse = run[1], run[2], run[3], run[4]
                fg = self._term_color(fg_name, self._TERM_FG, '#E6E6E6')
                bg = self._term_color(bg_name, self._TERM_BG, '#1E1E1E')
                if reverse:
                    fg, bg = bg, fg
                tag = 'c_{}_{}_{}'.format(fg[1:], bg[1:], 'b' if bold else 'n')
                if tag not in used_tags:
                    fsize = self._terminal_font_size
                    font = ('Consolas', fsize, 'bold') if bold else ('Consolas', fsize)
                    text_widget.tag_configure(tag, foreground=fg, background=bg, font=font)
                    used_tags.add(tag)
                text_widget.insert('end', run_text, tag)
        text_widget.configure(state='disabled')

    def _build_public_direct_tab(self, parent):
        outer = tk.Frame(parent, padx=16, pady=14)
        outer.pack(fill='both', expand=True)

        title = tk.Label(outer, text='公网直连（配合 NAS 端口转发）', anchor='w')
        title.pack(fill='x')
        sub = tk.Label(
            outer,
            text='开启后，桌面端会在指定端口监听，外部手机通过 NAS 上的 frpc 转发直接连入，绕开信令服务器中转。',
            anchor='w',
            wraplength=480,
            justify='left',
            fg='gray',
        )
        sub.pack(fill='x', pady=(4, 12))

        current = self._get_agent_public_direct()

        # Enable row
        self._public_direct_enabled_var = tk.BooleanVar(value=bool(current.get('enabled')))
        enable_check = tk.Checkbutton(
            outer,
            text='启用公网直连',
            variable=self._public_direct_enabled_var,
            anchor='w',
        )
        enable_check.pack(fill='x', pady=(0, 8))

        # Listen port row
        port_row = tk.Frame(outer)
        port_row.pack(fill='x', pady=4)
        tk.Label(port_row, text='监听端口（5 位冷门）：', width=22, anchor='w').pack(side='left')
        self._public_direct_port_var = tk.StringVar(
            value=str(int(current.get('listen_port') or 0))
        )
        tk.Entry(port_row, textvariable=self._public_direct_port_var, width=10).pack(side='left')
        tk.Button(
            port_row,
            text='随机生成',
            command=self._on_public_direct_random_port,
        ).pack(side='left', padx=(8, 0))

        # Public host row
        host_row = tk.Frame(outer)
        host_row.pack(fill='x', pady=4)
        tk.Label(host_row, text='公网地址（域名或 IP）：', width=22, anchor='w').pack(side='left')
        self._public_direct_host_var = tk.StringVar(value=str(current.get('public_host') or ''))
        tk.Entry(host_row, textvariable=self._public_direct_host_var, width=32).pack(side='left', fill='x', expand=True)

        # Public port row
        pport_row = tk.Frame(outer)
        pport_row.pack(fill='x', pady=4)
        tk.Label(pport_row, text='公网端口：', width=22, anchor='w').pack(side='left')
        self._public_direct_public_port_var = tk.StringVar(
            value=str(int(current.get('public_port') or 0))
        )
        tk.Entry(pport_row, textvariable=self._public_direct_public_port_var, width=10).pack(side='left')

        # Whitelist row
        wl_label = tk.Label(outer, text='下载白名单目录（每行一个）：', anchor='w')
        wl_label.pack(fill='x', pady=(12, 2))
        wl_frame = tk.Frame(outer)
        wl_frame.pack(fill='both', expand=False)
        self._public_direct_whitelist_text = tk.Text(
            wl_frame, height=4, width=60, wrap='word'
        )
        self._public_direct_whitelist_text.pack(side='left', fill='both', expand=True)
        for item in current.get('download_whitelist') or []:
            self._public_direct_whitelist_text.insert('end', str(item) + '\n')

        # TOTP secret row
        totp_row = tk.Frame(outer)
        totp_row.pack(fill='x', pady=(12, 4))
        tk.Label(totp_row, text='TOTP 密钥：', anchor='w').pack(side='left')
        existing_secret = str(current.get('totp_secret') or '').strip()
        if not existing_secret:
            agent = getattr(self, '_agent', None)
            store = getattr(agent, '_state_store', None) if agent is not None else None
            if store is not None and hasattr(store, 'load_or_create_totp_secret'):
                try:
                    existing_secret = str(store.load_or_create_totp_secret() or '').strip()
                except Exception:
                    existing_secret = ''
        self._public_direct_totp_var = tk.StringVar(value=existing_secret)
        tk.Label(
            totp_row,
            textvariable=self._public_direct_totp_var,
            fg='gray',
            font=('Consolas', 10),
        ).pack(side='left', padx=(8, 0))

        # Buttons
        btn_row = tk.Frame(outer)
        btn_row.pack(fill='x', pady=(16, 4))
        tk.Button(btn_row, text='保存', command=self._on_public_direct_save).pack(side='left')
        tk.Button(btn_row, text='生成直连配置二维码', command=self._on_public_direct_generate_qr).pack(side='left', padx=(8, 0))

        hint = tk.Label(
            outer,
            text='提示：保存后请在 NAS frpc 中配置 公网端口 → 电脑内网IP:监听端口。',
            anchor='w',
            fg='gray',
            wraplength=480,
            justify='left',
        )
        hint.pack(fill='x', pady=(8, 0))

    def _on_public_direct_random_port(self):
        for _ in range(8):
            candidate = random.randint(30000, 65535)
            if candidate not in (30000, 30100, 47823, 47900, 50000, 58080, 58081, 58082):
                break
        self._public_direct_port_var.set(str(candidate))
        if not self._public_direct_public_port_var.get().strip():
            self._public_direct_public_port_var.set(str(candidate))

    def _on_public_direct_save(self):
        try:
            listen_port = int((self._public_direct_port_var.get() or '0').strip() or '0')
        except Exception:
            listen_port = 0
        try:
            public_port = int((self._public_direct_public_port_var.get() or '0').strip() or '0')
        except Exception:
            public_port = 0
        whitelist_raw = self._public_direct_whitelist_text.get('1.0', 'end').splitlines()
        whitelist = [line.strip() for line in whitelist_raw if line.strip()]
        settings = {
            'enabled': bool(self._public_direct_enabled_var.get()),
            'listen_host': '0.0.0.0',
            'listen_port': listen_port,
            'public_host': (self._public_direct_host_var.get() or '').strip(),
            'public_port': public_port,
            'download_whitelist': whitelist,
        }
        # Keep the existing TOTP secret (we don't let the UI overwrite it
        # unless it's still empty).
        current = self._get_agent_public_direct()
        existing_secret = (current.get('totp_secret') or '').strip()
        if existing_secret:
            settings['totp_secret'] = existing_secret
        else:
            agent = getattr(self, '_agent', None)
            loader = getattr(agent, '_state_store', None) if agent is not None else None
            if loader is not None and hasattr(loader, 'load_or_create_totp_secret'):
                settings['totp_secret'] = loader.load_or_create_totp_secret()
        agent = getattr(self, '_agent', None)
        updater = getattr(agent, 'update_public_direct_settings', None) if agent is not None else None
        logger.info(f'[public_direct_save] agent={agent is not None}, updater={callable(updater)}')
        if callable(updater):
            normalized = updater(settings)
        else:
            logger.warning('[public_direct_save] updater not callable, using raw settings')
            normalized = settings
        if normalized.get('totp_secret'):
            self._public_direct_totp_var.set(str(normalized['totp_secret']))
        try:
            self._status_update_callback('公网直连设置已保存')
        except Exception:
            pass

    def _on_public_direct_generate_qr(self):
        try:
            public_port = int((self._public_direct_public_port_var.get() or '0').strip() or '0')
        except Exception:
            public_port = 0
        public_host = (self._public_direct_host_var.get() or '').strip()
        missing = []
        if not public_host:
            missing.append('公网地址（域名或 IP）')
        if public_port <= 0:
            missing.append('公网端口')
        if missing:
            messagebox.showwarning(
                'PocketWindow 公网直连',
                '生成二维码前请先填写：\n - ' + '\n - '.join(missing),
                parent=self._root,
            )
            return
        device_id = self._device_id_getter()
        totp_secret = (self._public_direct_totp_var.get() or '').strip()
        if not totp_secret:
            self._on_public_direct_save()
            totp_secret = (self._public_direct_totp_var.get() or '').strip()
        if not totp_secret:
            messagebox.showwarning(
                'PocketWindow 公网直连',
                'TOTP 密钥未生成，请先点一次「保存」。',
                parent=self._root,
            )
            return
        payload = {
            'v': 1,
            'type': 'pw-direct',
            'device_id': device_id,
            'direct_host': public_host,
            'direct_port': int(public_port),
            'totp_secret': totp_secret,
        }
        try:
            import json as _json
            import qrcode
            from PIL import ImageTk
            payload_str = _json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
            qr = qrcode.QRCode(border=2, box_size=5)
            qr.add_data(payload_str)
            qr.make(fit=True)
            image = qr.make_image(fill_color='black', back_color='white').convert('RGB')
            if self._qr_label is not None:
                self._qr_photo = ImageTk.PhotoImage(image)
                self._qr_label.configure(image=self._qr_photo, text='')
                try:
                    self._notebook.select(self._pair_tab_frame)
                except Exception:
                    pass
                try:
                    self._status_update_callback('已生成直连配置二维码，请在配对标签页扫码')
                except Exception:
                    pass
            else:
                messagebox.showinfo(
                    'PocketWindow 公网直连',
                    '二维码已生成（界面尚未渲染）。',
                    parent=self._root,
                )
        except Exception as exc:
            messagebox.showerror(
                'PocketWindow 公网直连',
                f'生成二维码失败：{exc}',
                parent=self._root,
            )

    def _run_on_ui_thread(self, callback: Callable[[], None]):
        if self._root is None:
            return
        if threading.get_ident() == self._main_thread_id:
            callback()
            return
        with self._ui_tasks_lock:
            self._ui_tasks.append(callback)

    def _drain_ui_tasks(self):
        while True:
            with self._ui_tasks_lock:
                if not self._ui_tasks:
                    return
                callback = self._ui_tasks.popleft()
            try:
                callback()
            except Exception:
                continue

    def _schedule_theme_apply(self):
        if self._root is None or self._theme_apply_pending:
            return
        self._theme_apply_pending = True

        def apply_later():
            self._theme_apply_pending = False
            try:
                self._apply_theme()
            except Exception as exc:
                logger.exception('apply theme failed: %s', exc)
                self._theme_name = 'classic'
                if self._theme_var is not None:
                    self._theme_var.set('classic')
                self._theme_setter('classic')
                try:
                    self._apply_theme()
                except Exception:
                    logger.exception('fallback classic theme apply failed')

        self._root.after_idle(apply_later)

    def _theme(self) -> dict:
        return resolve_theme(self._theme_name)

    def _configure_combobox_style(self, theme: dict):
        configure_ttk_styles(self._ttk_style, theme)

    def _apply_theme(self):
        if self._root is None:
            return
        theme = self._theme()
        self._configure_combobox_style(theme)

        self._root.configure(bg=theme['window_bg'])
        if self._root_frame:
            self._root_frame.configure(bg=theme['window_bg'])
        if self._header_bar:
            self._header_bar.configure(bg=theme['window_bg'])
        if self._pair_tab_frame:
            self._pair_tab_frame.configure(bg=theme['window_bg'])
        if self._status_tab_frame:
            self._status_tab_frame.configure(bg=theme['window_bg'])
        if self._settings_tab_frame:
            self._settings_tab_frame.configure(bg=theme['window_bg'])
        if self._hero_frame:
            self._hero_frame.configure(
                bg=theme['panel_bg'],
                highlightbackground=theme['panel_border'],
                highlightcolor=theme['panel_border'],
            )
        if self._hero_top_frame:
            self._hero_top_frame.configure(bg=theme['panel_bg'])
        if self._pair_card_frame:
            self._pair_card_frame.configure(
                bg=theme['pair_card_bg'],
                highlightbackground=theme['panel_border'],
                highlightcolor=theme['panel_border'],
            )
        if self._room_row_frame:
            self._room_row_frame.configure(bg=theme['pair_card_bg'])
        if self._panels_frame:
            self._panels_frame.configure(bg=theme['window_bg'])
        if self._trusted_panel_frame:
            self._trusted_panel_frame.configure(
                bg=theme['panel_alt_bg'],
                highlightbackground=theme['panel_border'],
                highlightcolor=theme['panel_border'],
            )
        if self._settings_panel_frame:
            self._settings_panel_frame.configure(
                bg=theme['panel_alt_bg'],
                highlightbackground=theme['panel_border'],
                highlightcolor=theme['panel_border'],
            )
        if self._hero_title_label:
            self._hero_title_label.configure(
                bg=theme['panel_bg'],
                fg=theme['accent_text'],
                font=theme['title_font'],
            )
        if self._hero_subtitle_label:
            self._hero_subtitle_label.configure(
                bg=theme['panel_bg'],
                fg=theme['muted_text'],
                font=theme['body_font'],
                text=theme['hero_subtitle'],
            )
        if self._theme_badge_label:
            self._theme_badge_label.configure(
                bg=theme['badge_bg'],
                fg=theme['badge_fg'],
                font=theme['heading_font'],
                padx=10,
                pady=4,
                text=theme['theme_label'],
            )
        if self._qr_label:
            self._qr_label.configure(bg=theme['pair_card_bg'])
        if self._trusted_panel:
            self._trusted_panel.configure(
                bg=theme['panel_alt_bg'],
                fg=theme['text'],
                font=theme['mono_font'],
                insertbackground=theme['text'],
                selectbackground=theme['panel_border'],
                selectforeground=theme['text'],
            )
        if self._trusted_scrollbar:
            self._trusted_scrollbar.configure(
                activebackground=theme['panel_border'],
                background=theme['panel_alt_bg'],
                troughcolor=theme['window_bg'],
            )
        if self._status_panel:
            self._status_panel.configure(
                bg=theme['panel_alt_bg'],
                fg=theme['accent_text'],
                font=theme['body_font'],
                highlightbackground=theme['panel_border'],
                highlightcolor=theme['panel_border'],
            )
        if self._startup_check:
            self._startup_check.configure(
                bg=theme['panel_alt_bg'],
                fg=theme['text'],
                activebackground=theme['panel_alt_bg'],
                activeforeground=theme['text'],
                selectcolor=theme['panel_bg'],
                font=theme['body_font'],
            )
        for label in self._section_labels:
            label.configure(
                bg=theme['window_bg'],
                fg=theme['text'],
                font=theme['heading_font'],
            )
        for label in self._meta_labels:
            label.configure(
                bg=theme['window_bg'],
                fg=theme['muted_text'],
                font=theme['body_font'],
            )

        for child in self._pair_card_frame.winfo_children() if self._pair_card_frame else []:
            if isinstance(child, tk.Label):
                if child is self._qr_label:
                    continue
                child.configure(
                    bg=theme['pair_card_bg'],
                    fg=theme['pair_card_fg'],
                    font=theme['body_font'] if child.cget('text') != self._pair_code else theme['code_font'],
                )
            elif isinstance(child, tk.Frame):
                child.configure(bg=theme['pair_card_bg'])
                for grandchild in child.winfo_children():
                    if isinstance(grandchild, tk.Label):
                        grandchild.configure(
                            bg=theme['pair_card_bg'],
                            fg=theme['pair_card_fg'],
                            font=theme['body_font'],
                        )
        if self._pair_code_var and self._pair_card_frame:
            labels = [child for child in self._pair_card_frame.winfo_children() if isinstance(child, tk.Label)]
            if len(labels) >= 2:
                labels[1].configure(font=theme['code_font'])

    def _on_theme_changed(self, _event=None):
        if not self._theme_var:
            return
        self._theme_name = self._theme_var.get().strip().lower()
        self._theme_setter(self._theme_name)
        self._schedule_theme_apply()

    def _on_startup_changed(self):
        if self._startup_var is None:
            return
        enabled = bool(self._startup_var.get())
        if self._startup_setter(enabled):
            self._status_update_callback('已开启开机随系统启动' if enabled else '已关闭开机随系统启动')
            return
        self._startup_var.set(not enabled)
        if self._root is not None:
            messagebox.showerror(
                'PocketWindow 配置',
                '开机随系统启动设置失败，请检查系统权限后重试。',
                parent=self._root,
            )

    # --- Signaling endpoints panel ----------------------------------------

    def _current_endpoints(self) -> list[dict]:
        if self._signaling_endpoints_getter is None:
            return []
        try:
            return list(self._signaling_endpoints_getter() or [])
        except Exception:
            logger.exception('signaling_endpoints_getter failed')
            return []

    def _commit_endpoints(self, endpoints: list[dict]) -> bool:
        if self._signaling_endpoints_setter is None:
            return False
        try:
            self._signaling_endpoints_setter(endpoints)
            # The pair QR embeds the endpoint list, so a successful commit
            # must refresh it; otherwise the phone scans the previous data.
            self.refresh_qr_image()
            return True
        except Exception:
            logger.exception('signaling_endpoints_setter failed')
            if self._root:
                messagebox.showerror(
                    'PocketWindow 信令服务器',
                    '保存信令服务器配置失败，请稍后重试。',
                    parent=self._root,
                )
            return False

    def _refresh_endpoints_list(self):
        listbox = self._endpoints_listbox
        if listbox is None:
            return
        endpoints = self._current_endpoints()
        listbox.delete(0, 'end')
        if not endpoints:
            listbox.insert('end', '（尚未添加，点击下方“新增”）')
            listbox.itemconfig(0, foreground='gray')
            return
        for entry in endpoints:
            mark = '●' if entry.get('enabled', True) else '○'
            label = f"{mark} {entry.get('name') or entry.get('url', '')}    {entry.get('url', '')}"
            listbox.insert('end', label)

    def _refresh_route_label(self):
        var = self._endpoints_route_var
        if var is None:
            return
        if self._signaling_route_getter is None:
            var.set('当前：未连接')
        else:
            try:
                route, host, port = self._signaling_route_getter()
            except Exception:
                logger.exception('signaling_route_getter failed')
                route, host, port = 'unknown', '', 0
            if route == 'lan':
                var.set(f'当前：局域网  {host}:{port}')
            elif route == 'wan':
                var.set(f'当前：外网  {host}:{port}')
            elif route == 'unconfigured':
                var.set('当前：未配置任何信令服务器')
            else:
                var.set('当前：未连接')
        # Schedule the next refresh while the UI is alive.
        if self._root is not None:
            try:
                if self._endpoints_route_refresh_after_id is not None:
                    self._root.after_cancel(self._endpoints_route_refresh_after_id)
            except Exception:
                pass
            self._endpoints_route_refresh_after_id = self._root.after(2000, self._refresh_route_label)

    def _selected_endpoint_index(self) -> Optional[int]:
        listbox = self._endpoints_listbox
        if listbox is None:
            return None
        selection = listbox.curselection()
        if not selection:
            return None
        idx = int(selection[0])
        endpoints = self._current_endpoints()
        if idx < 0 or idx >= len(endpoints):
            return None
        return idx

    def _prompt_endpoint_dialog(self, initial: Optional[dict] = None) -> Optional[dict]:
        if self._root is None:
            return None
        dialog = tk.Toplevel(self._root)
        dialog.title('信令服务器')
        dialog.transient(self._root)
        dialog.grab_set()
        dialog.resizable(False, False)

        result: dict = {}

        tk.Label(dialog, text='名称（可选）').grid(row=0, column=0, sticky='w', padx=12, pady=(12, 4))
        name_var = tk.StringVar(value=str((initial or {}).get('name') or ''))
        name_entry = tk.Entry(dialog, textvariable=name_var, width=36)
        name_entry.grid(row=0, column=1, padx=(0, 12), pady=(12, 4))

        tk.Label(dialog, text='地址').grid(row=1, column=0, sticky='w', padx=12, pady=4)
        url_var = tk.StringVar(value=str((initial or {}).get('url') or ''))
        url_entry = tk.Entry(dialog, textvariable=url_var, width=36)
        url_entry.grid(row=1, column=1, padx=(0, 12), pady=4)

        tk.Label(
            dialog,
            text='示例：signal.example.com:80 或 ws://192.168.1.10:58080',
            fg='gray',
        ).grid(row=2, column=0, columnspan=2, sticky='w', padx=12)

        button_frame = tk.Frame(dialog)
        button_frame.grid(row=3, column=0, columnspan=2, sticky='e', padx=12, pady=(12, 12))

        def _commit():
            url = url_var.get().strip()
            if not url:
                messagebox.showerror('PocketWindow', '地址不能为空', parent=dialog)
                return
            result['name'] = name_var.get().strip()
            result['url'] = url
            dialog.destroy()

        def _cancel():
            dialog.destroy()

        tk.Button(button_frame, text='取消', command=_cancel).pack(side='right', padx=(8, 0))
        tk.Button(button_frame, text='确定', command=_commit).pack(side='right')
        url_entry.focus_set()
        self._root.wait_window(dialog)
        if not result.get('url'):
            return None
        return result

    def _on_endpoint_add(self):
        prompt = self._prompt_endpoint_dialog()
        if prompt is None:
            return
        endpoints = self._current_endpoints()
        next_priority = max((int(e.get('priority') or 0) for e in endpoints), default=-1) + 1
        endpoints.append({
            'name': prompt.get('name') or '',
            'url': prompt['url'],
            'priority': next_priority,
            'enabled': True,
        })
        if self._commit_endpoints(endpoints):
            self._refresh_endpoints_list()

    def _on_endpoint_edit(self):
        idx = self._selected_endpoint_index()
        if idx is None:
            return
        endpoints = self._current_endpoints()
        prompt = self._prompt_endpoint_dialog(endpoints[idx])
        if prompt is None:
            return
        endpoints[idx]['name'] = prompt.get('name') or ''
        endpoints[idx]['url'] = prompt['url']
        if self._commit_endpoints(endpoints):
            self._refresh_endpoints_list()

    def _on_endpoint_delete(self):
        idx = self._selected_endpoint_index()
        if idx is None:
            return
        endpoints = self._current_endpoints()
        target = endpoints[idx]
        if self._root is not None:
            confirm = messagebox.askyesno(
                'PocketWindow',
                f'确定删除“{target.get("name") or target.get("url")}”？',
                parent=self._root,
            )
            if not confirm:
                return
        endpoints.pop(idx)
        if self._commit_endpoints(endpoints):
            self._refresh_endpoints_list()

    def _on_endpoint_move(self, delta: int):
        idx = self._selected_endpoint_index()
        if idx is None:
            return
        endpoints = self._current_endpoints()
        new_idx = idx + delta
        if new_idx < 0 or new_idx >= len(endpoints):
            return
        endpoints[idx], endpoints[new_idx] = endpoints[new_idx], endpoints[idx]
        # Renumber priorities so the new visible order maps to the routing order.
        for i, entry in enumerate(endpoints):
            entry['priority'] = i
        if self._commit_endpoints(endpoints):
            self._refresh_endpoints_list()
            if self._endpoints_listbox is not None:
                self._endpoints_listbox.selection_clear(0, 'end')
                self._endpoints_listbox.selection_set(new_idx)
                self._endpoints_listbox.activate(new_idx)

    def _on_endpoint_toggle_enabled(self):
        idx = self._selected_endpoint_index()
        if idx is None:
            return
        endpoints = self._current_endpoints()
        endpoints[idx]['enabled'] = not bool(endpoints[idx].get('enabled', True))
        if self._commit_endpoints(endpoints):
            self._refresh_endpoints_list()

    def set_status(self, message: str):
        self._status_text = message
        if self._root and self._status_var:
            snapshot = self._status_snapshot_getter()
            self._run_on_ui_thread(lambda: self._status_var.set(self._compose_status_text(snapshot)))

    def refresh_snapshot(self):
        snapshot = self._status_snapshot_getter()
        if self._root and self._status_var:
            composed = self._compose_status_text(snapshot)
            if snapshot != self._last_status_snapshot_text or self._status_var.get() != composed:
                self._last_status_snapshot_text = snapshot
                self._run_on_ui_thread(lambda: self._status_var.set(composed))
        trusted_snapshot = self._trusted_snapshot_getter()
        if self._root and self._trusted_panel:
            if trusted_snapshot != self._last_trusted_snapshot_text:
                self._last_trusted_snapshot_text = trusted_snapshot
                self._run_on_ui_thread(lambda: self._set_trusted_snapshot_text(trusted_snapshot))

    def _compose_status_text(self, snapshot: str) -> str:
        note = str(self._status_text or '').strip()
        details = str(snapshot or '').strip()
        if note and details:
            return f'{note}\n\n{details}'
        return note or details

    def set_pairing_info(self, room_id: str, pair_code: str):
        self._room_id = room_id
        self._pair_code = pair_code
        if self._root and self._pair_code_var and self._room_var:
            self._run_on_ui_thread(lambda: self._pair_code_var.set(pair_code))
            self._run_on_ui_thread(lambda: self._room_var.set(room_id))
            self._run_on_ui_thread(self.refresh_qr_image)

    def refresh_qr_image(self):
        if not self._qr_label:
            return
        theme = self._theme()
        device_id = self._device_id_getter()
        if not device_id or not self._pair_code or self._pair_code == '------':
            self._qr_label.configure(image='', text='等待配对码...', fg=theme['muted_text'])
            return
        # Single QR carries everything the phone needs to pair *and* sync the
        # signaling endpoint list in one scan. Old desktop builds emitted
        # `pocketwindow://pair?device_id=...&pair_code=...`; the phone's
        # scanner accepts both formats so this is a forward-compatible upgrade.
        endpoints_payload = []
        if self._signaling_endpoints_getter is not None:
            try:
                for entry in (self._signaling_endpoints_getter() or []):
                    if not entry.get('url'):
                        continue
                    endpoints_payload.append({
                        'name': entry.get('name') or '',
                        'url': entry.get('url'),
                        'priority': int(entry.get('priority') or 0),
                    })
            except Exception:
                logger.exception('signaling_endpoints_getter failed while building pair QR')
        payload_obj = {
            'v': 1,
            'type': 'pw-pair',
            'device_id': device_id,
            'pair_code': self._pair_code,
            'endpoints': endpoints_payload,
        }
        import json as _json
        payload = _json.dumps(payload_obj, ensure_ascii=False, separators=(',', ':'))
        qr = qrcode.QRCode(border=2, box_size=5)
        qr.add_data(payload)
        qr.make(fit=True)
        image = qr.make_image(fill_color='black', back_color='white').convert('RGB')
        photo = ImageTk.PhotoImage(image)
        self._qr_photo = photo
        self._qr_label.configure(image=photo, text='')

    def _set_trusted_snapshot_text(self, text: str):
        if self._trusted_panel is None:
            return
        yview = self._trusted_panel.yview()
        self._trusted_panel.configure(state='normal')
        self._trusted_panel.delete('1.0', tk.END)
        self._trusted_panel.insert('1.0', text)
        self._trusted_panel.configure(state='disabled')
        if yview:
            self._trusted_panel.yview_moveto(yview[0])

    def _tick(self):
        if self._root is None:
            return
        self._drain_ui_tasks()

        while self._pair_prompt_queue:
            payload = self._pair_prompt_queue.pop(0)
            client_name = payload.get('client_name') or '未命名手机'
            client_id = str(payload.get('client_id') or '').strip()
            request_id = payload.get('request_id')
            approved = messagebox.askyesno(
                '新的绑定申请',
                f'手机“{client_name}”请求绑定这台电脑。\n\n是否允许？',
                parent=self._root,
            )
            if request_id:
                self._pair_request_approver(request_id, approved)
                if approved:
                    self._trusted_client_rememberer(client_id, str(client_name))
                self._status_update_callback('已同意新的绑定请求' if approved else '已拒绝新的绑定请求')

        while self._update_prompt_queue:
            payload = self._update_prompt_queue.pop(0)
            callback = payload.get('callback')
            release = payload.get('release') if isinstance(payload.get('release'), dict) else {}
            remote_version = str(release.get('version') or '').strip() or '未知版本'
            notes = str(release.get('notes') or '').strip()
            force_update = release.get('force_update') is True
            approved = messagebox.askyesno(
                'PocketWindow 更新',
                f'检测到新版本 {remote_version}。\n\n{notes or "是否现在更新并重启电脑端？"}',
                parent=self._root,
            )
            if callable(callback):
                try:
                    callback(approved, force_update, remote_version)
                except Exception:
                    logger.exception('update prompt callback failed')

        self.refresh_snapshot()
        self._root.after(250, self._tick)

    def _terminal_tick(self):
        # Higher-frequency loop dedicated to the terminal so TUI output stays
        # smooth. Cheap when nothing changed thanks to the cells-signature guard.
        if self._root is None:
            return
        try:
            self._refresh_terminal_tab()
        except Exception:
            logger.exception('terminal tick failed')
        self._root.after(80, self._terminal_tick)
