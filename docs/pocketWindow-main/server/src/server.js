/*
 * PocketWindow Signaling Server
 * Secure pairing + authorized remote control
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { createFileTransferStore } = require('./file_transfer_store');
const { createReleaseStore } = require('./release_store');
const { createRoomChannels } = require('./room_channels');

const app = express();
const server = http.createServer(app);

// { roomId: { agent: ws|null, client: ws|null, createdAt, status } }
const rooms = new Map();
// { deviceId: { roomId, pairCode, pairingToken, deviceName, hostName, localIp, localIps, lanProbePort, platform, selectedWindowTitle, connectedAt, lastSeenAt, ws } }
const agentsByDeviceId = new Map();
// { clientId: { clientId, clientName, linkedAt, lastSeenAt } }
const clients = new Map();
// { deviceId: Set<clientId> }
const trustedClientsByDevice = new Map();
// { requestId: { requestId, deviceId, clientId, clientName, createdAt, status } }
const pairRequests = new Map();

const DATA_DIR = path.join(__dirname, '..', 'data');
const STATE_FILE = path.join(DATA_DIR, 'server-state.json');
const FILE_TRANSFER_DIR = path.join(DATA_DIR, 'file-transfers');
const RELEASES_DIR = path.join(DATA_DIR, 'releases');
const DIAGNOSTICS_DIR = path.join(DATA_DIR, 'diagnostics');
const RELEASES_STATE_FILE = path.join(DATA_DIR, 'releases.json');
const MAX_TRANSFER_SIZE = 1024 * 1024 * 1024;
const FILE_TRANSFER_TTL_MS = 10 * 60 * 1000;
const MAX_RELEASE_SIZE = 2 * 1024 * 1024 * 1024;
let fileTransferStore;
let releaseStore;
let releasesByPlatform;
let roomChannels;

app.use(express.json());

app.get('/download.apk', (req, res) => {
  const release = releasesByPlatform.get('android');
  if (!release) {
    return res.status(404).json({ error: 'Android release not found' });
  }
  const apkPath = releaseFilePath(release.fileToken, release.fileName);
  if (!fs.existsSync(apkPath)) {
    return res.status(404).json({ error: 'Android release file missing' });
  }
  const downloadName = `PocketWindow-v${release.version}-build${release.build}.apk`;
  return res.download(apkPath, downloadName);
});

function parseIceServers() {
  const raw = String(process.env.ICE_SERVERS_JSON || '').trim();
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        return parsed.filter((item) => item && (typeof item.urls === 'string' || Array.isArray(item.urls)));
      }
    } catch (error) {
      console.warn('Invalid ICE_SERVERS_JSON:', error.message);
    }
  }
  const turnUrl = String(process.env.TURN_URL || '').trim();
  const turnUsername = String(process.env.TURN_USERNAME || '').trim();
  const turnCredential = String(process.env.TURN_CREDENTIAL || '').trim();
  const servers = [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
  ];
  if (turnUrl && turnUsername && turnCredential) {
    servers.push({
      urls: turnUrl.includes(',') ? turnUrl.split(',').map((item) => item.trim()).filter(Boolean) : turnUrl,
      username: turnUsername,
      credential: turnCredential,
    });
  }
  return servers;
}

function ensureDataDir() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.mkdirSync(FILE_TRANSFER_DIR, { recursive: true });
  fs.mkdirSync(RELEASES_DIR, { recursive: true });
  fs.mkdirSync(DIAGNOSTICS_DIR, { recursive: true });
}

function serializeState() {
  return {
    agents: Array.from(agentsByDeviceId.values()).map((agent) => ({
      deviceId: agent.deviceId,
      roomId: agent.roomId,
      pairCode: agent.pairCode,
      pairingToken: agent.pairingToken,
      deviceName: agent.deviceName,
      hostName: agent.hostName,
      localIp: agent.localIp,
      localIps: Array.isArray(agent.localIps) ? agent.localIps : [],
      lanProbePort: Number(agent.lanProbePort || 0) || 0,
      lanDirectPort: Number(agent.lanDirectPort || 0) || 0,
      platform: agent.platform,
      selectedWindowTitle: agent.selectedWindowTitle,
      connectedAt: agent.connectedAt,
      lastSeenAt: agent.lastSeenAt,
    })),
    clients: Array.from(clients.values()).map((client) => ({
      clientId: client.clientId,
      clientName: client.clientName,
      linkedAt: client.linkedAt,
      lastSeenAt: client.lastSeenAt,
    })),
    trustedClientsByDevice: Array.from(trustedClientsByDevice.entries()).map(([deviceId, clientIds]) => ({
      deviceId,
      clientIds: Array.from(clientIds),
    })),
  };
}

function persistState() {
  try {
    ensureDataDir();
    fs.writeFileSync(STATE_FILE, JSON.stringify(serializeState(), null, 2), 'utf8');
  } catch (error) {
    console.error('[STATE] Persist failed:', error && error.message ? error.message : String(error));
  }
}

function serializeReleases() {
  return releaseStore.serialize();
}

function persistReleases() {
  releaseStore.persist();
}

function loadPersistedState() {
  try {
    ensureDataDir();
    if (!fs.existsSync(STATE_FILE)) {
      return;
    }
    const raw = fs.readFileSync(STATE_FILE, 'utf8');
    if (!raw.trim()) {
      return;
    }
    const parsed = JSON.parse(raw);
    const agents = Array.isArray(parsed?.agents) ? parsed.agents : [];
    const restoredClients = Array.isArray(parsed?.clients) ? parsed.clients : [];
    const trustedEntries = Array.isArray(parsed?.trustedClientsByDevice)
      ? parsed.trustedClientsByDevice
      : [];

    for (const item of agents) {
      const deviceId = String(item?.deviceId || '').trim();
      if (!deviceId) continue;
      const localIp = String(item?.localIp || '').trim();
      agentsByDeviceId.set(deviceId, {
        deviceId,
        roomId: String(item?.roomId || '').trim(),
        pairCode: String(item?.pairCode || '').trim() || generatePairCode(),
        pairingToken: String(item?.pairingToken || '').trim() || crypto.randomUUID(),
        deviceName: String(item?.deviceName || '').trim(),
        hostName: String(item?.hostName || '').trim(),
        localIp,
        localIps: normalizeAgentLocalIps(
          localIp,
          Array.isArray(item?.localIps)
            ? item.localIps.map((value) => String(value || '').trim()).filter(Boolean)
            : []
        ),
        lanProbePort: Number(item?.lanProbePort || 0) || 0,
        lanDirectPort: Number(item?.lanDirectPort || 0) || 0,
        platform: String(item?.platform || '').trim(),
        selectedWindowTitle: String(item?.selectedWindowTitle || '').trim(),
        connectedAt: Number(item?.connectedAt || 0) || Date.now(),
        lastSeenAt: Number(item?.lastSeenAt || 0) || 0,
        ws: null,
      });
    }

    for (const item of restoredClients) {
      const clientId = String(item?.clientId || '').trim();
      if (!clientId) continue;
      clients.set(clientId, {
        clientId,
        clientName: String(item?.clientName || '').trim(),
        linkedAt: Number(item?.linkedAt || 0) || Date.now(),
        lastSeenAt: Number(item?.lastSeenAt || 0) || 0,
      });
    }

    for (const entry of trustedEntries) {
      const deviceId = String(entry?.deviceId || '').trim();
      if (!deviceId) continue;
      const set = trustedSetForDevice(deviceId);
      const clientIds = Array.isArray(entry?.clientIds) ? entry.clientIds : [];
      for (const clientIdValue of clientIds) {
        const clientId = String(clientIdValue || '').trim();
        if (clientId) {
          set.add(clientId);
        }
      }
    }
  } catch (error) {
    console.error('[STATE] Load failed:', error && error.message ? error.message : String(error));
  }
}

function loadPersistedReleases() {
  releaseStore.load();
}

function generateRoomId() {
  return `pw-${crypto.randomBytes(8).toString('hex')}`;
}

function generatePairCode() {
  return `${Math.floor(100000 + Math.random() * 900000)}`;
}

function generateRequestId() {
  return `pair-${crypto.randomBytes(10).toString('hex')}`;
}

function safeSendJson(ws, payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(payload));
}

function isPocketWindowVideoFrameBinary(data) {
  const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data || []);
  return buffer.length >= 4 && buffer.subarray(0, 4).toString('ascii') === 'PWVF';
}

function parsePocketWindowVideoFrameHeader(data) {
  const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data || []);
  if (buffer.length < 30 || buffer.subarray(0, 4).toString('ascii') !== 'PWVF') {
    return null;
  }
  const codecId = buffer.readUInt8(5);
  const profileLength = buffer.readUInt16BE(28);
  const payloadOffset = 30 + profileLength;
  return {
    version: buffer.readUInt8(4),
    codec: codecId === 2 ? 'h265' : 'h264',
    seq: buffer.readUInt32BE(8),
    desktopSentAtMs: Number(buffer.readBigUInt64BE(12)),
    width: buffer.readUInt32BE(20),
    height: buffer.readUInt32BE(24),
    payloadBytes: Math.max(0, buffer.length - payloadOffset),
    totalBytes: buffer.length,
  };
}

function handleBinaryMessage(ws, data) {
  if (!isPocketWindowVideoFrameBinary(data)) {
    safeSendJson(ws, { type: 'error', message: 'Invalid binary message' });
    return;
  }
  const roomId = String(ws._roomId || '').trim();
  if (!roomId || ws._role !== 'agent') {
    safeSendJson(ws, { type: 'error', message: 'Binary video frame is only accepted from an agent in a room' });
    return;
  }
  const serverRecvTsMs = Date.now();
  const payload = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const header = parsePocketWindowVideoFrameHeader(payload);
  let tracePayload = header
    ? {
        type: 'video_transport_trace',
        room_id: roomId,
        seq: header.seq,
        codec: header.codec,
        desktop_sent_at_ms: header.desktopSentAtMs,
        server_recv_ts_ms: serverRecvTsMs,
        server_forward_ts_ms: Date.now(),
        server_payload_bytes: header.payloadBytes,
        server_frame_bytes: header.totalBytes,
        server_client_buffered_before: 0,
        server_client_channel: 'media',
      }
    : null;
  const agentChannel = ws._channel || 'media';
  let forwardResult = roomChannels.forwardBinaryToRoomPeer(
    roomId,
    'client',
    payload,
    agentChannel,
    tracePayload,
  );
  if (!forwardResult.ok) {
    if (agentChannel !== 'media') {
      tracePayload = tracePayload ? { ...tracePayload, server_client_channel: 'media' } : null;
      forwardResult = roomChannels.forwardBinaryToRoomPeer(
        roomId,
        'client',
        payload,
        'media',
        tracePayload,
      );
    }
    if (!forwardResult.ok) {
      const controlTracePayload = tracePayload
        ? { ...tracePayload, server_client_channel: 'control' }
        : null;
      forwardResult = roomChannels.forwardBinaryToRoomPeer(
        roomId,
        'client',
        payload,
        'control',
        controlTracePayload,
      );
    }
  }
  if (!forwardResult.ok) {
    safeSendJson(ws, { type: 'error', message: 'Client not connected' });
  } else if (tracePayload) {
    tracePayload.server_send_call_ms = forwardResult.sendCallMs;
    tracePayload.server_send_return_ts_ms = forwardResult.sendReturnTs;
    tracePayload.server_client_buffered_after_send = forwardResult.bufferedAfter;
    tracePayload.server_client_socket_after_send = forwardResult.socketAfter;
  }
}

function getOrCreateRoom(roomId) {
  let room = rooms.get(roomId);
  if (!room) {
    room = {
      agent: null,
      client: null,
      channels: {
        agent: {},
        client: {},
      },
      createdAt: Date.now(),
      status: 'waiting',
    };
    rooms.set(roomId, room);
  }
  return room;
}

function trustedSetForDevice(deviceId) {
  let trusted = trustedClientsByDevice.get(deviceId);
  if (!trusted) {
    trusted = new Set();
    trustedClientsByDevice.set(deviceId, trusted);
  }
  return trusted;
}

function normalizeAgentLocalIps(localIp, localIps) {
  const results = [];
  const add = (value) => {
    const normalized = String(value || '').trim();
    if (!normalized || results.includes(normalized)) {
      return;
    }
    results.push(normalized);
  };

  add(localIp);
  if (Array.isArray(localIps)) {
    for (const item of localIps) {
      add(item);
    }
  }
  return results;
}

function normalizeReleasePlatform(value) {
  return releaseStore.normalizeReleasePlatform(value);
}

function normalizeChannel(value) {
  return releaseStore.normalizeChannel(value);
}

function parsePositiveInt(value) {
  return releaseStore.parsePositiveInt(value);
}

function normalizeVersionParts(version) {
  return String(version || '')
    .trim()
    .split(/[.+-]/)
    .map((part) => Number.parseInt(part, 10))
    .map((part) => (Number.isFinite(part) ? part : 0));
}

function compareVersions(left, right) {
  const leftParts = normalizeVersionParts(left);
  const rightParts = normalizeVersionParts(right);
  const maxLength = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < maxLength; index += 1) {
    const leftValue = leftParts[index] || 0;
    const rightValue = rightParts[index] || 0;
    if (leftValue > rightValue) return 1;
    if (leftValue < rightValue) return -1;
  }
  return 0;
}

function sanitizeReleaseRecord(input, platform) {
  return releaseStore.sanitizeReleaseRecord(input, platform);
}

function releaseFilePath(fileToken, fileName) {
  return releaseStore.releaseFilePath(fileToken, fileName);
}

function sanitizeReleaseForClient(release, req) {
  return releaseStore.sanitizeReleaseForClient(release, req);
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatFileSize(bytes) {
  const value = parsePositiveInt(bytes);
  if (value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  const decimals = size >= 10 || unitIndex === 0 ? 0 : 1;
  return `${size.toFixed(decimals)} ${units[unitIndex]}`;
}

function formatReleaseTime(timestamp) {
  const value = parsePositiveInt(timestamp);
  if (!value) return '-';
  try {
    return new Date(value).toLocaleString('zh-CN', { hour12: false });
  } catch (_) {
    return String(value);
  }
}

function renderReleaseAdminPage(req, message = '') {
  const rows = Array.from(releasesByPlatform.values())
    .sort((left, right) => String(left.platform).localeCompare(String(right.platform)))
    .map((release) => {
      const clientRelease = sanitizeReleaseForClient(release, req);
      return `
        <tr>
          <td>${escapeHtml(release.platform)}</td>
          <td>${escapeHtml(release.version)}</td>
          <td>${escapeHtml(release.channel)}</td>
          <td>${escapeHtml(release.fileName)}</td>
          <td>${escapeHtml(String(release.fileSize))}</td>
          <td><a href="${escapeHtml(clientRelease?.download_url || '#')}">下载</a></td>
        </tr>
      `;
    })
    .join('');

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PocketWindow 更新中心</title>
  <style>
    body { font-family: "Microsoft YaHei UI", sans-serif; margin: 24px; background: #f6f8fb; color: #1f2937; }
    .card { background: #fff; border: 1px solid #dbe3ef; border-radius: 14px; padding: 20px; margin-bottom: 18px; }
    h1, h2 { margin-top: 0; }
    label { display: block; margin-top: 12px; font-weight: 600; }
    input, select, textarea { width: 100%; box-sizing: border-box; margin-top: 6px; padding: 10px 12px; border: 1px solid #c9d5e5; border-radius: 10px; font: inherit; }
    textarea { min-height: 120px; resize: vertical; }
    button { margin-top: 16px; border: 0; background: #2457f5; color: #fff; border-radius: 10px; padding: 10px 16px; font: inherit; cursor: pointer; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid #e5ebf3; }
    .msg { padding: 12px; background: #e8f1ff; border: 1px solid #b8d0ff; border-radius: 10px; margin-bottom: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>PocketWindow 更新中心</h1>
    ${message ? `<div class="msg">${escapeHtml(message)}</div>` : ''}
    <form action="/admin/releases/upload" method="post" enctype="application/octet-stream">
      <label>平台
        <select name="platform">
          <option value="android">android</option>
          <option value="windows">windows</option>
        </select>
      </label>
      <label>版本号
        <input type="text" name="version" placeholder="例如 1.1.0" required />
      </label>
      <label>构建号
        <input type="number" name="build" value="1" min="1" />
      </label>
      <label>渠道
        <input type="text" name="channel" value="stable" />
      </label>
      <label>标题
        <input type="text" name="title" placeholder="例如 1.1.0 更新" />
      </label>
      <label>最小支持版本
        <input type="text" name="min_supported_version" placeholder="留空表示不限制" />
      </label>
      <label>强制更新
        <select name="force_update">
          <option value="false">false</option>
          <option value="true">true</option>
        </select>
      </label>
      <label>文件名
        <input type="text" name="file_name" placeholder="例如 app-release.apk / PocketWindowAgent-win64.zip" required />
      </label>
      <label>SHA256
        <input type="text" name="sha256" placeholder="可选" />
      </label>
      <label>更新说明
        <textarea name="notes" placeholder="这次更新了什么"></textarea>
      </label>
      <label>上传方式
        <input type="text" value="请用 curl / Postman / 客户端调用同地址并以二进制 body 上传文件；这个表单主要展示字段" readonly />
      </label>
    </form>
  </div>
  <div class="card">
    <h2>当前版本</h2>
    <table>
      <thead>
        <tr><th>平台</th><th>版本</th><th>渠道</th><th>文件</th><th>大小</th><th>下载</th></tr>
      </thead>
      <tbody>${rows || '<tr><td colspan="6">暂无发布</td></tr>'}</tbody>
    </table>
  </div>
</body>
</html>`;
}

function isAgentOnline(agent, now = Date.now()) {
  return !!(agent && agent.ws && now - Number(agent.lastSeenAt || 0) < 30000);
}

function sanitizeAgent(agent) {
  const localIps = normalizeAgentLocalIps(agent.localIp, agent.localIps);
  return {
    deviceId: agent.deviceId,
    roomId: agent.roomId,
    pairCode: agent.pairCode,
    deviceName: agent.deviceName,
    hostName: agent.hostName,
    localIp: agent.localIp,
    localIps,
    lanProbePort: Number(agent.lanProbePort || 0) || 0,
    lanDirectPort: Number(agent.lanDirectPort || 0) || 0,
    platform: agent.platform,
    selectedWindowTitle: agent.selectedWindowTitle,
    connectedAt: agent.connectedAt,
    lastSeenAt: agent.lastSeenAt,
    online: isAgentOnline(agent),
    trustedClientCount: trustedSetForDevice(agent.deviceId).size,
  };
}

function upsertAgent(roomId, metadata = {}, selectedWindowTitle) {
  const existingRoom = rooms.get(roomId);
  const existingAgentDeviceId = existingRoom?.agent?._deviceId ||
    existingRoom?.channels?.agent?.control?._deviceId ||
    existingRoom?.channels?.agent?.media?._deviceId ||
    '';
  const deviceId = String(metadata.device_id || existingAgentDeviceId || '').trim();
  if (!deviceId) {
    return null;
  }

  const previous = agentsByDeviceId.get(deviceId) || {};
  const localIp = String(metadata.local_ip || previous.localIp || '').trim();
  const localIps = normalizeAgentLocalIps(
    localIp,
    Array.isArray(metadata.local_ips)
      ? metadata.local_ips.map((value) => String(value || '').trim()).filter(Boolean)
      : Array.isArray(previous.localIps) ? previous.localIps : []
  );
  const agent = {
    deviceId,
    roomId,
    pairCode: previous.pairCode || generatePairCode(),
    pairingToken: previous.pairingToken || crypto.randomUUID(),
    deviceName: metadata.device_name || previous.deviceName || '',
    hostName: metadata.host_name || previous.hostName || '',
    localIp,
    localIps,
    lanProbePort: Number(metadata.lan_probe_port || previous.lanProbePort || 0) || 0,
    lanDirectPort: Number(metadata.lan_direct_port || previous.lanDirectPort || 0) || 0,
    platform: metadata.platform || previous.platform || '',
    selectedWindowTitle:
      selectedWindowTitle || metadata.selected_window_title || previous.selectedWindowTitle || '',
    connectedAt: previous.connectedAt || Date.now(),
    lastSeenAt: Date.now(),
    ws: previous.ws || null,
  };

  agentsByDeviceId.set(deviceId, agent);
  persistState();
  return agent;
}

function updateAgentSocket(deviceId, ws) {
  const agent = agentsByDeviceId.get(deviceId);
  if (!agent) return;
  agent.ws = ws;
  agent.lastSeenAt = Date.now();
  persistState();
}

function cleanupWs(ws, reason) {
  const roomId = ws._roomId;
  const role = ws._role;
  const deviceId = ws._deviceId;
  const channel = roomChannels?.normalizeChannel(ws._channel) || '';

  if (deviceId && (!channel || channel === 'control')) {
    const agent = agentsByDeviceId.get(deviceId);
    if (agent && agent.ws === ws) {
      agent.ws = null;
      persistState();
    }
  }

  if (!roomId || !role) return;
  const { peer } = roomChannels.cleanupPeer(ws);

  if (peer) {
    safeSendJson(peer, {
      type: 'remote_disconnected',
      role,
      reason: reason || 'disconnected',
      channel,
      client_id: role === 'client' ? String(ws._clientId || '').trim() : String(peer._clientId || '').trim(),
    });
  }
}

function forwardToRoomPeer(roomId, targetRole, payload) {
  return roomChannels.forwardToRoomPeer(roomId, targetRole, payload);
}

function canReplaceExistingPeer(existingWs, incomingWs, role) {
  if (!existingWs || existingWs === incomingWs) {
    return false;
  }

  if (existingWs.readyState !== WebSocket.OPEN) {
    return true;
  }

  if (role === 'client') {
    const existingClientId = String(existingWs._clientId || '').trim();
    const incomingClientId = String(incomingWs._clientId || '').trim();
    return !!existingClientId && existingClientId === incomingClientId;
  }

  return false;
}

function isClientTrusted(deviceId, clientId) {
  if (!deviceId || !clientId) return false;
  return trustedSetForDevice(deviceId).has(clientId);
}

function safeFilename(name) {
  const normalized = String(name || '').trim().replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
  return normalized || 'download.bin';
}

function initReleaseStore() {
  releaseStore = createReleaseStore({
    releasesDir: RELEASES_DIR,
    stateFile: RELEASES_STATE_FILE,
    ensureDataDir,
    safeFilename,
  });
  releasesByPlatform = releaseStore.releasesByPlatform;
}

function createTransferToken() {
  return fileTransferStore.createToken();
}

function cleanupExpiredTransfers(now = Date.now()) {
  fileTransferStore.cleanupExpired(now);
}

function requireTrustedTransfer(req, res) {
  return fileTransferStore.requireTrusted(req, res);
}

function initFileTransferStore() {
  fileTransferStore = createFileTransferStore({
    transferDir: FILE_TRANSFER_DIR,
    ttlMs: FILE_TRANSFER_TTL_MS,
    isClientTrusted,
  });
}

app.get('/api/health', (req, res) => {
  const activeRooms = roomChannels.activeRoomCount();
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    activeRooms,
    onlineAgents: Array.from(agentsByDeviceId.values()).filter((agent) => agent.ws).length,
  });
});

app.get('/api/network-info', (req, res) => {
  const remoteAddress = String(
    req.headers['x-forwarded-for']?.toString().split(',')[0] ||
      req.socket?.remoteAddress ||
      ''
  ).trim();

  res.type('text/plain').send(remoteAddress.replace(/^::ffff:/, ''));
});

app.get('/api/ice-servers', (req, res) => {
  res.json({ iceServers: parseIceServers() });
});

app.get('/api/releases/latest', (req, res) => {
  const platform = normalizeReleasePlatform(req.query.platform);
  if (!platform) {
    return res.status(400).json({ message: 'platform is required: android/windows' });
  }
  const release = releasesByPlatform.get(platform);
  if (!release) {
    return res.status(404).json({ message: 'No release published for this platform' });
  }
  return res.json({
    release: sanitizeReleaseForClient(release, req),
  });
});

app.get('/api/releases/download/:platform/:token', (req, res) => {
  const platform = normalizeReleasePlatform(req.params.platform);
  const token = String(req.params.token || '').trim();
  const release = releasesByPlatform.get(platform);
  if (!platform || !release || release.fileToken !== token) {
    return res.status(404).json({ message: 'Release not found' });
  }
  const filePath = releaseFilePath(release.fileToken, release.fileName);
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ message: 'Release file missing' });
  }

  res.setHeader('Content-Type', release.mimeType || 'application/octet-stream');
  res.setHeader(
    'Content-Disposition',
    `attachment; filename="${encodeURIComponent(release.fileName).replace(/%20/g, ' ')}"`
  );
  res.setHeader('Content-Length', String(release.fileSize));
  if (release.sha256) {
    res.setHeader('X-PocketWindow-Sha256', release.sha256);
  }

  const stream = fs.createReadStream(filePath);
  stream.on('error', (error) => {
    if (!res.headersSent) {
      res.status(500).json({ message: error && error.message ? error.message : 'Read failed' });
    } else {
      res.destroy(error);
    }
  });
  stream.pipe(res);
});

function renderReleaseAdminPage(req, message = '') {
  const origin = `${req.protocol}://${req.get('host')}`;
  const uploadUrl = `${origin}/admin/releases/upload`;
  const rows = Array.from(releasesByPlatform.values())
    .sort((left, right) => String(left.platform).localeCompare(String(right.platform)))
    .map((release) => {
      const clientRelease = sanitizeReleaseForClient(release, req);
      return `
        <tr>
          <td>${escapeHtml(release.platform)}</td>
          <td>${escapeHtml(release.version)}</td>
          <td>${escapeHtml(String(release.build || 0))}</td>
          <td>${escapeHtml(release.channel)}</td>
          <td>${escapeHtml(release.fileName)}</td>
          <td>${escapeHtml(formatFileSize(release.fileSize))}</td>
          <td>${escapeHtml(formatReleaseTime(release.createdAt))}</td>
          <td><a href="${escapeHtml(clientRelease?.download_url || '#')}">下载</a></td>
        </tr>
      `;
    })
    .join('');

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PocketWindow 更新中心</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f3f6fb;
      --card: #ffffff;
      --line: #d7dfec;
      --line-soft: #e8edf6;
      --text: #1f2937;
      --muted: #5b6472;
      --accent: #2457f5;
      --accent-soft: #e8efff;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: "Microsoft YaHei UI", sans-serif; background: linear-gradient(180deg, #eef4ff 0%, var(--bg) 220px); color: var(--text); }
    .page { max-width: 1120px; margin: 0 auto; padding: 28px 20px 40px; }
    .hero { margin-bottom: 18px; }
    .hero h1 { margin: 0 0 10px; font-size: 30px; }
    .hero p { margin: 0; color: var(--muted); line-height: 1.6; }
    .layout { display: grid; grid-template-columns: minmax(340px, 420px) minmax(0, 1fr); gap: 18px; align-items: start; }
    .card { background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 20px; box-shadow: 0 16px 40px rgba(36, 87, 245, 0.08); }
    h2, h3 { margin-top: 0; }
    label { display: block; margin-top: 12px; font-weight: 600; }
    input, select, textarea { width: 100%; margin-top: 6px; padding: 10px 12px; border: 1px solid #c9d5e5; border-radius: 10px; font: inherit; background: #fff; }
    textarea { min-height: 120px; resize: vertical; }
    input[type="file"] { padding: 8px; }
    button { margin-top: 16px; border: 0; background: var(--accent); color: #fff; border-radius: 10px; padding: 11px 16px; font: inherit; cursor: pointer; font-weight: 600; }
    button:disabled { opacity: 0.65; cursor: wait; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid #e5ebf3; }
    th { color: var(--muted); font-weight: 600; font-size: 13px; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .msg { padding: 12px; background: #e8f1ff; border: 1px solid #b8d0ff; border-radius: 10px; margin-bottom: 16px; }
    .tip { margin-top: 14px; padding: 12px; border-radius: 12px; background: #f8fafc; border: 1px solid var(--line-soft); color: var(--muted); line-height: 1.6; }
    .result { margin-top: 16px; padding: 12px; min-height: 78px; border-radius: 12px; background: #0f172a; color: #e2e8f0; font: 13px/1.5 Consolas, monospace; white-space: pre-wrap; word-break: break-word; }
    .result.success { outline: 2px solid rgba(15, 118, 110, 0.18); }
    .result.error { outline: 2px solid rgba(180, 35, 24, 0.18); }
    .meta { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
    .meta label { margin-top: 0; }
    code { font-family: Consolas, monospace; background: #f5f7fb; padding: 2px 6px; border-radius: 6px; }
    @media (max-width: 920px) {
      .layout { grid-template-columns: 1fr; }
      .meta { grid-template-columns: 1fr; }
      .page { padding-inline: 14px; }
    }
  </style>
</head>
<body>
  <div class="page">
    <div class="hero">
      <h1>PocketWindow 更新中心</h1>
      <p>这里同时支持浏览器上传和终端直传。上传后，手机端和电脑端会通过 <code>/api/releases/latest</code> 自动检测新版本。</p>
    </div>
    ${message ? `<div class="msg">${escapeHtml(message)}</div>` : ''}
    <div class="layout">
      <div class="card">
        <h2>发布新版本</h2>
        <form id="releaseForm">
          <label>平台
            <select name="platform">
              <option value="android">android</option>
              <option value="windows">windows</option>
            </select>
          </label>
          <div class="meta">
            <label>版本号
              <input type="text" name="version" placeholder="例如 1.1.0" required />
            </label>
            <label>构建号
              <input type="number" name="build" value="1" min="1" />
            </label>
          </div>
          <div class="meta">
            <label>渠道
              <input type="text" name="channel" value="stable" />
            </label>
            <label>最小支持版本
              <input type="text" name="min_supported_version" placeholder="留空表示不限制" />
            </label>
          </div>
          <label>标题
            <input type="text" name="title" placeholder="例如 1.1.0 更新" />
          </label>
          <label>强制更新
            <select name="force_update">
              <option value="false">false</option>
              <option value="true">true</option>
            </select>
          </label>
          <label>更新包
            <input type="file" name="release_file" required />
          </label>
          <label>文件名
            <input type="text" name="file_name" placeholder="默认取所选文件名" />
          </label>
          <label>SHA256
            <input type="text" name="sha256" placeholder="可留空，由服务端自动计算" />
          </label>
          <label>更新说明
            <textarea name="notes" placeholder="这次更新了什么"></textarea>
          </label>
          <button id="submitButton" type="submit">上传并发布</button>
        </form>
        <div class="tip">
          终端直传地址：<code>${escapeHtml(uploadUrl)}</code><br />
          支持原始二进制请求体，元数据通过 query 或 <code>X-*</code> 请求头传递。
        </div>
        <pre id="resultBox" class="result">等待上传...</pre>
      </div>
      <div class="card">
        <h2>当前版本</h2>
        <table>
          <thead>
            <tr><th>平台</th><th>版本</th><th>构建</th><th>渠道</th><th>文件</th><th>大小</th><th>发布时间</th><th>下载</th></tr>
          </thead>
          <tbody>${rows || '<tr><td colspan="8">暂无发布</td></tr>'}</tbody>
        </table>
        <div class="tip">
          <h3>CLI 示例</h3>
          <div><code>python server/tools/upload_release.py --server ${escapeHtml(origin)} --platform android --version 1.1.0 --build 2 --file app-release.apk</code></div>
          <div style="margin-top:8px;"><code>curl --data-binary "@app-release.apk" "${escapeHtml(uploadUrl)}?platform=android&amp;version=1.1.0&amp;build=2&amp;file_name=app-release.apk"</code></div>
        </div>
      </div>
    </div>
  </div>
  <script>
    (function () {
      const form = document.getElementById('releaseForm');
      const submitButton = document.getElementById('submitButton');
      const resultBox = document.getElementById('resultBox');
      const fileInput = form.querySelector('input[name="release_file"]');
      const fileNameInput = form.querySelector('input[name="file_name"]');

      fileInput.addEventListener('change', function () {
        if (!fileNameInput.value.trim() && fileInput.files && fileInput.files[0]) {
          fileNameInput.value = fileInput.files[0].name;
        }
      });

      function setResult(type, value) {
        resultBox.className = 'result ' + (type || '');
        resultBox.textContent = value;
      }

      form.addEventListener('submit', async function (event) {
        event.preventDefault();
        const file = fileInput.files && fileInput.files[0];
        if (!file) {
          setResult('error', '请选择要上传的文件。');
          return;
        }

        const formData = new FormData(form);
        const params = new URLSearchParams();
        ['platform', 'version', 'build', 'channel', 'title', 'notes', 'file_name', 'sha256', 'min_supported_version', 'force_update'].forEach(function (key) {
          const rawValue = formData.get(key);
          const value = rawValue == null ? '' : String(rawValue).trim();
          if (value) {
            params.set(key, value);
          }
        });
        if (!params.get('file_name')) {
          params.set('file_name', file.name);
        }
        if (!params.get('title')) {
          params.set('title', params.get('platform') + ' ' + params.get('version'));
        }

        submitButton.disabled = true;
        setResult('', '正在上传 ' + file.name + ' ...');

        try {
          const response = await fetch('/admin/releases/upload?' + params.toString(), {
            method: 'POST',
            headers: {
              'Content-Type': file.type || 'application/octet-stream'
            },
            body: file
          });
          const rawText = await response.text();
          let payload = rawText;
          try {
            payload = JSON.stringify(JSON.parse(rawText), null, 2);
          } catch (_) {}
          if (!response.ok) {
            throw new Error(payload);
          }
          setResult('success', payload);
          window.setTimeout(function () {
            window.location.reload();
          }, 900);
        } catch (error) {
          setResult('error', error && error.message ? error.message : String(error));
        } finally {
          submitButton.disabled = false;
        }
      });
    })();
  </script>
</body>
</html>`;
}

app.get('/admin/releases', (req, res) => {
  res.type('html').send(renderReleaseAdminPage(req));
});

app.post(
  '/admin/releases/upload',
  express.raw({ type: '*/*', limit: `${MAX_RELEASE_SIZE}` }),
  (req, res) => {
    const platform = normalizeReleasePlatform(req.query.platform || req.headers['x-platform']);
    const version = String(req.query.version || req.headers['x-version'] || '').trim();
    const build = parsePositiveInt(req.query.build || req.headers['x-build']) || 1;
    const channel = normalizeChannel(req.query.channel || req.headers['x-channel']);
    const title = String(req.query.title || req.headers['x-title'] || '').trim();
    const notes = String(req.query.notes || req.headers['x-notes'] || '').trim();
    const fileName = safeFilename(req.query.file_name || req.headers['x-file-name'] || '');
    const sha256 = String(req.query.sha256 || req.headers['x-sha256'] || '').trim().toLowerCase();
    const minSupportedVersion = String(
      req.query.min_supported_version || req.headers['x-min-supported-version'] || ''
    ).trim();
    const forceUpdate =
      String(req.query.force_update || req.headers['x-force-update'] || '').trim().toLowerCase() === 'true';
    const body = req.body;

    if (!platform || !version || !fileName) {
      return res.status(400).json({ message: 'platform, version and file_name are required' });
    }
    if (!Buffer.isBuffer(body) || body.length <= 0) {
      return res.status(400).json({ message: 'Missing release file body' });
    }
    if (body.length > MAX_RELEASE_SIZE) {
      return res.status(413).json({ message: 'Release file too large' });
    }

    const fileToken = crypto.randomBytes(24).toString('hex');
    const filePath = releaseFilePath(fileToken, fileName);
    const mimeType = String(req.headers['content-type'] || 'application/octet-stream').trim();
    const actualSha256 = crypto.createHash('sha256').update(body).digest('hex').toLowerCase();
    if (sha256 && sha256 !== actualSha256) {
      return res.status(400).json({ message: 'sha256 mismatch' });
    }
    const release = {
      platform,
      version,
      build,
      channel,
      title,
      notes,
      fileName,
      fileToken,
      fileSize: body.length,
      sha256: actualSha256,
      mimeType,
      forceUpdate,
      minSupportedVersion,
      createdAt: Date.now(),
    };

    const previous = releasesByPlatform.get(platform);
    try {
      fs.writeFileSync(filePath, body);
      releasesByPlatform.set(platform, release);
      persistReleases();
      if (previous) {
        const previousPath = releaseFilePath(previous.fileToken, previous.fileName);
        if (fs.existsSync(previousPath)) {
          fs.unlinkSync(previousPath);
        }
      }
      return res.json({
        message: 'Release uploaded',
        release: sanitizeReleaseForClient(release, req),
      });
    } catch (error) {
      try {
        if (fs.existsSync(filePath)) {
          fs.unlinkSync(filePath);
        }
      } catch (_) {}
      return res.status(500).json({
        message: error && error.message ? error.message : 'Failed to store release file',
      });
    }
  }
);

