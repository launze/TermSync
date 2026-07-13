from __future__ import annotations

import asyncio
import logging
import threading
import time
from typing import Callable, Optional


logger = logging.getLogger('PocketWindowAgent')


class DirectTransport:
    def __init__(self, send_signal: Callable[[str, dict], bool], frame_provider=None):
        self._send_signal = send_signal
        self._frame_provider = frame_provider
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(
            target=self._run_loop,
            daemon=True,
            name='direct-transport',
        )
        self._thread.start()
        self._pc = None
        self._video_track = None
        self._video_active = False
        self._probe_id: Optional[str] = None

    @property
    def video_active(self) -> bool:
        return self._video_active

    def _run_loop(self):
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def handle_signal(self, data: dict):
        signal_type = str(data.get('type') or '')
        future = asyncio.run_coroutine_threadsafe(
            self._handle_signal_async(signal_type, data),
            self._loop,
        )
        future.add_done_callback(self._log_task_error)

    def close(self):
        future = asyncio.run_coroutine_threadsafe(self._close_async(), self._loop)
        future.add_done_callback(self._log_task_error)

    async def _handle_signal_async(self, signal_type: str, data: dict):
        try:
            if signal_type == 'webrtc_offer':
                await self._handle_offer(data)
            elif signal_type == 'webrtc_ice_candidate':
                await self._handle_ice_candidate(data)
        except ModuleNotFoundError as exc:
            logger.warning('WebRTC direct transport unsupported: %s', exc)
            self._send_signal(
                'webrtc_transport_state',
                {
                    'state': 'unsupported',
                    'reason': str(exc),
                    'probe_id': data.get('probe_id'),
                },
            )
        except Exception as exc:
            logger.exception('WebRTC direct transport failed')
            self._send_signal(
                'webrtc_transport_state',
                {
                    'state': 'failed',
                    'reason': str(exc),
                    'probe_id': data.get('probe_id'),
                },
            )

    async def _handle_offer(self, data: dict):
        from aiortc import RTCBundlePolicy, RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription

        await self._close_async()
        probe_id = str(data.get('probe_id') or '')
        self._probe_id = probe_id
        self._pc = RTCPeerConnection(
            RTCConfiguration(
                iceServers=self._parse_ice_servers(data.get('ice_servers'), RTCIceServer),
                bundlePolicy=RTCBundlePolicy.MAX_BUNDLE,
            ),
        )
        pc = self._pc
        if self._frame_provider is not None:
            try:
                self._video_track = _PocketWindowVideoTrack(self._frame_provider)
                pc.addTrack(self._video_track)
                logger.info('WebRTC video track added')
            except Exception as exc:
                self._video_track = None
                logger.warning('Failed to add WebRTC video track: %s', exc)

        @pc.on('connectionstatechange')
        async def on_connectionstatechange():
            if self._pc is not pc:
                return
            logger.info('WebRTC direct connection state: %s', pc.connectionState)
            self._video_active = pc.connectionState == 'connected' and self._video_track is not None
            self._send_signal(
                'webrtc_transport_state',
                {
                    'state': pc.connectionState,
                    'probe_id': probe_id,
                    'video': self._video_active,
                },
            )
            if pc.connectionState in ('failed', 'closed', 'disconnected'):
                await self._close_async()

        sdp = str(data.get('sdp') or '')
        sdp_type = str(data.get('sdp_type') or 'offer')
        if not sdp:
            raise ValueError('missing WebRTC offer SDP')
        await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=sdp_type))
        answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        await self._wait_for_ice_complete(pc)
        self._send_signal(
            'webrtc_answer',
            {
                'probe_id': probe_id,
                'sdp': self._relay_only_sdp(pc.localDescription.sdp),
                'sdp_type': pc.localDescription.type,
            },
        )

    async def _handle_ice_candidate(self, data: dict):
        from aiortc.sdp import candidate_from_sdp

        pc = self._pc
        if pc is None:
            return
        probe_id = str(data.get('probe_id') or '')
        if self._probe_id and probe_id and probe_id != self._probe_id:
            return
        candidate_payload = data.get('candidate')
        if not isinstance(candidate_payload, dict):
            return
        candidate_line = str(candidate_payload.get('candidate') or '').strip()
        if not candidate_line:
            await pc.addIceCandidate(None)
            return
        logger.info(
            'WebRTC remote ICE candidate received: relay=%s line=%s',
            ' typ relay ' in candidate_line,
            candidate_line[:180],
        )
        if candidate_line.startswith('candidate:'):
            candidate_line = candidate_line[len('candidate:'):]
        candidate = candidate_from_sdp(candidate_line)
        sdp_mid = candidate_payload.get('sdpMid')
        sdp_mline_index = candidate_payload.get('sdpMLineIndex')
        if sdp_mid is not None:
            candidate.sdpMid = str(sdp_mid)
        if sdp_mline_index is not None:
            try:
                candidate.sdpMLineIndex = int(sdp_mline_index)
            except Exception:
                pass
        await pc.addIceCandidate(candidate)

    def _parse_ice_servers(self, raw_servers, ice_server_cls) -> list:
        """Build the agent-side ICE server list from whatever the phone
        offered.

        The phone has already filtered the configured ICE servers down to
        TURN-over-TCP entries; we just normalize the payload into the type
        aiortc expects. Returning an empty list means "no relay servers
        available" which lets aiortc surface a clean failure rather than
        connecting to a baked-in URL that may not exist for this user.
        """
        servers: list = []
        if isinstance(raw_servers, list):
            for entry in raw_servers:
                if not isinstance(entry, dict):
                    continue
                raw_urls = entry.get('urls')
                urls: list[str] = []
                if isinstance(raw_urls, str) and raw_urls.strip():
                    urls = [raw_urls.strip()]
                elif isinstance(raw_urls, list):
                    urls = [str(u).strip() for u in raw_urls if str(u or '').strip()]
                if not urls:
                    continue
                username = entry.get('username')
                credential = entry.get('credential')
                kwargs = {'urls': urls if len(urls) > 1 else urls[0]}
                if username is not None:
                    kwargs['username'] = str(username)
                if credential is not None:
                    kwargs['credential'] = str(credential)
                try:
                    servers.append(ice_server_cls(**kwargs))
                except Exception:
                    logger.warning('skipped malformed ICE server entry: %s', entry)
        if servers:
            logger.info('WebRTC ICE servers from peer: count=%d', len(servers))
        else:
            logger.info('WebRTC ICE servers: none provided by peer')
        return servers

    def _relay_only_sdp(self, sdp: str) -> str:
        lines = str(sdp or '').splitlines()
        candidate_lines = [line for line in lines if line.startswith('a=candidate:')]
        relay_lines = [line for line in candidate_lines if ' typ relay ' in line]
        host_lines = [line for line in candidate_lines if ' typ host ' in line]
        if not relay_lines:
            logger.info(
                'WebRTC answer SDP has no relay candidates, sending empty candidate SDP: host=%s candidates=%s',
                len(host_lines),
                len(candidate_lines),
            )
            return self._without_candidate_sdp(lines)

        next_lines = []
        removed = 0
        kept = 0
        for line in lines:
            if line.startswith('a=candidate:'):
                if ' typ relay ' in line:
                    next_lines.append(line)
                    kept += 1
                else:
                    removed += 1
                continue
            next_lines.append(line)
        logger.info('WebRTC answer relay-only SDP candidates: kept=%s removed=%s', kept, removed)
        return '\r\n'.join(next_lines) + '\r\n'

    def _without_candidate_sdp(self, lines: list[str]) -> str:
        return '\r\n'.join(
            line for line in lines if not line.startswith('a=candidate:')
        ) + '\r\n'

    async def _wait_for_ice_complete(self, pc):
        if pc.iceGatheringState == 'complete':
            return
        done = asyncio.Event()

        @pc.on('icegatheringstatechange')
        def on_icegatheringstatechange():
            if pc.iceGatheringState == 'complete':
                done.set()

        try:
            await asyncio.wait_for(done.wait(), timeout=10.0)
        except asyncio.TimeoutError:
            logger.warning('WebRTC ICE gathering timed out: state=%s', pc.iceGatheringState)

    async def _close_async(self):
        pc = self._pc
        video_track = self._video_track
        self._pc = None
        self._video_track = None
        self._video_active = False
        self._probe_id = None
        if video_track is not None:
            try:
                video_track.stop()
            except Exception:
                pass
        if pc is not None:
            await pc.close()

    def _log_task_error(self, future):
        try:
            future.result()
        except Exception:
            logger.exception('Direct transport task failed')


