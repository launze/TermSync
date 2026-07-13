# PocketWindow Server
WebRTC 信令服务器，用于协调手机端与被控端的连接

## 功能

- WebRTC 信令中转
- 连接管理
- 心跳检测
- 简单的 REST API

## 运行

```bash
npm install
npm start
```

## 端点

- WebSocket: `ws://<host>:58080/ws`
- REST:
  - `POST http://<host>:58080/api/create_room`
  - `GET  http://<host>:58080/api/health`
  - `GET  http://<host>:58080/api/list_rooms`
