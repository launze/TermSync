THEME_COMBO_STYLE = 'PocketWindow.TCombobox'
NOTEBOOK_STYLE = 'PocketWindow.TNotebook'
NOTEBOOK_TAB_STYLE = 'PocketWindow.TNotebook.Tab'


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
        'theme_label': 'Classic',
        'hero_subtitle': 'Scan the QR code or enter the pairing code on your phone.',
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
        'theme_label': 'Mabinogi',
        'hero_subtitle': 'Manage pairing and control status from the desktop agent.',
        'pair_card_bg': '#4A3A28',
        'pair_card_fg': '#FFE7AE',
        'badge_bg': '#6E5431',
        'badge_fg': '#FFE7AE',
        'combo_bg': '#473A2D',
        'combo_fg': '#F5E8C8',
    },
}


def resolve_theme(theme_name: str) -> dict:
    return THEMES.get(theme_name, THEMES['classic'])


def configure_ttk_styles(ttk_style, theme: dict):
    if ttk_style is None:
        return
    try:
        ttk_style.theme_use('clam')
    except Exception:
        pass
    ttk_style.configure(
        THEME_COMBO_STYLE,
        foreground=theme['combo_fg'],
        fieldbackground=theme['combo_bg'],
        background=theme['combo_bg'],
        arrowcolor=theme['combo_fg'],
        bordercolor=theme['panel_border'],
        lightcolor=theme['panel_border'],
        darkcolor=theme['panel_border'],
        insertcolor=theme['combo_fg'],
        padding=4,
    )
    ttk_style.map(
        THEME_COMBO_STYLE,
        fieldbackground=[('readonly', theme['combo_bg'])],
        foreground=[('readonly', theme['combo_fg'])],
        selectbackground=[('readonly', theme['combo_bg'])],
        selectforeground=[('readonly', theme['combo_fg'])],
        background=[('readonly', theme['combo_bg'])],
        arrowcolor=[('readonly', theme['combo_fg'])],
    )
    ttk_style.configure(
        NOTEBOOK_STYLE,
        background=theme['window_bg'],
        borderwidth=0,
        tabmargins=[0, 0, 0, 0],
    )
    ttk_style.configure(
        NOTEBOOK_TAB_STYLE,
        background=theme['panel_alt_bg'],
        foreground=theme['muted_text'],
        padding=(18, 8),
        borderwidth=0,
        font=theme['heading_font'],
    )
    ttk_style.map(
        NOTEBOOK_TAB_STYLE,
        background=[('selected', theme['panel_bg'])],
        foreground=[('selected', theme['accent_text'])],
    )