app.get('/api/agents', (req, res) => {
  const now = Date.now();
  const onlineAgents = Array.from(agentsByDeviceId.values())
    .filter((agent) => isAgentOnline(agent, now))
    .sort((a, b) => b.lastSeenAt - a.lastSeenAt)
    .map(sanitizeAgent);

  res.json({ agents: onlineAgents });
});

app.post('/api/pair/request', (req, res) => {
  const deviceId = String(req.body?.device_id || '').trim();
  const pairCode = String(req.body?.pair_code || '').trim();
  const clientId = String(req.body?.client_id || '').trim();
  const clientName = String(req.body?.client_name || '').trim();

  if (!deviceId || !pairCode || !clientId) {
    return res.status(400).json({ message: 'device_id, pair_code, client_id are required' });
  }

  const agent = agentsByDeviceId.get(deviceId);
  if (!agent || !agent.ws) {
    return res.status(404).json({ message: 'Device is offline or unavailable' });
  }

  if (agent.pairCode !== pairCode) {
    return res.status(403).json({ message: 'Pair code is invalid' });
  }

  clients.set(clientId, {
    clientId,
    clientName,
    linkedAt: clients.get(clientId)?.linkedAt || Date.now(),
    lastSeenAt: Date.now(),
  });
  persistState();

  const requestId = generateRequestId();
  const request = {
    requestId,
    deviceId,
    clientId,
    clientName,
    createdAt: Date.now(),
    status: 'pending',
  };
  pairRequests.set(requestId, request);

  safeSendJson(agent.ws, {
    type: 'pair_request',
    request_id: requestId,
    device_id: deviceId,
    client_id: clientId,
    client_name: clientName,
  });

  return res.json({
    request_id: requestId,
    status: 'pending',
  });
});

