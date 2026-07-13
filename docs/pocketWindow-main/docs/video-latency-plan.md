# Video Latency Plan

## Current Finding

The main delay is not in desktop control handling, server JavaScript forwarding, or Android native decoding. Logs show large spikes between server send and Android WebSocket receipt. This behaves like TCP/WebSocket buffering or mobile network stack batching.

## Layer 1 Plan

1. Switch to H264 immediately while finger scrolling is active.
2. Restore H265 only after scrolling has been idle for a short delay.
3. Add video frame ACK/status from Android to the desktop agent.
4. Use ACK delay, WebSocket gaps, and burst count as congestion signals.
5. Slow desktop video sending during congestion so old frames do not enter the TCP/WebSocket queue.
6. Keep Android's existing decode-side stale-frame dropping.
7. If congestion is still severe, rebuild the media WebSocket to clear already queued TCP data.

## Later Options

If WebSocket low-latency mode is still not enough, evaluate UDP-like media transport such as QUIC/WebTransport/RTP. That path is more complex because deployment and port constraints are stricter.
