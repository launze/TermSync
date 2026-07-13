function createRoomChannels({ rooms, safeSendJson, WebSocket }) {
  function ensureChannels(room) {
    if (!room.channels) {
      room.channels = {
        agent: {},
        client: {},
      };
    }
    return room.channels;
  }

  function normalizeChannel(value) {
    const channel = String(value || '').trim().toLowerCase();
    return channel || '';
  }

  function peerConnected(room, role) {
    const channels = ensureChannels(room);
    return !!room[role] || !!channels[role].control || !!channels[role].media;
  }

  function getPeerSocket(room, role, preferredChannel) {
    const channels = ensureChannels(room);
    const channel = normalizeChannel(preferredChannel);
    if (channel && channels[role][channel]) {
      return channels[role][channel];
    }
    if (channel) {
      return null;
    }
    return channels[role].control || channels[role].media || room[role] || null;
  }

  function canReplaceExistingPeer(existingWs, incomingWs, role) {
    if (!existingWs || existingWs === incomingWs) {
      return false;
    }
    if (existingWs.readyState !== WebSocket.OPEN) {
      return true;
    }
    // Allow same-identity reconnections to replace a still-OPEN peer. The TCP
    // half-open state can keep the old socket "OPEN" on the server side long
    // after the client tore it down (frps tunnels, mobile network handoffs,
    // CF reconnects); without this branch the new connection gets rejected
    // with "already connected" forever, which strands the agent and makes
    // every binary frame fall through to "Binary video frame is only
    // accepted from an agent in a room".
    if (role === 'client') {
      const existingClientId = String(existingWs._clientId || '').trim();
      const incomingClientId = String(incomingWs._clientId || '').trim();
      return !!existingClientId && existingClientId === incomingClientId;
    }
    if (role === 'agent') {
      const existingDeviceId = String(existingWs._deviceId || '').trim();
      const incomingDeviceId = String(incomingWs._deviceId || '').trim();
      if (existingDeviceId && incomingDeviceId && existingDeviceId === incomingDeviceId) {
        return true;
      }
    }
    return false;
  }

  function registerPeer(roomId, role, channel, ws) {
    const room = rooms.get(roomId);
    if (!room) return { ok: false, replaced: null };

    const normalizedChannel = normalizeChannel(channel);
    if (!normalizedChannel) {
      const existing = room[role];
      if (existing && existing !== ws && !canReplaceExistingPeer(existing, ws, role)) {
        return { ok: false, reason: `${role} already connected` };
      }
      room[role] = ws;
      room.status = room.agent && room.client ? 'connected' : 'waiting';
      return { ok: true, replaced: existing && existing !== ws ? existing : null };
    }

    const channels = ensureChannels(room);
    const existing = channels[role][normalizedChannel];
    if (existing && existing !== ws && !canReplaceExistingPeer(existing, ws, role)) {
      return { ok: false, reason: `${role} ${normalizedChannel} channel already connected` };
    }
    channels[role][normalizedChannel] = ws;
    room.status = peerConnected(room, 'agent') && peerConnected(room, 'client')
      ? 'connected'
      : 'waiting';
    return { ok: true, replaced: existing && existing !== ws ? existing : null };
  }

  function cleanupPeer(ws) {
    const roomId = ws._roomId;
    const role = ws._role;
    const channel = normalizeChannel(ws._channel);
    if (!roomId || !role) return { room: null, peer: null };

    const room = rooms.get(roomId);
    if (!room) return { room: null, peer: null };

    const channels = ensureChannels(room);
    if (channel) {
      if (channels[role][channel] === ws) {
        channels[role][channel] = null;
      }
    } else if (room[role] === ws) {
      room[role] = null;
    }

    const peerRole = role === 'agent' ? 'client' : 'agent';
    const peer = getPeerSocket(room, peerRole, channel || 'control');
    room.status = peerConnected(room, 'agent') && peerConnected(room, 'client')
      ? 'connected'
      : 'waiting';

    if (!peerConnected(room, 'agent') && !peerConnected(room, 'client')) {
      rooms.delete(roomId);
    }

    return { room, peer };
  }

  function forwardToRoomPeer(roomId, targetRole, payload, preferredChannel) {
    const room = rooms.get(roomId);
    if (!room) return false;
    const target = getPeerSocket(room, targetRole, preferredChannel);
    if (!target) return false;
    safeSendJson(target, payload);
    return true;
  }

  function socketDetail(ws) {
    const socket = ws && ws._socket;
    return {
      ready_state: ws ? ws.readyState : null,
      buffered_amount: ws ? Number(ws.bufferedAmount || 0) : 0,
      socket_writable_length: socket ? Number(socket.writableLength || 0) : null,
      socket_writable_need_drain: socket ? socket.writableNeedDrain === true : null,
      socket_bytes_written: socket ? Number(socket.bytesWritten || 0) : null,
      socket_bytes_read: socket ? Number(socket.bytesRead || 0) : null,
    };
  }

  function forwardBinaryToRoomPeer(roomId, targetRole, payload, preferredChannel, tracePayload) {
    const room = rooms.get(roomId);
    if (!room) return { ok: false };
    const target = getPeerSocket(room, targetRole, preferredChannel);
    if (!target || target.readyState !== WebSocket.OPEN) return { ok: false };
    const bufferedBefore = Number(target.bufferedAmount || 0);
    const sendStart = Date.now();
    const socketBefore = socketDetail(target);
    if (tracePayload && typeof tracePayload === 'object') {
      safeSendJson(target, {
        ...tracePayload,
        server_send_start_ts_ms: sendStart,
        server_client_buffered_before: bufferedBefore,
        server_client_socket_before: socketBefore,
      });
    }
    let sendAccepted = true;
    let sendErrorMessage = '';
    target.send(payload, { binary: true }, (error) => {
      const sendCallbackTs = Date.now();
      const resultPayload = {
        type: 'video_transport_send_result',
        room_id: roomId,
        seq: tracePayload && tracePayload.seq,
        codec: tracePayload && tracePayload.codec,
        server_send_start_ts_ms: sendStart,
        server_send_callback_ts_ms: sendCallbackTs,
        server_send_callback_ms: sendCallbackTs - sendStart,
        server_send_error: error ? String(error.message || error) : '',
        server_client_buffered_after_callback: Number(target.bufferedAmount || 0),
        server_client_socket_after_callback: socketDetail(target),
      };
      if (target.readyState === WebSocket.OPEN) {
        safeSendJson(target, resultPayload);
      }
    });
    const sendReturnTs = Date.now();
    const bufferedAfter = Number(target.bufferedAmount || 0);
    if (target.readyState !== WebSocket.OPEN) {
      sendAccepted = false;
      sendErrorMessage = `target readyState changed to ${target.readyState}`;
    }
    return {
      ok: true,
      target,
      bufferedBefore,
      bufferedAfter,
      sendAccepted,
      sendErrorMessage,
      sendStart,
      sendReturnTs,
      sendCallMs: sendReturnTs - sendStart,
      socketBefore,
      socketAfter: socketDetail(target),
    };
  }

  function hasPeer(roomId, role) {
    const room = rooms.get(roomId);
    return !!room && peerConnected(room, role);
  }

  function activeRoomCount() {
    return Array.from(rooms.values()).filter(
      (room) => peerConnected(room, 'agent') && peerConnected(room, 'client'),
    ).length;
  }

  return {
    activeRoomCount,
    cleanupPeer,
    forwardBinaryToRoomPeer,
    forwardToRoomPeer,
    getPeerSocket,
    hasPeer,
    normalizeChannel,
    registerPeer,
  };
}

module.exports = { createRoomChannels };