app.get('/api/pair/status/:requestId', (req, res) => {
  const request = pairRequests.get(req.params.requestId);
  if (!request) {
    return res.status(404).json({ message: 'Pair request not found' });
  }
  return res.json({
    request_id: request.requestId,
    status: request.status,
    device_id: request.deviceId,
    client_id: request.clientId,
  });
});

app.get('/api/trusted-devices/:clientId', (req, res) => {
  const clientId = String(req.params.clientId || '').trim();
  const devices = Array.from(agentsByDeviceId.values())
    .filter((agent) => isClientTrusted(agent.deviceId, clientId))
    .map(sanitizeAgent);
  res.json({ devices });
});

app.post(
  '/api/file-transfer/upload',
  (req, res) => {
    cleanupExpiredTransfers();
    const deviceId = String(req.query.device_id || req.headers['x-device-id'] || '').trim();
    const clientId = String(req.query.client_id || req.headers['x-client-id'] || '').trim();
    const fileName = safeFilename(req.query.file_name || req.headers['x-file-name'] || '');
    const declaredSize = Number(req.query.file_size || req.headers['x-file-size'] || 0) || 0;
    const contentLength = Number(req.headers['content-length'] || 0) || 0;

    if (!deviceId || !clientId || !fileName) {
      return res.status(400).json({ message: 'device_id, client_id and file_name are required' });
    }
    if (!isClientTrusted(deviceId, clientId)) {
      return res.status(403).json({ message: 'Client is not trusted for this device' });
    }
    if (declaredSize > MAX_TRANSFER_SIZE || contentLength > MAX_TRANSFER_SIZE) {
      return res.status(413).json({ message: 'File too large' });
    }

    const token = createTransferToken();
    const filePath = fileTransferStore.createFilePath(token, fileName);
    const expiresAt = Date.now() + FILE_TRANSFER_TTL_MS;
    const output = fs.createWriteStream(filePath);
    let received = 0;
    let completed = false;

    const fail = (status, message) => {
      if (completed) return;
      completed = true;
      try {
        output.destroy();
      } catch (_) {}
      try {
        if (fs.existsSync(filePath)) {
          fs.unlinkSync(filePath);
        }
      } catch (_) {}
      return res.status(status).json({ message });
    };

    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > MAX_TRANSFER_SIZE) {
        fail(413, 'File too large');
        req.destroy();
        return;
      }
      if (!output.write(chunk)) {
        req.pause();
      }
    });
    output.on('drain', () => {
      req.resume();
    });
    req.on('aborted', () => {
      fail(400, 'Upload aborted');
    });
    req.on('error', (error) => {
      fail(500, error && error.message ? error.message : 'Upload failed');
    });
    output.on('error', (error) => {
      fail(500, error && error.message ? error.message : 'Failed to store transfer file');
    });
    req.on('end', () => {
      if (completed) return;
      output.end();
    });
    output.on('finish', () => {
      if (completed) return;
      if (received <= 0) {
        fail(400, 'Missing file body');
        return;
      }
      if (declaredSize > 0 && received !== declaredSize) {
        fail(400, 'Uploaded size does not match file_size');
        return;
      }
      completed = true;
      fileTransferStore.add({
        token,
        deviceId,
        clientId,
        fileName,
        filePath,
        size: received,
        expiresAt,
        createdAt: Date.now(),
      });
      return res.json({
        token,
        file_name: fileName,
        size: received,
        expires_at: expiresAt,
        download_url: `${req.protocol}://${req.get('host')}/api/file-transfer/${token}?client_id=${encodeURIComponent(clientId)}`,
        relative_download_url: `/api/file-transfer/${token}?client_id=${encodeURIComponent(clientId)}`,
      });
    });
  }
);

