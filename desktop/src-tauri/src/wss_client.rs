use crate::lan_direct::LanDirectState;
use crate::pty_manager::PtyManager;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use futures::{SinkExt, StreamExt};
use rustls::{Certificate, ClientConfig, RootCertStore};
use serde::Serialize;
use serde_json::{json, Value};
use std::io::Cursor;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};
use tokio::sync::{mpsc, Mutex};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};
use tokio_tungstenite::{connect_async_tls_with_config, Connector};

#[derive(Clone, Serialize)]
pub struct ServerStatusPayload {
    pub state: String,
    pub server_url: Option<String>,
    pub device_id: Option<String>,
    pub message: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct ServerMessagePayload {
    #[serde(rename = "type")]
    pub event_type: String,
    pub id: Option<String>,
    pub workspace_id: Option<String>,
    pub pane_id: Option<String>,
    pub session_id: Option<String>,
    pub payload: Value,
}

#[derive(Clone, Serialize)]
pub struct ServerStatusSnapshot {
    pub connected: bool,
    pub server_url: Option<String>,
    pub device_id: Option<String>,
}

enum OutboundMessage {
    Json(Value),
    Close,
}

#[derive(Default)]
struct InnerState {
    connected: bool,
    server_url: Option<String>,
    device_id: Option<String>,
    connection_id: Option<String>,
    selected_protocol: Option<u8>,
    sender: Option<mpsc::UnboundedSender<OutboundMessage>>,
    task: Option<JoinHandle<()>>,
}

#[derive(Clone)]
pub struct WssClientState {
    inner: Arc<Mutex<InnerState>>,
    client_instance_id: Arc<String>,
    connection_generation: Arc<AtomicU64>,
    lan_direct: LanDirectState,
}

impl WssClientState {
    pub fn new(lan_direct: LanDirectState) -> Self {
        Self {
            inner: Arc::new(Mutex::new(InnerState::default())),
            client_instance_id: Arc::new(format!("desktop-{}", uuid::Uuid::new_v4())),
            connection_generation: Arc::new(AtomicU64::new(0)),
            lan_direct,
        }
    }

    pub async fn connect(
        &self,
        app: AppHandle,
        pty_manager: PtyManager,
        url: String,
        token: String,
    ) -> Result<(), String> {
        crate::log_debug(&format!(
            "wss:connect:start url={} token_len={}",
            url,
            token.len()
        ));
        self.disconnect_internal(None).await;

        let mut request = url
            .as_str()
            .into_client_request()
            .map_err(|e| format!("Invalid websocket URL: {e}"))?;
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            "termsync-protocol".parse().unwrap(),
        );

        self.emit_status(&app, "connecting", Some(url.clone()), None, None);

        let connector = Self::build_connector()?;
        crate::log_debug(&format!("wss:connect:tls-ready url={}", url));
        let (stream, _) = connect_async_tls_with_config(request, None, false, Some(connector))
            .await
            .map_err(|e| {
                crate::log_debug(&format!("wss:connect:error url={} error={}", url, e));
                format!("Failed to connect: {e}")
            })?;
        crate::log_debug(&format!("wss:connect:open url={}", url));

        let (tx, mut rx) = mpsc::unbounded_channel();
        let (mut writer, mut reader) = stream.split();
        let app_handle = app.clone();
        let state = self.clone();
        let url_for_task = url.clone();
        let client_instance_id = self.client_instance_id.as_ref().clone();
        let connection_generation = self.connection_generation.fetch_add(1, Ordering::SeqCst) + 1;