try:
    from aiortc import VideoStreamTrack as _AiortcVideoStreamTrack
except Exception:
    _AiortcVideoStreamTrack = object


class _PocketWindowVideoTrack(_AiortcVideoStreamTrack):
    kind = 'video'

    def __init__(self, frame_provider):
        super().__init__()
        self._frame_provider = frame_provider
        self._last_frame = None
        self._frames_sent = 0
        self._last_log_at = 0.0
        self._last_wait_log_at = 0.0

    async def recv(self):
        from av import VideoFrame

        pts, time_base = await self.next_timestamp()
        frame = None
        while frame is None:
            for _ in range(8):
                frame = await asyncio.to_thread(self._frame_provider.capture_webrtc_frame)
                if frame is not None:
                    break
                await asyncio.sleep(0.04)
            if frame is not None:
                break
            if self._last_frame is not None:
                frame = self._last_frame
                break
            now = time.time()
            if now - self._last_wait_log_at >= 2.0:
                self._last_wait_log_at = now
                logger.info('WebRTC video waiting for first real frame')
            await asyncio.sleep(0.10)
        reused = False
        if frame is None:
            frame = self._last_frame
            reused = frame is not None
        self._last_frame = frame
        self._frames_sent += 1
        now = time.time()
        if now - self._last_log_at >= 2.0:
            self._last_log_at = now
            logger.info(
                'WebRTC video frame sent: frames=%s size=%sx%s reused=%s',
                self._frames_sent,
                int(frame.shape[1]) if hasattr(frame, 'shape') and len(frame.shape) >= 2 else 0,
                int(frame.shape[0]) if hasattr(frame, 'shape') and len(frame.shape) >= 2 else 0,
                reused,
            )
        video_frame = VideoFrame.from_ndarray(frame, format='rgb24')
        video_frame.pts = pts
        video_frame.time_base = time_base
        return video_frame