// Diagnostic bundle upload. The phone heartbeat watchdog writes log files to
// its private app directory; when the user hits "Upload diagnostics" we
// receive each file here as raw octet-stream and persist it under
// data/diagnostics/<bundle>/<safe-filename>. No client-id check: the user
// asked for this explicitly, and the size cap is small (10MB per file).
app.post('/api/diagnostics/upload', (req, res) => {
  const bundle = String(req.query.bundle || '').replace(/[^0-9A-Za-z_\-]/g, '');
  const fileNameRaw = String(req.query.file_name || '');
  const fileName = safeFilename(fileNameRaw);
  if (!bundle || !fileName) {
    return res.status(400).json({ message: 'bundle and file_name are required' });
  }
  const MAX_DIAG_SIZE = 10 * 1024 * 1024;
  const bundleDir = path.join(DIAGNOSTICS_DIR, bundle);
  try {
    fs.mkdirSync(bundleDir, { recursive: true });
  } catch (error) {
    return res.status(500).json({ message: 'Failed to create bundle dir' });
  }
  const filePath = path.join(bundleDir, fileName);
  const output = fs.createWriteStream(filePath);
  let received = 0;
  let completed = false;
  const fail = (status, message) => {
    if (completed) return;
    completed = true;
    try { output.destroy(); } catch (_) {}
    try { if (fs.existsSync(filePath)) fs.unlinkSync(filePath); } catch (_) {}
    return res.status(status).json({ message });
  };
  req.on('data', (chunk) => {
    received += chunk.length;
    if (received > MAX_DIAG_SIZE) {
      fail(413, 'File too large');
      req.destroy();
      return;
    }
    if (!output.write(chunk)) req.pause();
  });
  output.on('drain', () => req.resume());
  req.on('aborted', () => fail(400, 'Upload aborted'));
  req.on('error', (e) => fail(500, e?.message || 'Upload failed'));
  req.on('end', () => { if (!completed) output.end(); });
  output.on('finish', () => {
    if (completed) return;
    completed = true;
    return res.json({ bundle, file_name: fileName, size: received });
  });
});

