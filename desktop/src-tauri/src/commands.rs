use std::collections::HashMap;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{command, AppHandle, State};
use uuid::Uuid;

use crate::api_client::{self, PairingCodeResponse, RegisterDeviceResponse};
use crate::pty_manager::{PtyManager, SessionDescriptor};
use crate::wss_client::{ServerStatusSnapshot, WssClientState};

#[derive(Debug, Clone, Serialize)]
pub struct AiProxyResponse {
    pub ok: bool,
    pub status: u16,
    pub body: Value,
}

fn require_session_id(session_id: String) -> Result<String, String> {
    if session_id.trim().is_empty() {
        return Err("session_id is required".to_string());
    }
    Ok(session_id)
}

fn require_input(input: Option<String>, data: Option<String>) -> Result<String, String> {
    input
        .or(data)
        .ok_or_else(|| "input or data is required".to_string())
}

#[command]
pub async fn connect_server(
    url: String,
    token: String,
    app: AppHandle,
    state: State<'_, WssClientState>,
    pty_manager: State<'_, PtyManager>,
) -> Result<String, String> {
    state
        .connect(app, pty_manager.inner().clone(), url, token)
        .await?;
    Ok("Connecting".to_string())
}

#[command]
pub async fn disconnect_server(
    app: AppHandle,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state.disconnect(&app).await;
    Ok("Disconnected".to_string())
}

#[command]
pub async fn create_session(
    cols: u16,
    rows: u16,
    app: AppHandle,
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
    session_id: Option<String>,
    title: Option<String>,
    shell: Option<String>,
    cwd: Option<String>,
) -> Result<String, String> {
    let session_id = session_id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let title = title.unwrap_or_else(|| "Terminal".to_string());
    crate::log_debug(&format!(
        "command:create_session session={} title={} shell={:?} cwd={:?}",
        session_id, title, shell, cwd
    ));

    let session_id = pty_manager.create_session(
        &app,
        session_id,
        cols,
        rows,
        Some(title.clone()),
        shell,
        cwd,
    )?;
    // 检查WebSocket连接状态，如果已连接则发送会话创建消息
    if wss_state.is_connected() {
        let result = wss_state
            .send_session_create(&session_id, &title, cols, rows)
            .await;
        if let Err(e) = result {
            log::warn!("Failed to send session create: {}", e);
        }
    } else {
        log::info!("WebSocket not connected, will send session create after connection is established");
    }

    Ok(session_id)
}

#[command]
pub async fn close_session(
    session_id: String,
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    pty_manager.close_session(&session_id)?;
    let _ = wss_state.send_session_close(&session_id).await;
    Ok("Session closed".to_string())
}

#[command]
pub async fn send_input(
    session_id: String,
    input: Option<String>,
    data: Option<String>,
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    let input = require_input(input, data)?;
    crate::log_debug(&format!(
        "command:send_input session={} bytes={}",
        session_id,
        input.len()
    ));

    if pty_manager.has_session(&session_id) {
        pty_manager.write_input(&session_id, input.as_bytes())?;
    } else {
        wss_state.send_terminal_input(&session_id, &input).await?;
    }

    Ok("Input sent".to_string())
}

#[command]
pub async fn resize_terminal_cmd(
    session_id: String,
    cols: u16,
    rows: u16,
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;

    if pty_manager.has_session(&session_id) {
        pty_manager.resize(&session_id, cols, rows)?;
    }
    let _ = wss_state
        .send_terminal_resize(&session_id, cols, rows)
        .await;

    Ok("Terminal resized".to_string())
}

#[command]
pub async fn subscribe_session(
    session_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .subscribe_session(&require_session_id(session_id)?)
        .await?;
    Ok("Subscribed".to_string())
}

#[command]
pub async fn unsubscribe_session(
    session_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .unsubscribe_session(&require_session_id(session_id)?)
        .await?;
    Ok("Unsubscribed".to_string())
}

#[command]
pub async fn relay_terminal_output(
    session_id: String,
    data: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .send_terminal_output(&require_session_id(session_id)?, &data)
        .await?;
    Ok("Output relayed".to_string())
}