        let task = tokio::spawn(async move {
            let auth_msg = json!({
                "type": "auth",
                "v": 3,
                "timestamp": current_timestamp(),
                "payload": {
                    "token": token,
                    "client_instance_id": client_instance_id,
                    "connection_generation": connection_generation,
                    "supported_protocols": [3]
                }
            });
            crate::log_debug(&format!(
                "wss:auth:send url={} token_len={}",
                url_for_task,
                auth_msg["payload"]["token"]
                    .as_str()
                    .map(|v| v.len())
                    .unwrap_or_default()
            ));
            if let Err(err) = writer.send(Message::Text(auth_msg.to_string())).await {
                crate::log_debug(&format!(
                    "wss:auth:send:error url={} error={}",
                    url_for_task, err
                ));
                state.emit_status(
                    &app_handle,
                    "disconnected",
                    Some(url_for_task.clone()),
                    None,
                    Some(format!("Failed to send auth message: {err}")),
                );
                state.reset_runtime().await;
                return;
            }

            loop {
                tokio::select! {
                    outbound = rx.recv() => {
                        match outbound {
                            Some(OutboundMessage::Json(value)) => {
                                crate::log_debug(&format!(
                                    "wss:outbound:type={} session={}",
                                    message_type(&value),
                                    value.get("session_id").and_then(Value::as_str).unwrap_or("-")
                                ));
                                if writer.send(Message::Text(value.to_string())).await.is_err() {
                                    crate::log_debug("wss:outbound:send:error");
                                    break;
                                }
                            }
                            Some(OutboundMessage::Close) | None => {
                                crate::log_debug(&format!("wss:close:requested url={}", url_for_task));
                                let _ = writer.send(Message::Close(None)).await;
                                break;
                            }
                        }
                    }
                    incoming = reader.next() => {
                        match incoming {
                            Some(Ok(Message::Text(text))) => {
                                state.handle_incoming_text(&app_handle, &pty_manager, text, &url_for_task).await;
                            }
                            Some(Ok(Message::Ping(payload))) => {
                                crate::log_debug(&format!(
                                    "wss:ping size={} url={}",
                                    payload.len(),
                                    url_for_task
                                ));
                                if writer.send(Message::Pong(payload)).await.is_err() {
                                    crate::log_debug("wss:pong:send:error");
                                    break;
                                }
                            }
                            Some(Ok(Message::Close(frame))) => {
                                crate::log_debug(&format!("wss:close:received url={} frame={:?}", url_for_task, frame));
                                break;
                            }
                            None => {
                                crate::log_debug(&format!("wss:stream:eof url={}", url_for_task));
                                break;
                            }
                            Some(Ok(_)) => {}
                            Some(Err(err)) => {
                                crate::log_debug(&format!(
                                    "wss:stream:error url={} error={}",
                                    url_for_task, err
                                ));
                                state.emit_status(
                                    &app_handle,
                                    "disconnected",
                                    Some(url_for_task.clone()),
                                    None,
                                    Some(format!("WebSocket error: {err}")),
                                );
                                break;
                            }
                        }
                    }
                }
            }

            state.reset_runtime().await;
            crate::log_debug(&format!("wss:task:end url={}", url_for_task));
            state.emit_status(
                &app_handle,
                "disconnected",
                Some(url_for_task),
                None,
                Some("Connection closed".to_string()),
            );
        });

        let mut inner = self.inner.lock().await;
        inner.server_url = Some(url);
        inner.sender = Some(tx);
        inner.task = Some(task);
        Ok(())
    }

    pub async fn disconnect(&self, app: &AppHandle) {
        self.disconnect_internal(Some(app)).await;
    }