app.get('/api/file-transfer/:token', (req, res) => {
  const transfer = requireTrustedTransfer(req, res);
  if (!transfer) {
    return;
  }

  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader(
    'Content-Disposition',
    `attachment; filename="${encodeURIComponent(transfer.fileName).replace(/%20/g, ' ')}"`
  );
  res.setHeader('Content-Length', String(transfer.size));
  res.setHeader('X-PocketWindow-Transfer-Expires-At', String(transfer.expiresAt));

  const stream = fs.createReadStream(transfer.filePath);
  stream.on('error', (error) => {
    if (!res.headersSent) {
      res.status(500).json({ message: error && error.message ? error.message : 'Read failed' });
    } else {
      res.destroy(error);
    }
  });
  stream.pipe(res);
});

const wss = new WebSocket.Server({ server, path: '/ws' });
roomChannels = createRoomChannels({ rooms, safeSendJson, WebSocket });

// Heartbeat: actively probe each WS so half-open TCP connections (frps tunnel
// timeouts, mobile network handoffs, CF-side resets) get cleaned up rather
// than lingering in readyState=OPEN forever. Without this, an agent that
// reconnected after a hard network drop would be rejected with "already
// connected" because the dead old socket was still occupying the slot.
const WS_HEARTBEAT_INTERVAL_MS = 25000;
const WS_HEARTBEAT_TIMEOUT_MS = 60000;

