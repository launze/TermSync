from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class PeakLimitConfig:
    bytes_per_second: int
    max_fps: float
    min_scale: float
    target_bitrate_kbps: int


@dataclass(frozen=True)
class PeakLimitDecision:
    ok_to_send: bool
    reason: str = ''


class VideoPeakLimiter:
    """Applies fixed per-profile stream budgets without dropping frames."""

    PROFILE_LIMITS = {
        'hybrid': PeakLimitConfig(
            bytes_per_second=5 * 1024 * 1024,
            max_fps=15.0,
            min_scale=0.70,
            target_bitrate_kbps=3000,
        ),
        'smooth_hd': PeakLimitConfig(
            bytes_per_second=5 * 1024 * 1024,
            max_fps=40.0,
            min_scale=0.75,
            target_bitrate_kbps=8000,
        ),
        'lan': PeakLimitConfig(
            bytes_per_second=5 * 1024 * 1024,
            max_fps=60.0,
            min_scale=1.0,
            target_bitrate_kbps=25000,
        ),
    }

    def __init__(self) -> None:
        self._last_sent_bytes = 0
        self._last_profile_id = ''

    def config_for(self, profile_id: str) -> PeakLimitConfig:
        return self.PROFILE_LIMITS.get(profile_id, self.PROFILE_LIMITS['hybrid'])

    def tune_params(
        self,
        profile_id: str,
        encode_params: dict,
        *,
        scroll_mode_active: bool,
        diff_value: float,
        scroll_tuning: Optional[dict] = None,
    ) -> dict:
        config = self.config_for(profile_id)
        params = dict(encode_params)
        if scroll_mode_active and scroll_tuning:
            target_fps = min(60.0, max(1.0, float(scroll_tuning.get('fps', 15.0) or 15.0)))
            requested_scale = min(
                1.0,
                max(config.min_scale, float(scroll_tuning.get('scale', config.min_scale) or config.min_scale)),
            )
            scale = requested_scale
            bitrate_kbps = max(
                128,
                int(float(scroll_tuning.get('bitrate_kbps', config.target_bitrate_kbps) or config.target_bitrate_kbps)),
            )
            crf = str(scroll_tuning.get('crf', params.get('crf', '24')) or '24')
            bufsize_multiplier = max(
                2,
                min(8, int(float(scroll_tuning.get('vbv_multiplier', 6 if profile_id == 'lan' else 3) or 3))),
            )
            pixel_format = str(scroll_tuning.get('pixel_format', 'yuv420p') or 'yuv420p').strip().lower()
            if pixel_format not in {'yuv420p', 'yuv444p'}:
                pixel_format = 'yuv420p'
            preset = str(scroll_tuning.get('preset', 'veryfast') or 'veryfast').strip().lower()
            if preset not in {'ultrafast', 'superfast', 'veryfast', 'faster', 'fast'}:
                preset = 'veryfast'
            params['target_fps'] = target_fps
            params['scale'] = scale
            params['target_bitrate_kbps'] = bitrate_kbps
            params['crf'] = crf
            params['bufsize_multiplier'] = bufsize_multiplier
            params['pixel_format'] = pixel_format
            params['preset'] = preset
            params['scroll_fixed_tuning'] = True
            params['min_send_interval'] = 1.0 / target_fps
            params['loop_sleep'] = 1.0 / target_fps
            params['peak_bytes_per_second'] = config.bytes_per_second
            params['peak_frame_budget_bytes'] = self.frame_budget_bytes(profile_id, target_fps)
            return params

        requested_fps = float(params.get('target_fps', config.max_fps) or config.max_fps)
        target_fps = min(max(1.0, requested_fps), config.max_fps)
        params['target_fps'] = target_fps
        params['min_send_interval'] = max(
            float(params.get('min_send_interval', 0.0) or 0.0),
            1.0 / target_fps,
        )
        params['loop_sleep'] = max(
            float(params.get('loop_sleep', 0.0) or 0.0),
            1.0 / target_fps,
        )
        params['peak_bytes_per_second'] = config.bytes_per_second
        params['peak_frame_budget_bytes'] = self.frame_budget_bytes(profile_id, target_fps)
        params['target_bitrate_kbps'] = config.target_bitrate_kbps
        params['scale'] = 1.0 if profile_id == 'lan' else 0.75 if profile_id == 'smooth_hd' else 0.70
        params['bufsize_multiplier'] = 6 if profile_id == 'lan' else 2
        params['pixel_format'] = 'yuv420p'
        params['preset'] = 'veryfast'
        params['crf'] = str(params.get('crf') or (18 if profile_id == 'lan' else 22 if profile_id == 'smooth_hd' else 28))

        return params

    def frame_budget_bytes(self, profile_id: str, fps: float) -> int:
        config = self.config_for(profile_id)
        safe_fps = max(1.0, min(float(fps or config.max_fps), config.max_fps))
        return max(4 * 1024, int(config.bytes_per_second / safe_fps))

    def assess_encoded_frame(
        self,
        profile_id: str,
        *,
        encoded_bytes: int,
        fps: float,
        attempt: int,
        current_scale: float,
    ) -> PeakLimitDecision:
        config = self.config_for(profile_id)
        budget = self.frame_budget_bytes(profile_id, fps)
        if encoded_bytes <= budget:
            self._last_sent_bytes = int(encoded_bytes)
            self._last_profile_id = profile_id
            return PeakLimitDecision(ok_to_send=True)

        self._last_sent_bytes = int(encoded_bytes)
        self._last_profile_id = profile_id
        return PeakLimitDecision(
            ok_to_send=True,
            reason=f'send_over_peak_budget:{encoded_bytes}>{budget}',
        )