#[command]
pub async fn request_terminal_replay(
    session_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .send_terminal_replay_request(&require_session_id(session_id)?)
        .await?;
    Ok("Replay requested".to_string())
}

#[command]
pub async fn relay_terminal_replay(
    session_id: String,
    target_device_id: String,
    data: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    if target_device_id.trim().is_empty() {
        return Err("target_device_id is required".to_string());
    }
    state
        .send_terminal_replay(&session_id, target_device_id.trim(), &data)
        .await?;
    Ok("Replay relayed".to_string())
}

#[command]
pub async fn update_session_meta(
    session_id: String,
    activity: Option<String>,
    preview: Option<String>,
    task_state: Option<String>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    crate::log_debug(&format!(
        "command:update_session_meta session={} task_state={:?} activity={:?}",
        session_id, task_state, activity
    ));
    state
        .send_session_update(
            &session_id,
            activity.as_deref(),
            preview.as_deref(),
            task_state.as_deref(),
        )
        .await?;
    Ok("Session metadata updated".to_string())
}

#[command]
pub async fn sync_active_sessions(
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
) -> Result<String, String> {
    for session in pty_manager.describe_sessions() {
        wss_state
            .send_session_create(
                &session.session_id,
                &session.title,
                session.cols,
                session.rows,
            )
            .await?;
    }
    Ok("Active sessions synced".to_string())
}

#[command]
pub fn list_local_sessions(
    pty_manager: State<'_, PtyManager>,
) -> Result<Vec<SessionDescriptor>, String> {
    Ok(pty_manager.describe_sessions())
}

#[command]
pub async fn get_server_status(
    state: State<'_, WssClientState>,
) -> Result<ServerStatusSnapshot, String> {
    Ok(state.status_snapshot().await)
}

#[command]
pub async fn register_device(
    server_url: String,
    name: String,
    device_type: String,
) -> Result<RegisterDeviceResponse, String> {
    api_client::register_device(server_url, name, device_type).await
}

#[command]
pub async fn generate_pairing_code(
    server_url: String,
    token: String,
) -> Result<PairingCodeResponse, String> {
    api_client::generate_pairing_code(server_url, token).await
}

#[command]
pub fn debug_log(message: String) -> Result<String, String> {
    crate::log_debug(&format!("frontend:{message}"));
    Ok("logged".to_string())
}

#[command]
pub async fn proxy_ai_request(
    url: String,
    headers: Option<HashMap<String, String>>,
    body: Value,
) -> Result<AiProxyResponse, String> {
    let url = url.trim();
    if url.is_empty() {
        return Err("AI request URL is required".to_string());
    }

    let mut header_map = HeaderMap::new();
    if let Some(headers) = headers {
        for (name, value) in headers {
            let value = value.trim();
            if value.is_empty() {
                continue;
            }

            let header_name = HeaderName::from_bytes(name.trim().as_bytes())
                .map_err(|err| format!("Invalid AI request header `{name}`: {err}"))?;
            let header_value = HeaderValue::from_str(value)
                .map_err(|err| format!("Invalid AI request header value for `{name}`: {err}"))?;
            header_map.insert(header_name, header_value);
        }
    }

    crate::log_debug(&format!("command:proxy_ai_request url={url}"));

    let client = reqwest::Client::builder()
        .use_rustls_tls()
        .timeout(Duration::from_secs(90))
        .build()
        .map_err(|err| format!("Failed to build AI request client: {err}"))?;

    let response = client
        .post(url)
        .headers(header_map)
        .json(&body)
        .send()
        .await
        .map_err(|err| format!("AI request failed: {err}"))?;

    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|err| format!("Failed to read AI response: {err}"))?;
    let parsed = serde_json::from_str::<Value>(&text)
        .unwrap_or_else(|_| json!({ "message": text }));

    crate::log_debug(&format!(
        "command:proxy_ai_request:done status={}",
        status.as_u16()
    ));

    Ok(AiProxyResponse {
        ok: status.is_success(),
        status: status.as_u16(),
        body: parsed,
    })
}
