# PocketWindow Server - Docker 部署

## 快速启动

```bash
# 构建镜像
docker build -t pocketwindow-server .

# 运行容器
docker run -d -p 58080:58080 --name pocketwindow-server pocketwindow-server
```

## Docker Compose

```bash
docker-compose up -d
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| PORT | 58080 | 服务器监听端口 |
| NODE_ENV | production | 运行环境 |

## API 端点

### 健康检查
```
GET /api/health
Response: {"status": "ok", "timestamp": "...", "activeConnections": 0}
```

### 创建房间
```
POST /api/create_room
Response: {"room_id": "pw-abc123...", "message": "Room created successfully"}
```

### 查询房间
```
GET /api/list_rooms
Response: {"rooms": [{"room_id": "...", "connected": false, "created_at": ...}]}
```

## WebSocket

- WebSocket: `ws://<host>:58080/ws`