wss.on('connection', (ws) => {
  ws._roomId = null;
  ws._role = null;
  ws._channel = '';
  ws._deviceId = null;
  ws._clientId = null;
  ws._isAlive = true;
  ws._lastPongAt = Date.now();

  ws.on('pong', () => {
    ws._isAlive = true;
    ws._lastPongAt = Date.now();
  });

  ws.on('message', (data, isBinary) => {
    if (isBinary || isPocketWindowVideoFrameBinary(data)) {
      handleBinaryMessage(ws, data);
      return;
    }

    let message;
    try {
      message = JSON.parse(data.toString());
    } catch (_) {
      safeSendJson(ws, { type: 'error', message: 'Invalid JSON' });
      return;
    }

    handleMessage(ws, message);
  });

  ws.on('close', () => cleanupWs(ws, 'close'));
  ws.on('error', (err) => {
    console.error('[WS] Error:', err && err.message ? err.message : String(err));
    cleanupWs(ws, 'error');
  });
});

const heartbeatTimer = setInterval(() => {
  const now = Date.now();
  wss.clients.forEach((ws) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (now - (ws._lastPongAt || 0) > WS_HEARTBEAT_TIMEOUT_MS) {
      // Peer hasn't acknowledged our pings; treat as zombie and drop it so
      // the next reconnect from the same device can take its slot.
      console.log(
        `[WS] Heartbeat timeout (room=${ws._roomId || '-'} role=${ws._role || '-'}` +
          ` channel=${ws._channel || '-'}) - terminating`
      );
      try {
        cleanupWs(ws, 'heartbeat-timeout');
      } catch (_) {}
      try {
        ws.terminate();
      } catch (_) {}
      return;
    }
    ws._isAlive = false;
    try {
      ws.ping();
    } catch (_) {}
  });
}, WS_HEARTBEAT_INTERVAL_MS);

