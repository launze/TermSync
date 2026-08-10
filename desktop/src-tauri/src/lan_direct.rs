use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::net::{Ipv4Addr, UdpSocket};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};
use tokio::task::JoinHandle;
use uuid::Uuid;

const PAIRING_TTL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LanDevice {
    id: String,
    name: String,
    token: String,
    #[serde(rename = "type")]
    device_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedLanState {
    owner_id: String,
    owner_name: String,
    viewers: Vec<LanDevice>,
}

#[derive(Debug, Clone)]
struct PairingCode {
    code: String,
    expires_at: u64,
}

struct ViewerConnection {
    connection_id: String,
    device: LanDevice,
    sender: mpsc::UnboundedSender<Message>,
    workspace_subscribed: bool,
    pane_subscriptions: HashSet<String>,
}

struct LanDirectInner {
    running: bool,
    port: u16,
    owner_id: String,
    owner_name: String,
    pairing: Option<PairingCode>,
    pairing_failed_attempts: u8,
    pending_devices: HashMap<String, LanDevice>,
    paired_devices: HashMap<String, LanDevice>,
    connections: HashMap<String, ViewerConnection>,
    latest_layout: Option<Value>,
    pane_meta: HashMap<String, Value>,
    screen_snapshots: HashMap<String, Value>,
    persist_path: Option<PathBuf>,
    app: Option<AppHandle>,
    task: Option<JoinHandle<()>>,
}

impl Default for LanDirectInner {
    fn default() -> Self {
        Self {
            running: false,
            port: 7390,
            owner_id: Uuid::new_v4().to_string(),
            owner_name: "TTY1 Desktop".to_string(),
            pairing: None,
            pairing_failed_attempts: 0,
            pending_devices: HashMap::new(),
            paired_devices: HashMap::new(),
            connections: HashMap::new(),
            latest_layout: None,
            pane_meta: HashMap::new(),
            screen_snapshots: HashMap::new(),
            persist_path: None,
            app: None,
            task: None,
        }
    }
}

#[derive(Clone, Default)]
pub struct LanDirectState {
    inner: Arc<Mutex<LanDirectInner>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LanDirectStatus {
    pub running: bool,
    pub port: u16,
    pub ip: String,
    pub ips: Vec<String>,
    pub websocket_url: String,
    pub websocket_urls: Vec<String>,
    pub owner_id: String,
    pub pairing_code: Option<String>,
    pub pairing_expires_at: Option<u64>,
    pub paired_receivers: usize,
    pub connected_receivers: usize,
}

#[derive(Debug, Deserialize)]
struct RegisterRequest {
    name: Option<String>,
    #[serde(rename = "type")]
    device_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CompletePairingRequest {
    token: String,
    code: String,
}

#[derive(Debug, Deserialize)]
struct UnbindRequest {
    token: String,
}

#[derive(Clone, Serialize)]
struct FrontendServerMessage {
    #[serde(rename = "type")]
    event_type: String,
    id: Option<String>,
    workspace_id: Option<String>,
    pane_id: Option<String>,
    session_id: Option<String>,
    payload: Value,
}

impl LanDirectState {
    pub async fn start(
        &self,
        app: AppHandle,
        port: u16,
        owner_name: String,
    ) -> Result<LanDirectStatus, String> {
        if port == 0 {
            return Err("LAN direct port must be between 1 and 65535".to_string());
        }
        {
            let inner = self.inner.lock().await;
            if inner.running {
                return Ok(status_from_inner(&inner));
            }
        }

        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
            .await
            .map_err(|error| format!("Failed to listen on LAN port {port}: {error}"))?;
        let persist_path = app
            .path()
            .app_data_dir()
            .map_err(|error| format!("Failed to resolve app data directory: {error}"))?
            .join("lan-direct.json");
        let persisted = load_persisted_state(&persist_path);

        {
            let mut inner = self.inner.lock().await;
            if let Some(persisted) = persisted {
                inner.owner_id = persisted.owner_id;
                inner.owner_name = persisted.owner_name;
                inner.paired_devices = persisted
                    .viewers
                    .into_iter()
                    .map(|device| (device.token.clone(), device))
                    .collect();
            }
            let trimmed_name = owner_name.trim();
            if !trimmed_name.is_empty() {
                inner.owner_name = trimmed_name.to_string();
            }
            inner.running = true;
            inner.port = port;
            inner.persist_path = Some(persist_path);
            inner.app = Some(app.clone());
            persist_inner(&inner)?;
        }

        let router = lan_router(self.clone());
        let state = self.clone();
        let task = tokio::spawn(async move {
            if let Err(error) = axum::serve(listener, router).await {
                crate::log_debug(&format!("lan-direct:server:error={error}"));
            }
            let mut inner = state.inner.lock().await;
            inner.running = false;
            inner.connections.clear();
        });
        {
            let mut inner = self.inner.lock().await;
            inner.task = Some(task);
        }
        self.emit_peer_state().await;
        Ok(self.status().await)
    }

    pub async fn stop(&self) -> LanDirectStatus {
        let task = {
            let mut inner = self.inner.lock().await;
            inner.running = false;
            inner.pairing = None;
            inner.connections.clear();
            inner.task.take()
        };
        if let Some(task) = task {
            task.abort();
        }
        self.emit_peer_state().await;
        self.status().await
    }

    pub async fn status(&self) -> LanDirectStatus {
        let mut inner = self.inner.lock().await;
        clear_expired_pairing(&mut inner);
        status_from_inner(&inner)
    }

    pub async fn generate_pairing_code(&self) -> Result<LanDirectStatus, String> {
        let mut inner = self.inner.lock().await;
        if !inner.running {
            return Err("LAN direct server is not running".to_string());
        }
        let code = pairing_code();
        inner.pairing = Some(PairingCode {
            code,
            expires_at: unix_seconds() + PAIRING_TTL.as_secs(),
        });
        inner.pairing_failed_attempts = 0;
        Ok(status_from_inner(&inner))
    }

    pub async fn clear_paired_receivers(&self) -> Result<LanDirectStatus, String> {
        let senders = {
            let mut inner = self.inner.lock().await;
            inner.pairing = None;
            inner.pairing_failed_attempts = 0;
            inner.pending_devices.clear();
            inner.paired_devices.clear();
            let senders = inner
                .connections
                .drain()
                .map(|(_, connection)| connection.sender)
                .collect::<Vec<_>>();
            persist_inner(&inner)?;
            senders
        };
        for sender in senders {
            let _ = sender.send(Message::Close(None));
        }
        self.emit_peer_state().await;
        Ok(self.status().await)
    }

    async fn unpair_receiver(&self, token: &str) -> Result<bool, String> {
        let (removed, sender) = {
            let mut inner = self.inner.lock().await;
            let pending_removed = inner.pending_devices.remove(token).is_some();
            let paired = inner.paired_devices.remove(token);
            let sender = paired
                .as_ref()
                .and_then(|device| inner.connections.remove(&device.id))
                .map(|connection| connection.sender);
            let removed = pending_removed || paired.is_some();
            if removed {
                persist_inner(&inner)?;
            }
            (removed, sender)
        };
        if let Some(sender) = sender {
            let _ = sender.send(Message::Close(None));
        }
        if removed {
            self.emit_peer_state().await;
        }
        Ok(removed)
    }

    pub async fn publish_owner_message(&self, value: Value) -> bool {
        let mut inner = self.inner.lock().await;
        if !inner.running {
            return false;
        }
        let message_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match message_type {
            "layout.snapshot" | "layout.patch" => {
                let workspace_id = value
                    .get("workspace_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let live_meta_keys = layout_pane_ids(&value)
                    .into_iter()
                    .map(|pane_id| format!("{workspace_id}\u{1f}{pane_id}"))
                    .collect::<HashSet<_>>();
                if !workspace_id.is_empty() {
                    inner.pane_meta.retain(|key, _| {
                        let belongs_to_workspace =
                            key.split_once('\u{1f}')
                                .is_some_and(|(cached_workspace_id, _)| {
                                    cached_workspace_id == workspace_id
                                });
                        !belongs_to_workspace || live_meta_keys.contains(key)
                    });
                }
                inner.latest_layout = Some(value.clone());
            }
            "pane.meta" => {
                if let Some(key) = pane_meta_key(&value) {
                    inner.pane_meta.insert(key, value.clone());
                }
            }
            "screen.snapshot" => {
                if let Some(key) = screen_key(&value) {
                    inner.screen_snapshots.insert(key, value.clone());
                }
            }
            _ => {}
        }

        let target = value
            .get("payload")
            .and_then(|payload| payload.get("target_device_id"))
            .and_then(Value::as_str);
        let pane_key = screen_key(&value);
        for connection in inner.connections.values() {
            if target.is_some_and(|target| target != connection.device.id) {
                continue;
            }
            let should_send = match message_type {
                "layout.snapshot" | "layout.patch" | "pane.meta" => connection.workspace_subscribed,
                "screen.snapshot" | "screen.delta" | "screen.clear" => pane_key
                    .as_ref()
                    .is_some_and(|key| connection.pane_subscriptions.contains(key)),
                "screen.history_response" => target == Some(connection.device.id.as_str()),
                _ => true,
            };
            if should_send {
                let _ = connection.sender.send(Message::Text(value.to_string()));
            }
        }
        true
    }

    async fn route_viewer_message(&self, device_id: &str, value: Value) {
        let message_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut direct_replies = Vec::new();
        let mut owner_message = None;
        let app = {
            let mut inner = self.inner.lock().await;
            match message_type {
                "workspace.list" => {
                    let workspace_id = inner
                        .latest_layout
                        .as_ref()
                        .and_then(|message| message.get("workspace_id"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| format!("{}:default", inner.owner_id));
                    direct_replies.push(protocol_message(
                        "workspace.list_res",
                        None,
                        None,
                        json!({
                            "workspaces": [{
                                "workspace_id": workspace_id,
                                "owner_device_id": inner.owner_id,
                                "owner_name": inner.owner_name
                            }]
                        }),
                    ));
                }
                "workspace.subscribe" => {
                    if let Some(connection) = inner.connections.get_mut(device_id) {
                        connection.workspace_subscribed = true;
                    }
                    let latest_layout = inner.latest_layout.clone();
                    if let Some(layout) = latest_layout.as_ref() {
                        direct_replies.push(layout.clone());
                    }
                    let workspace_id = value
                        .get("workspace_id")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let meta_keys = latest_layout
                        .as_ref()
                        .map(layout_pane_ids)
                        .unwrap_or_default()
                        .into_iter()
                        .map(|pane_id| format!("{workspace_id}\u{1f}{pane_id}"));
                    for key in meta_keys {
                        if let Some(meta) = inner.pane_meta.get(&key) {
                            direct_replies.push(meta.clone());
                        }
                    }
                }
                "workspace.unsubscribe" => {
                    if let Some(connection) = inner.connections.get_mut(device_id) {
                        connection.workspace_subscribed = false;
                    }
                }
                "screen.subscribe" => {
                    if let Some(key) = screen_key(&value) {
                        if let Some(connection) = inner.connections.get_mut(device_id) {
                            connection.pane_subscriptions.insert(key.clone());
                        }
                        if let Some(snapshot) = inner.screen_snapshots.get(&key).cloned() {
                            direct_replies.push(snapshot);
                        }
                    }
                }
                "screen.unsubscribe" => {
                    if let Some(key) = screen_key(&value) {
                        if let Some(connection) = inner.connections.get_mut(device_id) {
                            connection.pane_subscriptions.remove(&key);
                        }
                    }
                }
                "input.send"
                | "layout.action_request"
                | "screen.resync_request"
                | "screen.history_request" => {
                    owner_message = Some(add_requested_by(value, device_id));
                }
                "screen.ack" | "heartbeat" => {}
                _ => {
                    direct_replies.push(protocol_error(
                        "permission_denied",
                        "LAN receivers may only send viewer protocol messages",
                    ));
                }
            }
            if let Some(connection) = inner.connections.get(device_id) {
                for reply in &direct_replies {
                    let _ = connection.sender.send(Message::Text(reply.to_string()));
                }
            }
            inner.app.clone()
        };
        if let (Some(app), Some(message)) = (app, owner_message) {
            emit_owner_message(&app, message);
        }
    }

    async fn emit_peer_state(&self) {
        let (app, peers) = {
            let inner = self.inner.lock().await;
            let peers = inner
                .paired_devices
                .values()
                .map(|device| {
                    json!({
                        "id": device.id,
                        "name": device.name,
                        "type": "pc_receiver",
                        "online": inner.connections.contains_key(&device.id)
                    })
                })
                .collect::<Vec<_>>();
            (inner.app.clone(), peers)
        };
        if let Some(app) = app {
            let _ = app.emit("lan-peer-state", json!({ "peers": peers }));
        }
    }

    #[cfg(test)]
    pub(crate) async fn add_test_receiver(&self) -> mpsc::UnboundedReceiver<Message> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let mut inner = self.inner.lock().await;
        inner.running = true;
        inner.connections.insert(
            "test-viewer".to_string(),
            ViewerConnection {
                connection_id: "test-connection".to_string(),
                device: LanDevice {
                    id: "test-viewer".to_string(),
                    name: "Test Receiver".to_string(),
                    token: "test-token".to_string(),
                    device_type: "pc_receiver".to_string(),
                },
                sender,
                workspace_subscribed: true,
                pane_subscriptions: HashSet::new(),
            },
        );
        receiver
    }
}

async fn health_handler() -> Json<Value> {
    Json(json!({ "status": "ok", "mode": "lan-direct", "protocol": 3 }))
}

async fn register_handler(
    State(state): State<LanDirectState>,
    Json(request): Json<RegisterRequest>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let device_type = request
        .device_type
        .unwrap_or_else(|| "pc_receiver".to_string());
    if device_type != "pc_receiver" {
        return Err((
            StatusCode::FORBIDDEN,
            "LAN direct endpoint only registers PC receivers".to_string(),
        ));
    }
    let device = LanDevice {
        id: Uuid::new_v4().to_string(),
        name: request
            .name
            .unwrap_or_else(|| "TermSync PC Receiver".to_string()),
        token: Uuid::new_v4().to_string(),
        device_type,
    };
    let mut inner = state.inner.lock().await;
    if inner.pending_devices.len() >= 256 {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "Too many pending LAN registrations".to_string(),
        ));
    }
    inner
        .pending_devices
        .insert(device.token.clone(), device.clone());
    Ok(Json(json!({ "success": true, "device": device })))
}

async fn complete_pairing_handler(
    State(state): State<LanDirectState>,
    Json(request): Json<CompletePairingRequest>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let pairing;
    {
        let mut inner = state.inner.lock().await;
        clear_expired_pairing(&mut inner);
        let valid_code = inner
            .pairing
            .as_ref()
            .is_some_and(|pairing| pairing.code == request.code);
        if !valid_code {
            inner.pairing_failed_attempts = inner.pairing_failed_attempts.saturating_add(1);
            if inner.pairing_failed_attempts >= 10 {
                inner.pairing = None;
            }
            return Err((
                StatusCode::BAD_REQUEST,
                "Pairing code not found or expired".to_string(),
            ));
        }
        let device = inner
            .pending_devices
            .remove(&request.token)
            .or_else(|| inner.paired_devices.get(&request.token).cloned())
            .ok_or_else(|| {
                (
                    StatusCode::UNAUTHORIZED,
                    "Unknown receiver token".to_string(),
                )
            })?;
        inner
            .paired_devices
            .insert(device.token.clone(), device.clone());
        inner.pairing = None;
        inner.pairing_failed_attempts = 0;
        persist_inner(&inner).map_err(|error| (StatusCode::INTERNAL_SERVER_ERROR, error))?;
        pairing = json!({
            "desktop_id": inner.owner_id,
            "desktop_name": inner.owner_name,
            "mobile_id": device.id,
            "mobile_name": device.name,
            "created_at": ""
        });
    }
    state.emit_peer_state().await;
    Ok(Json(json!({ "success": true, "pairing": pairing })))
}

async fn unbind_handler(
    State(state): State<LanDirectState>,
    Json(request): Json<UnbindRequest>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let token = request.token.trim();
    if token.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Receiver token is required".to_string(),
        ));
    }
    let removed = state
        .unpair_receiver(token)
        .await
        .map_err(|error| (StatusCode::INTERNAL_SERVER_ERROR, error))?;
    Ok(Json(json!({ "success": true, "removed": removed })))
}