    pub async fn send_layout_snapshot(
        &self,
        workspace_id: &str,
        snapshot: Value,
        layout_version: Option<i64>,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "layout.snapshot",
            Some(workspace_id),
            None,
            None,
            json!({
                "layout_version": layout_version.unwrap_or_else(current_timestamp_millis_i64),
                "snapshot": snapshot
            }),
        ))
        .await
    }

    pub async fn send_layout_patch(
        &self,
        workspace_id: &str,
        snapshot: Value,
        layout_version: Option<i64>,
        reason: Option<&str>,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "layout.patch",
            Some(workspace_id),
            None,
            None,
            json!({
                "layout_version": layout_version.unwrap_or_else(current_timestamp_millis_i64),
                "reason": reason.unwrap_or("layout_change"),
                "snapshot": snapshot
            }),
        ))
        .await
    }

    pub async fn send_pane_meta(
        &self,
        workspace_id: &str,
        pane_id: &str,
        session_id: Option<&str>,
        payload: Value,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "pane.meta",
            Some(workspace_id),
            Some(pane_id),
            session_id,
            payload,
        ))
        .await
    }

    pub async fn send_layout_action_request(
        &self,
        workspace_id: &str,
        action: &str,
        payload: Option<Value>,
    ) -> Result<(), String> {
        let mut body = match payload {
            Some(Value::Object(map)) => map,
            _ => serde_json::Map::new(),
        };
        body.insert("action".to_string(), Value::String(action.to_string()));
        self.send_json(v3_message(
            "layout.action_request",
            Some(workspace_id),
            None,
            None,
            Value::Object(body),
        ))
        .await
    }

    pub async fn subscribe_workspace(&self, workspace_id: &str) -> Result<(), String> {
        self.send_json(v3_message(
            "workspace.subscribe",
            Some(workspace_id),
            None,
            None,
            json!({ "workspace_id": workspace_id }),
        ))
        .await
    }

    pub async fn subscribe_screen(
        &self,
        workspace_id: &str,
        pane_id: &str,
        encoding: &str,
    ) -> Result<(), String> {
        let encoding = normalize_screen_encoding(encoding);
        self.send_json(v3_message(
            "screen.subscribe",
            Some(workspace_id),
            Some(pane_id),
            None,
            json!({
                "pane_id": pane_id,
                "encoding": encoding
            }),
        ))
        .await
    }

    pub async fn unsubscribe_screen(
        &self,
        workspace_id: &str,
        pane_id: &str,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "screen.unsubscribe",
            Some(workspace_id),
            Some(pane_id),
            None,
            json!({ "pane_id": pane_id }),
        ))
        .await
    }

    pub async fn send_screen_delta(
        &self,
        workspace_id: &str,
        pane_id: &str,
        session_id: &str,
        seq: i64,
        prev_seq: i64,
        encoding: &str,
        data: &str,
    ) -> Result<(), String> {
        let encoding = normalize_screen_encoding(encoding);
        self.send_json(v3_message(
            "screen.delta",
            Some(workspace_id),
            Some(pane_id),
            Some(session_id),
            json!({
                "stream_id": format!("{session_id}:1"),
                "seq": seq,
                "prev_seq": prev_seq,
                "encoding": encoding,
                "data": BASE64.encode(data.as_bytes())
            }),
        ))
        .await
    }

    pub async fn send_screen_snapshot(
        &self,
        workspace_id: &str,
        pane_id: &str,
        session_id: &str,
        snapshot_seq: i64,
        encoding: &str,
        data: &str,
    ) -> Result<(), String> {
        let encoding = normalize_screen_encoding(encoding);
        self.send_json(v3_message(
            "screen.snapshot",
            Some(workspace_id),
            Some(pane_id),
            Some(session_id),
            json!({
                "stream_id": format!("{session_id}:1"),
                "snapshot_seq": snapshot_seq,
                "encoding": encoding,
                "data": BASE64.encode(data.as_bytes())
            }),
        ))
        .await
    }

    pub async fn send_screen_history_response(
        &self,
        workspace_id: &str,
        pane_id: &str,
        session_id: &str,
        request_id: &str,
        target_device_id: &str,
        encoding: &str,
        data: &str,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "screen.history_response",
            Some(workspace_id),
            Some(pane_id),
            Some(session_id),
            json!({
                "request_id": request_id,
                "target_device_id": target_device_id,
                "encoding": normalize_screen_encoding(encoding),
                "data": BASE64.encode(data.as_bytes())
            }),
        ))
        .await
    }

    pub async fn send_screen_resync_request(
        &self,
        workspace_id: &str,
        pane_id: &str,
        last_seq: i64,
        encoding: &str,
    ) -> Result<(), String> {
        let encoding = normalize_screen_encoding(encoding);
        self.send_json(v3_message(
            "screen.resync_request",
            Some(workspace_id),
            Some(pane_id),
            None,
            json!({
                "pane_id": pane_id,
                "last_seq": last_seq,
                "encoding": encoding
            }),
        ))
        .await
    }

    pub async fn send_screen_ack(
        &self,
        workspace_id: &str,
        pane_id: &str,
        ack_seq: i64,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "screen.ack",
            Some(workspace_id),
            Some(pane_id),
            None,
            json!({
                "pane_id": pane_id,
                "ack_seq": ack_seq
            }),
        ))
        .await
    }

    pub async fn send_input_send(
        &self,
        workspace_id: &str,
        pane_id: &str,
        session_id: Option<&str>,
        data: &str,
        input_id: &str,
    ) -> Result<(), String> {
        self.send_json(v3_message(
            "input.send",
            Some(workspace_id),
            Some(pane_id),
            session_id,
            json!({
                "input_id": input_id,
                "encoding": "base64",
                "mode": "raw",
                "data": BASE64.encode(data.as_bytes())
            }),
        ))
        .await
    }

    pub async fn status_snapshot(&self) -> ServerStatusSnapshot {
        let inner = self.inner.lock().await;
        ServerStatusSnapshot {
            connected: inner.connected,
            server_url: inner.server_url.clone(),
            device_id: inner.device_id.clone(),
        }
    }

    async fn handle_incoming_text(
        &self,
        app: &AppHandle,
        _pty_manager: &PtyManager,
        text: String,
        server_url: &str,
    ) {
        let Ok(value) = serde_json::from_str::<Value>(&text) else {
            crate::log_debug(&format!("wss:incoming:invalid-json text={}", text));
            self.emit_status(
                app,
                "disconnected",
                Some(server_url.to_string()),
                None,
                Some("Received invalid JSON from server".to_string()),
            );
            return;
        };

        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let session_id = value
            .get("session_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let message_id = value
            .get("id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let workspace_id = value
            .get("workspace_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let pane_id = value
            .get("pane_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let payload = value.get("payload").cloned().unwrap_or(Value::Null);
        crate::log_debug(&format!(
            "wss:incoming:type={} session={}",
            event_type,
            session_id.as_deref().unwrap_or("-")
        ));

        match event_type.as_str() {
            "auth_response" => {
                let success = payload
                    .get("success")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let device_id = payload
                    .get("device_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                let connection_id = payload
                    .get("connection_id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                let selected_protocol = payload
                    .get("selected_protocol")
                    .and_then(Value::as_u64)
                    .map(|value| value as u8);
                crate::log_debug(&format!(
                    "wss:auth:response success={} device_id={:?} protocol={:?} connection_id={:?} message={:?}",
                    success,
                    device_id,
                    selected_protocol,
                    connection_id,
                    payload.get("message").and_then(Value::as_str)
                ));

                let mut inner = self.inner.lock().await;
                inner.connected = success;
                inner.device_id = device_id.clone();
                inner.connection_id = connection_id;
                inner.selected_protocol = selected_protocol;
                drop(inner);

                self.emit_status(
                    app,
                    if success { "connected" } else { "disconnected" },
                    Some(server_url.to_string()),
                    device_id,
                    payload
                        .get("message")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                );
            }
            "peer.replaced" => {
                crate::log_debug(&format!("wss:peer:replaced payload={}", payload));
                self.reset_runtime().await;
                self.emit_status(
                    app,
                    "disconnected",
                    Some(server_url.to_string()),
                    None,
                    Some("Connection replaced by another client instance".to_string()),
                );
            }
            _ => {}
        }

        if event_type != "heartbeat" {
            let _ = app.emit(
                "server-message",
                ServerMessagePayload {
                    event_type,
                    id: message_id,
                    workspace_id,
                    pane_id,
                    session_id,
                    payload,
                },
            );
        }
    }

    async fn send_json(&self, value: Value) -> Result<(), String> {
        crate::log_debug(&format!(
            "wss:queue:type={} session={}",
            message_type(&value),
            value
                .get("session_id")
                .and_then(Value::as_str)
                .unwrap_or("-")
        ));
        let lan_available = self.lan_direct.publish_owner_message(value.clone()).await;
        let sender = {
            let inner = self.inner.lock().await;
            if !inner.connected {
                if lan_available {
                    return Ok(());
                }
                return Err("Server is not connected".to_string());
            }
            inner.sender.clone()
        };

        match sender {
            Some(sender) => sender
                .send(OutboundMessage::Json(value))
                .map_err(|_| "Failed to queue websocket message".to_string()),
            None if lan_available => Ok(()),
            None => Err("Server is not connected".to_string()),
        }
    }

    async fn disconnect_internal(&self, app: Option<&AppHandle>) {
        let (sender, task, server_url) = {
            let mut inner = self.inner.lock().await;
            let sender = inner.sender.take();
            let task = inner.task.take();
            inner.connected = false;
            inner.device_id = None;
            (sender, task, inner.server_url.clone())
        };
        crate::log_debug(&format!(
            "wss:disconnect_internal url={:?} emit_status={}",
            server_url,
            app.is_some()
        ));

        if let Some(sender) = sender {
            let _ = sender.send(OutboundMessage::Close);
        }

        if let Some(task) = task {
            task.abort();
        }

        if let Some(app) = app {
            self.emit_status(
                app,
                "disconnected",
                server_url,
                None,
                Some("Disconnected".to_string()),
            );
        }
    }

    async fn reset_runtime(&self) {
        let mut inner = self.inner.lock().await;
        inner.connected = false;
        inner.device_id = None;
        inner.connection_id = None;
        inner.selected_protocol = None;
        inner.sender = None;
        inner.task = None;
        crate::log_debug("wss:runtime:reset");
    }

    fn emit_status(
        &self,
        app: &AppHandle,
        state: &str,
        server_url: Option<String>,
        device_id: Option<String>,
        message: Option<String>,
    ) {
        crate::log_debug(&format!(
            "wss:status state={} url={:?} device_id={:?} message={:?}",
            state, server_url, device_id, message
        ));
        let _ = app.emit(
            "server-status",
            ServerStatusPayload {
                state: state.to_string(),
                server_url,
                device_id,
                message,
            },
        );
    }

    fn build_connector() -> Result<Connector, String> {
        let mut root_store = RootCertStore::empty();

        if let Ok(native_certs) = rustls_native_certs::load_native_certs() {
            for cert in native_certs {
                let _ = root_store.add(&Certificate(cert.0));
            }
        }

        let mut reader = Cursor::new(&include_bytes!("../../assets/server.crt")[..]);
        let bundled_certs = rustls_pemfile::certs(&mut reader)
            .map_err(|e| format!("Failed to read bundled certificate: {e}"))?;
        for cert in bundled_certs {
            let _ = root_store.add(&Certificate(cert));
        }

        let config = ClientConfig::builder()
            .with_safe_defaults()
            .with_root_certificates(root_store)
            .with_no_client_auth();

        Ok(Connector::Rustls(Arc::new(config)))
    }
}

fn current_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn current_timestamp_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

fn current_timestamp_millis_i64() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

fn message_type(value: &Value) -> &str {
    value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
}

fn v3_message(
    message_type: &str,
    workspace_id: Option<&str>,
    pane_id: Option<&str>,
    session_id: Option<&str>,
    payload: Value,
) -> Value {
    let mut message = serde_json::Map::new();
    message.insert("type".to_string(), Value::String(message_type.to_string()));
    message.insert("v".to_string(), json!(3));
    message.insert("id".to_string(), Value::String(new_client_message_id()));
    message.insert("timestamp".to_string(), json!(current_timestamp()));
    if let Some(workspace_id) = workspace_id.filter(|value| !value.is_empty()) {
        message.insert(
            "workspace_id".to_string(),
            Value::String(workspace_id.to_string()),
        );
    }
    if let Some(pane_id) = pane_id.filter(|value| !value.is_empty()) {
        message.insert("pane_id".to_string(), Value::String(pane_id.to_string()));
    }
    if let Some(session_id) = session_id.filter(|value| !value.is_empty()) {
        message.insert(
            "session_id".to_string(),
            Value::String(session_id.to_string()),
        );
    }
    if !payload.is_null() {
        message.insert("payload".to_string(), payload);
    }
    Value::Object(message)
}

fn normalize_screen_encoding(encoding: &str) -> &'static str {
    match encoding {
        "base64+cells-json" | "cells" | "cells-json" => "base64+cells-json",
        _ => "base64+vt",
    }
}

fn new_client_message_id() -> String {
    static NEXT_MESSAGE_ID: AtomicU64 = AtomicU64::new(1);
    let seq = NEXT_MESSAGE_ID.fetch_add(1, Ordering::Relaxed);
    format!("desktop-{}-{}", current_timestamp_millis(), seq)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn owner_message_is_sent_to_cloud_and_lan() {
        let lan_direct = LanDirectState::default();
        let mut lan_receiver = lan_direct.add_test_receiver().await;
        let state = WssClientState::new(lan_direct);
        let (cloud_sender, mut cloud_receiver) = mpsc::unbounded_channel();
        {
            let mut inner = state.inner.lock().await;
            inner.connected = true;
            inner.sender = Some(cloud_sender);
        }

        state
            .send_pane_meta(
                "owner:default",
                "pane-1",
                Some("session-1"),
                json!({ "activity": "running", "task_state": "running" }),
            )
            .await
            .expect("pane metadata dual publish should succeed");

        let Some(OutboundMessage::Json(cloud_message)) = cloud_receiver.recv().await else {
            panic!("expected cloud JSON message")
        };
        assert_eq!(
            cloud_message.get("type").and_then(Value::as_str),
            Some("pane.meta")
        );
        let Some(axum::extract::ws::Message::Text(lan_text)) = lan_receiver.recv().await else {
            panic!("expected LAN text message")
        };
        let lan_message: Value = serde_json::from_str(&lan_text).unwrap();
        assert_eq!(
            lan_message.get("type").and_then(Value::as_str),
            Some("pane.meta")
        );
        assert_eq!(
            lan_message.get("pane_id").and_then(Value::as_str),
            Some("pane-1")
        );
    }
}