wss.on('close', () => clearInterval(heartbeatTimer));

function handleMessage(ws, message) {
  const type = message?.type;

  if (type === 'join_room') {
    const roomId = String(message.room_id || '').trim();
    const role = String(message.role || '').trim();
    const channel = roomChannels.normalizeChannel(message.channel);

    if (!roomId || (role !== 'agent' && role !== 'client')) {
      safeSendJson(ws, { type: 'error', message: 'Missing or invalid room_id or role' });
      return;
    }

    let room = getOrCreateRoom(roomId);

    if (role === 'agent') {
      const agent = upsertAgent(roomId, message.metadata || {});
      if (!agent) {
        safeSendJson(ws, { type: 'error', message: 'device_id is required for agent' });
        return;
      }
      ws._deviceId = agent.deviceId;
      if (!channel || channel === 'control') {
        updateAgentSocket(agent.deviceId, ws);
      }
      if (!channel || channel === 'control') {
        safeSendJson(ws, {
          type: 'pairing_info',
          device_id: agent.deviceId,
          room_id: roomId,
          pair_code: agent.pairCode,
        });
      }
    } else {
      const clientId = String(message.client_id || '').trim();
      if (!clientId) {
        safeSendJson(ws, { type: 'error', message: 'client_id is required for client' });
        return;
      }
      ws._clientId = clientId;
      clients.set(clientId, {
        clientId,
        clientName: String(message.client_name || '').trim(),
        linkedAt: clients.get(clientId)?.linkedAt || Date.now(),
        lastSeenAt: Date.now(),
      });
      persistState();

      const targetDeviceId = String(message.device_id || '').trim();
      const trusted = targetDeviceId && isClientTrusted(targetDeviceId, clientId);
      if (!trusted) {
        safeSendJson(ws, {
          type: 'error',
          message: 'This client is not authorized for the target device',
        });
        return;
      }
    }

    const registerResult = roomChannels.registerPeer(roomId, role, channel, ws);
    if (!registerResult.ok) {
      safeSendJson(ws, { type: 'error', message: registerResult.reason || `${role} already connected` });
      return;
    }
    if (registerResult.replaced) {
      const existingWs = registerResult.replaced;
      console.log(
        `[WS] Replacing ${role}${channel ? ` ${channel}` : ''} connection in room ${roomId}` +
          (role === 'client' ? ` for client ${String(ws._clientId || '').trim()}` : '')
      );

      cleanupWs(existingWs, 'replaced');
      try {
        existingWs.close(4001, 'replaced by newer connection');
      } catch (_) {
        try {
          existingWs.terminate();
        } catch (_) {}
      }

      room = rooms.get(roomId) || getOrCreateRoom(roomId);
    }

    ws._roomId = roomId;
    ws._role = role;
    ws._channel = channel;

    safeSendJson(ws, { type: 'room_joined', room_id: roomId, role, channel });

    const peerRole = role === 'agent' ? 'client' : 'agent';
    const peer = roomChannels.getPeerSocket(room, peerRole, channel || 'control');
    if (peer) {
      const clientId = role === 'client'
        ? String(ws._clientId || '').trim()
        : String(peer._clientId || '').trim();
      safeSendJson(peer, { type: 'remote_connected', role, channel, client_id: clientId });
      safeSendJson(ws, { type: 'remote_connected', role: peerRole, channel, client_id: clientId });
    }
    return;
  }

  if (type === 'agent_heartbeat') {
    const roomId = String(message.room_id || ws._roomId || '').trim();
    const agent = upsertAgent(roomId, message.metadata || {});
    if (agent) {
      updateAgentSocket(agent.deviceId, ws);
      ws._deviceId = agent.deviceId;
    }
    return;
  }

  if (type === 'agent_update') {
    const roomId = String(message.room_id || ws._roomId || '').trim();
    const agent = upsertAgent(roomId, message.metadata || {}, message.selected_window_title);
    if (agent) {
      updateAgentSocket(agent.deviceId, ws);
      ws._deviceId = agent.deviceId;
    }
    return;
  }

  if (type === 'agent_trusted_clients_sync') {
    const deviceId = String(message.device_id || ws._deviceId || '').trim();
    if (!deviceId) {
      safeSendJson(ws, { type: 'error', message: 'device_id is required for trusted sync' });
      return;
    }
    const trusted = trustedSetForDevice(deviceId);
    trusted.clear();
    const entries = Array.isArray(message.trusted_clients) ? message.trusted_clients : [];
    for (const item of entries) {
      if (!item || typeof item !== 'object') continue;
      const clientId = String(item.client_id || item.clientId || '').trim();
      if (!clientId) continue;
      trusted.add(clientId);
      const previous = clients.get(clientId) || {};
      clients.set(clientId, {
        clientId,
        clientName: String(item.client_name || item.clientName || previous.clientName || '').trim(),
        linkedAt: Number(item.linked_at || item.linkedAt || previous.linkedAt || 0) || Date.now(),
        lastSeenAt: Number(item.last_connected_at || item.lastConnectedAt || previous.lastSeenAt || 0),
      });
    }
    persistState();
    safeSendJson(ws, { type: 'agent_trusted_clients_sync_ack', device_id: deviceId });
    return;
  }

  if (type === 'pair_response') {
    const requestId = String(message.request_id || '').trim();
    const approved = message.approved === true;
    const request = pairRequests.get(requestId);
    if (!request) {
      safeSendJson(ws, { type: 'error', message: 'Pair request not found' });
      return;
    }

    request.status = approved ? 'approved' : 'rejected';
    if (approved) {
      trustedSetForDevice(request.deviceId).add(request.clientId);
      persistState();
    }

    const clientWs = Array.from(wss.clients).find((item) => item._clientId === request.clientId);
    if (clientWs) {
      safeSendJson(clientWs, {
        type: 'pair_result',
        request_id: requestId,
        device_id: request.deviceId,
        approved,
      });
    }
    return;
  }

  const roomId = String(message.room_id || ws._roomId || '').trim();
  if (!roomId) {
    safeSendJson(ws, { type: 'error', message: 'Not in a room' });
    return;
  }

  if (
    type === 'webrtc_offer' ||
    type === 'webrtc_answer' ||
    type === 'webrtc_ice_candidate' ||
    type === 'webrtc_transport_state'
  ) {
    const targetRole = ws._role === 'agent' ? 'client' : 'agent';
    const ok = roomChannels.forwardToRoomPeer(roomId, targetRole, message, 'control');
    if (!ok) {
      safeSendJson(ws, { type: 'error', message: `${targetRole} not connected` });
    }
    return;
  }

  if (
    type === 'image_frame' ||
    type === 'video_stream_start' ||
    type === 'video_stream_frame' ||
    type === 'video_stream_progress' ||
    type === 'video_stream_keepalive' ||
    type === 'video_stream_stop' ||
    type === 'cursor_position' ||
    type === 'windows_list' ||
    type === 'set_window_response' ||
    type === 'control_response'
  ) {
    const preferredChannel = (
      type === 'image_frame' ||
      type === 'video_stream_start' ||
      type === 'video_stream_frame' ||
      type === 'video_stream_keepalive' ||
      type === 'video_stream_stop'
    ) ? 'media' : 'control';
    let ok = roomChannels.forwardToRoomPeer(roomId, 'client', message, preferredChannel);
    if (!ok && preferredChannel === 'media') {
      ok = roomChannels.forwardToRoomPeer(roomId, 'client', message, 'control');
    }
    if (!ok) {
      safeSendJson(ws, { type: 'error', message: 'Client not connected' });
    }
    return;
  }

  if (
    type === 'control' ||
    type === 'get_windows' ||
    type === 'set_window' ||
    type === 'image_frame_ack' ||
    type === 'video_stream_status' ||
    type === 'video_frame_ack' ||
    type === 'video_congestion'
  ) {
    const ok = roomChannels.forwardToRoomPeer(roomId, 'agent', message, 'control');
    if (!ok) {
      safeSendJson(ws, { type: 'error', message: 'Agent not connected' });
    }
    return;
  }

  safeSendJson(ws, { type: 'error', message: `Unknown type: ${String(type)}` });
}

const PORT = process.env.PORT || 58080;

initFileTransferStore();
initReleaseStore();
loadPersistedState();
loadPersistedReleases();

server.listen(PORT, () => {
  console.log(`PocketWindow signaling server listening on ${PORT}`);
});

module.exports = { app, server, wss };