async fn websocket_handler(
    websocket: WebSocketUpgrade,
    State(state): State<LanDirectState>,
) -> impl IntoResponse {
    websocket
        .protocols(["termsync-protocol"])
        .on_upgrade(move |socket| handle_socket(state, socket))
}

fn lan_router(state: LanDirectState) -> Router {
    Router::new()
        .route("/api/health", get(health_handler))
        .route("/api/register", post(register_handler))
        .route("/api/pairing/complete", post(complete_pairing_handler))
        .route("/api/pairing/unbind", post(unbind_handler))
        .route("/ws", get(websocket_handler))
        .with_state(state)
}

async fn handle_socket(state: LanDirectState, mut socket: WebSocket) {
    let auth_message = match tokio::time::timeout(Duration::from_secs(5), socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => serde_json::from_str::<Value>(&text).ok(),
        _ => None,
    };
    let token = auth_message
        .as_ref()
        .filter(|message| message.get("type").and_then(Value::as_str) == Some("auth"))
        .and_then(|message| message.get("payload"))
        .and_then(|payload| payload.get("token"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let Some(token) = token else {
        let _ = socket
            .send(Message::Text(
                auth_response(false, None, "Missing authentication token").to_string(),
            ))
            .await;
        return;
    };
    let (device, owner_id, owner_name) = {
        let inner = state.inner.lock().await;
        (
            inner.paired_devices.get(&token).cloned(),
            inner.owner_id.clone(),
            inner.owner_name.clone(),
        )
    };
    let Some(device) = device else {
        let _ = socket
            .send(Message::Text(
                auth_response(false, None, "Receiver is not paired").to_string(),
            ))
            .await;
        return;
    };
    let connection_id = Uuid::new_v4().to_string();
    let _ = socket
        .send(Message::Text(
            auth_response(
                true,
                Some((&device, &connection_id)),
                "LAN direct connection authenticated",
            )
            .to_string(),
        ))
        .await;
    let _ = socket
        .send(Message::Text(
            protocol_message(
                "device.peer_state",
                None,
                None,
                json!({
                    "peers": [{
                        "id": owner_id,
                        "name": owner_name,
                        "type": "desktop",
                        "online": true
                    }]
                }),
            )
            .to_string(),
        ))
        .await;

    let (mut writer, mut reader) = socket.split();
    let (sender, mut outbound) = mpsc::unbounded_channel();
    {
        let mut inner = state.inner.lock().await;
        if let Some(previous) = inner.connections.remove(&device.id) {
            let _ = previous.sender.send(Message::Close(None));
        }
        inner.connections.insert(
            device.id.clone(),
            ViewerConnection {
                connection_id: connection_id.clone(),
                device: device.clone(),
                sender,
                workspace_subscribed: false,
                pane_subscriptions: HashSet::new(),
            },
        );
    }
    state.emit_peer_state().await;

    loop {
        tokio::select! {
            outgoing = outbound.recv() => {
                match outgoing {
                    Some(message) => {
                        if writer.send(message).await.is_err() { break; }
                    }
                    None => break,
                }
            }
            incoming = reader.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if text.len() > 2 * 1024 * 1024 {
                            break;
                        }
                        if let Ok(value) = serde_json::from_str::<Value>(&text) {
                            state.route_viewer_message(&device.id, value).await;
                        }
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        if writer.send(Message::Pong(payload)).await.is_err() { break; }
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
        }
    }
    {
        let mut inner = state.inner.lock().await;
        let is_current = inner
            .connections
            .get(&device.id)
            .is_some_and(|connection| connection.connection_id == connection_id);
        if is_current {
            inner.connections.remove(&device.id);
        }
    }
    state.emit_peer_state().await;
}

fn auth_response(success: bool, identity: Option<(&LanDevice, &str)>, message: &str) -> Value {
    protocol_message(
        "auth_response",
        None,
        None,
        json!({
            "success": success,
            "device_id": identity.map(|(device, _)| device.id.as_str()).unwrap_or(""),
            "device_type": "pc_receiver",
            "selected_protocol": 3,
            "connection_id": identity.map(|(_, connection_id)| connection_id).unwrap_or(""),
            "message": message
        }),
    )
}

fn protocol_message(
    message_type: &str,
    workspace_id: Option<&str>,
    pane_id: Option<&str>,
    payload: Value,
) -> Value {
    let mut message = serde_json::Map::new();
    message.insert("type".to_string(), Value::String(message_type.to_string()));
    message.insert("v".to_string(), json!(3));
    message.insert("id".to_string(), Value::String(Uuid::new_v4().to_string()));
    message.insert("timestamp".to_string(), json!(unix_seconds()));
    if let Some(workspace_id) = workspace_id {
        message.insert(
            "workspace_id".to_string(),
            Value::String(workspace_id.to_string()),
        );
    }
    if let Some(pane_id) = pane_id {
        message.insert("pane_id".to_string(), Value::String(pane_id.to_string()));
    }
    message.insert("payload".to_string(), payload);
    Value::Object(message)
}

fn protocol_error(code: &str, message: &str) -> Value {
    protocol_message(
        "error",
        None,
        None,
        json!({ "code": code, "message": message }),
    )
}

fn add_requested_by(mut value: Value, device_id: &str) -> Value {
    if let Some(message) = value.as_object_mut() {
        let payload = message
            .entry("payload".to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()));
        if let Some(payload) = payload.as_object_mut() {
            payload.insert(
                "requested_by".to_string(),
                Value::String(device_id.to_string()),
            );
        }
    }
    value
}

fn emit_owner_message(app: &AppHandle, value: Value) {
    let payload = FrontendServerMessage {
        event_type: value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        id: string_field(&value, "id"),
        workspace_id: string_field(&value, "workspace_id"),
        pane_id: string_field(&value, "pane_id"),
        session_id: string_field(&value, "session_id"),
        payload: value.get("payload").cloned().unwrap_or(Value::Null),
    };
    let _ = app.emit("server-message", payload);
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn pane_meta_key(value: &Value) -> Option<String> {
    let workspace_id = value.get("workspace_id").and_then(Value::as_str)?;
    let pane_id = value
        .get("pane_id")
        .and_then(Value::as_str)
        .or_else(|| value.get("payload")?.get("pane_id")?.as_str())?;
    Some(format!("{workspace_id}\u{1f}{pane_id}"))
}

fn layout_pane_ids(value: &Value) -> Vec<String> {
    let snapshot = value
        .get("payload")
        .and_then(|payload| payload.get("snapshot"))
        .unwrap_or(value);
    snapshot
        .get("tabs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|tab| {
            tab.get("panes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(|pane| {
            pane.get("pane_id")
                .and_then(Value::as_str)
                .or_else(|| pane.get("paneId").and_then(Value::as_str))
        })
        .filter(|pane_id| !pane_id.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn screen_key(value: &Value) -> Option<String> {
    let pane_id = value
        .get("pane_id")
        .and_then(Value::as_str)
        .or_else(|| value.get("payload")?.get("pane_id")?.as_str())?;
    let encoding = value
        .get("payload")
        .and_then(|payload| payload.get("encoding"))
        .and_then(Value::as_str)
        .unwrap_or("base64+vt");
    Some(format!("{pane_id}\u{1f}{encoding}"))
}

fn pairing_code() -> String {
    let bytes = Uuid::new_v4();
    bytes
        .as_bytes()
        .iter()
        .take(6)
        .map(|byte| char::from(b'0' + (byte % 10)))
        .collect()
}

fn clear_expired_pairing(inner: &mut LanDirectInner) {
    if inner
        .pairing
        .as_ref()
        .is_some_and(|pairing| pairing.expires_at <= unix_seconds())
    {
        inner.pairing = None;
    }
}

fn status_from_inner(inner: &LanDirectInner) -> LanDirectStatus {
    let ips = local_ipv4_addresses()
        .into_iter()
        .map(|ip| ip.to_string())
        .collect::<Vec<_>>();
    let ip = ips
        .first()
        .cloned()
        .unwrap_or_else(|| Ipv4Addr::LOCALHOST.to_string());
    let websocket_urls = if inner.running {
        ips.iter()
            .map(|ip| format!("ws://{ip}:{}/ws", inner.port))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    LanDirectStatus {
        running: inner.running,
        port: inner.port,
        ip,
        websocket_url: websocket_urls.first().cloned().unwrap_or_default(),
        websocket_urls,
        ips,
        owner_id: inner.owner_id.clone(),
        pairing_code: inner.pairing.as_ref().map(|pairing| pairing.code.clone()),
        pairing_expires_at: inner.pairing.as_ref().map(|pairing| pairing.expires_at),
        paired_receivers: inner.paired_devices.len(),
        connected_receivers: inner.connections.len(),
    }
}

fn local_ipv4_addresses() -> Vec<Ipv4Addr> {
    let primary = route_local_ipv4();
    let mut addresses = if_addrs::get_if_addrs()
        .map(|interfaces| {
            interfaces
                .into_iter()
                .filter_map(|interface| match interface.ip() {
                    std::net::IpAddr::V4(ip)
                        if !ip.is_unspecified()
                            && !ip.is_loopback()
                            && !ip.is_link_local()
                            && !ip.is_multicast() =>
                    {
                        Some(ip)
                    }
                    _ => None,
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    addresses.sort_by_key(|ip| ip.octets());
    addresses.dedup();
    if let Some(primary) = primary {
        addresses.retain(|ip| *ip != primary);
        addresses.insert(0, primary);
    }
    if addresses.is_empty() {
        addresses.push(Ipv4Addr::LOCALHOST);
    }
    addresses
}

fn route_local_ipv4() -> Option<Ipv4Addr> {
    UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .and_then(|socket| {
            socket.connect("8.8.8.8:80")?;
            socket.local_addr()
        })
        .ok()
        .and_then(|address| match address.ip() {
            std::net::IpAddr::V4(ip) if !ip.is_loopback() && !ip.is_unspecified() => Some(ip),
            _ => None,
        })
}

fn load_persisted_state(path: &PathBuf) -> Option<PersistedLanState> {
    let data = fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

fn persist_inner(inner: &LanDirectInner) -> Result<(), String> {
    let Some(path) = inner.persist_path.as_ref() else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Failed to create LAN state directory: {error}"))?;
    }
    let state = PersistedLanState {
        owner_id: inner.owner_id.clone(),
        owner_name: inner.owner_name.clone(),
        viewers: inner.paired_devices.values().cloned().collect(),
    };
    let data = serde_json::to_vec_pretty(&state)
        .map_err(|error| format!("Failed to encode LAN state: {error}"))?;
    fs::write(path, data).map_err(|error| format!("Failed to persist LAN state: {error}"))
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::connect_async;

    #[tokio::test]
    async fn receiver_cannot_publish_owner_messages() {
        let state = LanDirectState::default();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        {
            let mut inner = state.inner.lock().await;
            inner.running = true;
            inner.connections.insert(
                "viewer-1".to_string(),
                ViewerConnection {
                    connection_id: "connection-1".to_string(),
                    device: LanDevice {
                        id: "viewer-1".to_string(),
                        name: "Receiver".to_string(),
                        token: "token".to_string(),
                        device_type: "pc_receiver".to_string(),
                    },
                    sender,
                    workspace_subscribed: false,
                    pane_subscriptions: HashSet::new(),
                },
            );
        }
        state
            .route_viewer_message(
                "viewer-1",
                protocol_message("layout.snapshot", None, None, json!({})),
            )
            .await;
        let reply = receiver.recv().await.expect("permission error reply");
        let Message::Text(text) = reply else {
            panic!("expected text reply")
        };
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value.get("type").and_then(Value::as_str), Some("error"));
    }

    #[tokio::test]
    async fn owner_messages_are_cached_and_filtered_by_subscription() {
        let state = LanDirectState::default();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        {
            let mut inner = state.inner.lock().await;
            inner.running = true;
            inner.connections.insert(
                "viewer-1".to_string(),
                ViewerConnection {
                    connection_id: "connection-1".to_string(),
                    device: LanDevice {
                        id: "viewer-1".to_string(),
                        name: "Receiver".to_string(),
                        token: "token".to_string(),
                        device_type: "pc_receiver".to_string(),
                    },
                    sender,
                    workspace_subscribed: true,
                    pane_subscriptions: HashSet::from(["1\u{1f}base64+cells-json".to_string()]),
                },
            );
        }
        let layout = protocol_message("layout.snapshot", Some("owner:default"), None, json!({}));
        assert!(state.publish_owner_message(layout).await);
        assert!(matches!(receiver.recv().await, Some(Message::Text(_))));

        let vt = protocol_message(
            "screen.delta",
            Some("owner:default"),
            Some("1"),
            json!({ "encoding": "base64+vt", "data": "YQ==" }),
        );
        assert!(state.publish_owner_message(vt).await);
        assert!(receiver.try_recv().is_err());

        let cells = protocol_message(
            "screen.delta",
            Some("owner:default"),
            Some("1"),
            json!({ "encoding": "base64+cells-json", "data": "e30=" }),
        );
        assert!(state.publish_owner_message(cells).await);
        assert!(matches!(receiver.recv().await, Some(Message::Text(_))));
    }

    #[tokio::test]
    async fn workspace_subscribe_replays_layout_then_cached_pane_meta() {
        let state = LanDirectState::default();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        {
            let mut inner = state.inner.lock().await;
            inner.running = true;
            inner.connections.insert(
                "viewer-1".to_string(),
                ViewerConnection {
                    connection_id: "connection-1".to_string(),
                    device: LanDevice {
                        id: "viewer-1".to_string(),
                        name: "Receiver".to_string(),
                        token: "token".to_string(),
                        device_type: "pc_receiver".to_string(),
                    },
                    sender,
                    workspace_subscribed: false,
                    pane_subscriptions: HashSet::new(),
                },
            );
        }

        let layout = protocol_message(
            "layout.snapshot",
            Some("owner:default"),
            None,
            json!({
                "snapshot": {
                    "tabs": [{
                        "tab_id": "tab-1",
                        "panes": [{ "pane_id": "pane-1", "session_id": "session-1" }]
                    }]
                }
            }),
        );
        let pane_meta = protocol_message(
            "pane.meta",
            Some("owner:default"),
            Some("pane-1"),
            json!({ "activity": "running", "task_state": "running" }),
        );
        assert!(state.publish_owner_message(layout).await);
        assert!(state.publish_owner_message(pane_meta).await);
        assert!(receiver.try_recv().is_err());

        state
            .route_viewer_message(
                "viewer-1",
                protocol_message(
                    "workspace.subscribe",
                    Some("owner:default"),
                    None,
                    json!({}),
                ),
            )
            .await;

        let Message::Text(layout_text) = receiver.recv().await.expect("layout replay") else {
            panic!("expected layout text message")
        };
        let Message::Text(meta_text) = receiver.recv().await.expect("pane metadata replay") else {
            panic!("expected pane metadata text message")
        };
        let replayed_layout: Value = serde_json::from_str(&layout_text).unwrap();
        let replayed_meta: Value = serde_json::from_str(&meta_text).unwrap();
        assert_eq!(
            replayed_layout.get("type").and_then(Value::as_str),
            Some("layout.snapshot")
        );
        assert_eq!(
            replayed_meta.get("type").and_then(Value::as_str),
            Some("pane.meta")
        );
        assert_eq!(
            replayed_meta.get("pane_id").and_then(Value::as_str),
            Some("pane-1")
        );
    }

    #[tokio::test]
    async fn layout_removes_cached_metadata_for_closed_panes() {
        let state = LanDirectState::default();
        {
            let mut inner = state.inner.lock().await;
            inner.running = true;
        }
        let layout_with_pane = protocol_message(
            "layout.snapshot",
            Some("owner:default"),
            None,
            json!({ "snapshot": { "tabs": [{ "panes": [{ "pane_id": "pane-1" }] }] } }),
        );
        let empty_layout = protocol_message(
            "layout.patch",
            Some("owner:default"),
            None,
            json!({ "snapshot": { "tabs": [] } }),
        );
        let pane_meta = protocol_message(
            "pane.meta",
            Some("owner:default"),
            Some("pane-1"),
            json!({ "activity": "running" }),
        );

        assert!(state.publish_owner_message(layout_with_pane).await);
        assert!(state.publish_owner_message(pane_meta).await);
        assert_eq!(state.inner.lock().await.pane_meta.len(), 1);
        assert!(state.publish_owner_message(empty_layout).await);
        assert!(state.inner.lock().await.pane_meta.is_empty());
    }

    #[tokio::test]
    async fn sender_can_clear_all_paired_receivers() {
        let state = LanDirectState::default();
        let (sender, mut receiver) = mpsc::unbounded_channel();
        {
            let mut inner = state.inner.lock().await;
            let device = LanDevice {
                id: "viewer-1".to_string(),
                name: "Receiver".to_string(),
                token: "token".to_string(),
                device_type: "pc_receiver".to_string(),
            };
            inner
                .paired_devices
                .insert(device.token.clone(), device.clone());
            inner.connections.insert(
                device.id.clone(),
                ViewerConnection {
                    connection_id: "connection-1".to_string(),
                    device,
                    sender,
                    workspace_subscribed: false,
                    pane_subscriptions: HashSet::new(),
                },
            );
        }

        let status = state.clear_paired_receivers().await.unwrap();
        assert_eq!(status.paired_receivers, 0);
        assert_eq!(status.connected_receivers, 0);
        assert!(matches!(receiver.recv().await, Some(Message::Close(None))));
    }

    #[tokio::test]
    async fn loopback_pairing_and_websocket_auth_work_end_to_end() {
        let state = LanDirectState::default();
        {
            let mut inner = state.inner.lock().await;
            inner.running = true;
            inner.port = 7390;
            inner.pairing = Some(PairingCode {
                code: "123456".to_string(),
                expires_at: unix_seconds() + 300,
            });
        }
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, lan_router(state.clone()))
                .await
                .unwrap();
        });
        let client = reqwest::Client::new();
        let register: Value = client
            .post(format!("http://{address}/api/register"))
            .json(&json!({ "name": "Receiver", "type": "pc_receiver" }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        let token = register["device"]["token"].as_str().unwrap().to_string();
        let pairing: Value = client
            .post(format!("http://{address}/api/pairing/complete"))
            .json(&json!({ "token": token, "code": "123456" }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(pairing["success"], true);

        let (mut websocket, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
        websocket
            .send(tokio_tungstenite::tungstenite::Message::Text(
                json!({
                    "type": "auth",
                    "v": 3,
                    "payload": { "token": token, "supported_protocols": [3] }
                })
                .to_string(),
            ))
            .await
            .unwrap();
        let auth = websocket
            .next()
            .await
            .unwrap()
            .unwrap()
            .into_text()
            .unwrap();
        let auth: Value = serde_json::from_str(&auth).unwrap();
        assert_eq!(auth["type"], "auth_response");
        assert_eq!(auth["payload"]["success"], true);
        let peer_state = websocket
            .next()
            .await
            .unwrap()
            .unwrap()
            .into_text()
            .unwrap();
        let peer_state: Value = serde_json::from_str(&peer_state).unwrap();
        assert_eq!(peer_state["type"], "device.peer_state");

        let unbind: Value = client
            .post(format!("http://{address}/api/pairing/unbind"))
            .json(&json!({ "token": token }))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(unbind["success"], true);
        assert_eq!(unbind["removed"], true);
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(2), websocket.next())
                .await
                .unwrap(),
            Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_)))
        ));

        let (mut rejected, _) = connect_async(format!("ws://{address}/ws")).await.unwrap();
        rejected
            .send(tokio_tungstenite::tungstenite::Message::Text(
                json!({
                    "type": "auth",
                    "v": 3,
                    "payload": { "token": token, "supported_protocols": [3] }
                })
                .to_string(),
            ))
            .await
            .unwrap();
        let auth = rejected.next().await.unwrap().unwrap().into_text().unwrap();
        let auth: Value = serde_json::from_str(&auth).unwrap();
        assert_eq!(auth["payload"]["success"], false);
        task.abort();
    }
}
