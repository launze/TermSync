use crate::pty_manager::PtyManager;
use futures::{SinkExt, StreamExt};
use rustls::{Certificate, ClientConfig, RootCertStore};
use serde::Serialize;
use serde_json::{json, Value};
use std::io::Cursor;
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
    sender: Option<mpsc::UnboundedSender<OutboundMessage>>,
    task: Option<JoinHandle<()>>,
}

#[derive(Clone, Default)]
pub struct WssClientState {
    inner: Arc<Mutex<InnerState>>,
}

impl WssClientState {
    pub fn is_connected(&self) -> bool {
        // 使用try_lock来避免阻塞
        if let Ok(inner) = self.inner.try_lock() {
            inner.connected
        } else {
            false
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

        let task = tokio::spawn(async move {
            let auth_msg = json!({
                "type": "auth",
                "timestamp": current_timestamp(),
                "payload": { "token": token }
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

    pub async fn send_session_create(
        &self,
        session_id: &str,
        title: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), String> {
        self.send_json(json!({
            "type": "session.create",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": {
                "title": title,
                "cols": cols,
                "rows": rows
            }
        }))
        .await
    }

    pub async fn send_session_close(&self, session_id: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "session.close",
            "session_id": session_id,
            "timestamp": current_timestamp()
        }))
        .await
    }

    pub async fn send_terminal_output(&self, session_id: &str, data: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "terminal.output",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": { "data": data }
        }))
        .await
    }

    pub async fn send_terminal_input(&self, session_id: &str, data: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "terminal.input",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": { "data": data }
        }))
        .await
    }

    pub async fn send_terminal_resize(
        &self,
        session_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), String> {
        self.send_json(json!({
            "type": "terminal.resize",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": {
                "cols": cols,
                "rows": rows
            }
        }))
        .await
    }

    pub async fn send_terminal_replay_request(&self, session_id: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "terminal.replay_request",
            "session_id": session_id,
            "timestamp": current_timestamp()
        }))
        .await
    }

    pub async fn send_terminal_replay(
        &self,
        session_id: &str,
        target_device_id: &str,
        data: &str,
    ) -> Result<(), String> {
        self.send_json(json!({
            "type": "terminal.replay",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": {
                "target_device_id": target_device_id,
                "data": data
            }
        }))
        .await
    }

    pub async fn send_session_update(
        &self,
        session_id: &str,
        activity: Option<&str>,
        preview: Option<&str>,
        task_state: Option<&str>,
    ) -> Result<(), String> {
        let mut payload = serde_json::Map::new();
        if let Some(value) = activity {
            payload.insert("activity".to_string(), Value::String(value.to_string()));
        }
        if let Some(value) = preview {
            payload.insert("preview".to_string(), Value::String(value.to_string()));
        }
        if let Some(value) = task_state {
            payload.insert("task_state".to_string(), Value::String(value.to_string()));
        }

        self.send_json(json!({
            "type": "session.update",
            "session_id": session_id,
            "timestamp": current_timestamp(),
            "payload": payload
        }))
        .await
    }

    pub async fn subscribe_session(&self, session_id: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "session.subscribe",
            "session_id": session_id,
            "timestamp": current_timestamp()
        }))
        .await
    }

    pub async fn unsubscribe_session(&self, session_id: &str) -> Result<(), String> {
        self.send_json(json!({
            "type": "session.unsubscribe",
            "session_id": session_id,
            "timestamp": current_timestamp()
        }))
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
        pty_manager: &PtyManager,
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
                crate::log_debug(&format!(
                    "wss:auth:response success={} device_id={:?} message={:?}",
                    success,
                    device_id,
                    payload.get("message").and_then(Value::as_str)
                ));

                let mut inner = self.inner.lock().await;
                inner.connected = success;
                inner.device_id = device_id.clone();
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
            "terminal.input" => {
                if let (Some(session_id), Some(data)) = (
                    session_id.as_deref(),
                    payload.get("data").and_then(Value::as_str),
                ) {
                    crate::log_debug(&format!(
                        "wss:terminal:input session={} bytes={}",
                        session_id,
                        data.len()
                    ));
                    let _ = pty_manager.write_input(session_id, data.as_bytes());
                }
            }
            "terminal.resize" => {
                if let Some(session_id) = session_id.as_deref() {
                    let cols = payload.get("cols").and_then(Value::as_u64).unwrap_or(80) as u16;
                    let rows = payload.get("rows").and_then(Value::as_u64).unwrap_or(24) as u16;
                    crate::log_debug(&format!(
                        "wss:terminal:resize session={} cols={} rows={}",
                        session_id, cols, rows
                    ));
                    let _ = pty_manager.resize(session_id, cols, rows);
                }
            }
            "session.close" => {
                if let Some(session_id) = session_id.as_deref() {
                    crate::log_debug(&format!("wss:session:close session={}", session_id));
                    let _ = pty_manager.close_session(session_id);
                }
            }
            _ => {}
        }

        if event_type != "heartbeat" {
            let _ = app.emit(
                "server-message",
                ServerMessagePayload {
                    event_type,
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
        let sender = {
            let inner = self.inner.lock().await;
            if !inner.connected {
                return Err("Server is not connected".to_string());
            }
            inner.sender.clone()
        };

        sender
            .ok_or_else(|| "Server is not connected".to_string())?
            .send(OutboundMessage::Json(value))
            .map_err(|_| "Failed to queue websocket message".to_string())
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

fn message_type(value: &Value) -> &str {
    value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
}
