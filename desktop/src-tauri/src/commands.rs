use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use arboard::Clipboard;
use chrono::Local;
use image::{ColorType, ImageFormat};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sysinfo::System;
use tauri::{command, AppHandle, Manager, State};
use uuid::Uuid;

use crate::api_client::{
    self, CompletePairingResponse, PairingCodeResponse, RegisterDeviceResponse, ReleaseInfo,
};
use crate::pty_manager::{PtyManager, SessionDescriptor};
use crate::wss_client::{ServerStatusSnapshot, WssClientState};

#[derive(Debug, Clone, Serialize)]
pub struct AiProxyResponse {
    pub ok: bool,
    pub status: u16,
    pub body: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScreenDeltaPayload {
    pub workspace_id: String,
    pub pane_id: String,
    pub session_id: String,
    pub seq: i64,
    pub prev_seq: i64,
    pub encoding: Option<String>,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScreenSnapshotPayload {
    pub workspace_id: String,
    pub pane_id: String,
    pub session_id: String,
    pub snapshot_seq: i64,
    pub encoding: Option<String>,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScreenHistoryPayload {
    pub workspace_id: String,
    pub pane_id: String,
    pub session_id: String,
    pub request_id: String,
    pub target_device_id: String,
    pub encoding: Option<String>,
    pub data: String,
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
    layout: Option<Value>,
) -> Result<SessionDescriptor, String> {
    let session_id = session_id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let title = title.unwrap_or_else(|| "Terminal".to_string());
    crate::log_debug(&format!(
        "command:create_session session={} title={} shell={:?} cwd={:?}",
        session_id, title, shell, cwd
    ));

    let session = pty_manager.create_session(
        &app,
        session_id,
        cols,
        rows,
        Some(title.clone()),
        shell,
        cwd,
    )?;
    let _ = (wss_state, layout);

    Ok(session)
}

#[command]
pub async fn close_session(
    session_id: String,
    pty_manager: State<'_, PtyManager>,
    wss_state: State<'_, WssClientState>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    pty_manager.close_session(&session_id)?;
    let _ = wss_state;
    Ok("Session closed".to_string())
}

#[command]
pub async fn send_input(
    session_id: String,
    input: Option<String>,
    data: Option<String>,
    input_id: Option<String>,
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
        let _ = (wss_state, input_id);
        return Err("remote input must use input.send with workspace_id and pane_id".to_string());
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
    let _ = wss_state;

    Ok("Terminal resized".to_string())
}

#[command]
pub async fn update_session_meta(
    session_id: String,
    title: Option<String>,
    activity: Option<String>,
    preview: Option<String>,
    task_state: Option<String>,
    layout: Option<Value>,
    state: State<'_, WssClientState>,
    pty_manager: State<'_, PtyManager>,
) -> Result<String, String> {
    let session_id = require_session_id(session_id)?;
    let title = title.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    });
    crate::log_debug(&format!(
        "command:update_session_meta session={} title={:?} task_state={:?} activity={:?}",
        session_id, title, task_state, activity
    ));

    if let Some(ref value) = title {
        pty_manager.update_session_title(&session_id, value);
    }

    let _ = (state, activity, preview, task_state, layout);

    Ok("Session metadata updated".to_string())
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
pub fn get_default_device_name() -> Result<String, String> {
    let name = std::env::var("COMPUTERNAME")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .or_else(System::host_name)
        .map(|value| {
            value
                .trim()
                .chars()
                .filter(|ch| !ch.is_control())
                .collect::<String>()
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "TTY1 Desktop".to_string());
    Ok(name)
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
pub async fn complete_pairing(
    server_url: String,
    token: String,
    code: String,
) -> Result<CompletePairingResponse, String> {
    api_client::complete_pairing(server_url, token, code).await
}

#[command]
pub async fn publish_layout_snapshot(
    workspace_id: String,
    snapshot: Value,
    layout_version: Option<i64>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    if workspace_id.is_empty() {
        return Err("workspace_id is required".to_string());
    }
    state
        .send_layout_snapshot(workspace_id, snapshot, layout_version)
        .await?;
    Ok("Layout snapshot published".to_string())
}

#[command]
pub async fn publish_layout_patch(
    workspace_id: String,
    snapshot: Value,
    layout_version: Option<i64>,
    reason: Option<String>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    if workspace_id.is_empty() {
        return Err("workspace_id is required".to_string());
    }
    state
        .send_layout_patch(workspace_id, snapshot, layout_version, reason.as_deref())
        .await?;
    Ok("Layout patch published".to_string())
}

#[command]
pub async fn subscribe_workspace(
    workspace_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    if workspace_id.is_empty() {
        return Err("workspace_id is required".to_string());
    }
    state.subscribe_workspace(workspace_id).await?;
    Ok("Workspace subscribed".to_string())
}

#[command]
pub async fn subscribe_screen(
    workspace_id: String,
    pane_id: String,
    encoding: Option<String>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    let pane_id = pane_id.trim();
    if workspace_id.is_empty() || pane_id.is_empty() {
        return Err("workspace_id and pane_id are required".to_string());
    }
    state
        .subscribe_screen(
            workspace_id,
            pane_id,
            encoding.as_deref().unwrap_or("base64+vt"),
        )
        .await?;
    Ok("Screen subscribed".to_string())
}

#[command]
pub async fn unsubscribe_screen(
    workspace_id: String,
    pane_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    let pane_id = pane_id.trim();
    if workspace_id.is_empty() || pane_id.is_empty() {
        return Err("workspace_id and pane_id are required".to_string());
    }
    state.unsubscribe_screen(workspace_id, pane_id).await?;
    Ok("Screen unsubscribed".to_string())
}

#[command]
pub async fn publish_screen_delta(
    payload: ScreenDeltaPayload,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .send_screen_delta(
            payload.workspace_id.trim(),
            payload.pane_id.trim(),
            payload.session_id.trim(),
            payload.seq,
            payload.prev_seq,
            payload.encoding.as_deref().unwrap_or("base64+vt"),
            &payload.data,
        )
        .await?;
    Ok("Screen delta published".to_string())
}

#[command]
pub async fn publish_screen_snapshot(
    payload: ScreenSnapshotPayload,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .send_screen_snapshot(
            payload.workspace_id.trim(),
            payload.pane_id.trim(),
            payload.session_id.trim(),
            payload.snapshot_seq,
            payload.encoding.as_deref().unwrap_or("base64+vt"),
            &payload.data,
        )
        .await?;
    Ok("Screen snapshot published".to_string())
}

#[command]
pub async fn publish_screen_history(
    payload: ScreenHistoryPayload,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    state
        .send_screen_history_response(
            payload.workspace_id.trim(),
            payload.pane_id.trim(),
            payload.session_id.trim(),
            payload.request_id.trim(),
            payload.target_device_id.trim(),
            payload.encoding.as_deref().unwrap_or("base64+cells-json"),
            &payload.data,
        )
        .await?;
    Ok("Screen history published".to_string())
}

#[command]
pub async fn request_screen_resync(
    workspace_id: String,
    pane_id: String,
    last_seq: Option<i64>,
    encoding: Option<String>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    let pane_id = pane_id.trim();
    if workspace_id.is_empty() || pane_id.is_empty() {
        return Err("workspace_id and pane_id are required".to_string());
    }
    state
        .send_screen_resync_request(
            workspace_id,
            pane_id,
            last_seq.unwrap_or(0),
            encoding.as_deref().unwrap_or("base64+vt"),
        )
        .await?;
    Ok("Screen resync requested".to_string())
}

#[command]
pub async fn ack_screen(
    workspace_id: String,
    pane_id: String,
    ack_seq: i64,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    let workspace_id = workspace_id.trim();
    let pane_id = pane_id.trim();
    if workspace_id.is_empty() || pane_id.is_empty() || ack_seq <= 0 {
        return Err("workspace_id, pane_id and positive ack_seq are required".to_string());
    }
    state
        .send_screen_ack(workspace_id, pane_id, ack_seq)
        .await?;
    Ok("Screen acknowledged".to_string())
}

#[command]
pub async fn send_remote_input_v3(
    workspace_id: String,
    pane_id: String,
    session_id: Option<String>,
    data: String,
    input_id: String,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    if workspace_id.trim().is_empty() || pane_id.trim().is_empty() || input_id.trim().is_empty() {
        return Err("workspace_id, pane_id and input_id are required".to_string());
    }
    state
        .send_input_send(
            workspace_id.trim(),
            pane_id.trim(),
            session_id.as_deref(),
            &data,
            input_id.trim(),
        )
        .await?;
    Ok("Input sent".to_string())
}

#[command]
pub async fn request_layout_action(
    workspace_id: String,
    action: String,
    payload: Option<Value>,
    state: State<'_, WssClientState>,
) -> Result<String, String> {
    if workspace_id.trim().is_empty() || action.trim().is_empty() {
        return Err("workspace_id and action are required".to_string());
    }
    state
        .send_layout_action_request(workspace_id.trim(), action.trim(), payload)
        .await?;
    Ok("Layout action requested".to_string())
}

#[derive(Debug, Clone, Serialize)]
pub struct DesktopUpdateResponse {
    pub current_version: String,
    pub latest: ReleaseInfo,
}

#[derive(Debug, Clone, Serialize)]
pub struct DownloadedUpdate {
    pub file_path: String,
    pub file_name: String,
    pub size_bytes: u64,
}

#[command]
pub async fn check_desktop_update(server_url: String) -> Result<DesktopUpdateResponse, String> {
    let latest = api_client::fetch_latest_release(server_url, "desktop").await?;
    Ok(DesktopUpdateResponse {
        current_version: env!("CARGO_PKG_VERSION").to_string(),
        latest,
    })
}

#[command]
pub async fn download_desktop_update(
    app: AppHandle,
    url: String,
    file_name: String,
) -> Result<DownloadedUpdate, String> {
    let url = url.trim();
    if url.is_empty() {
        return Err("download url is required".to_string());
    }
    let safe_file_name = safe_download_file_name(&file_name);
    let updates_dir = app
        .path()
        .app_cache_dir()
        .map_err(|error| format!("无法定位缓存目录: {error}"))?
        .join("updates");
    fs::create_dir_all(&updates_dir)
        .map_err(|error| format!("创建更新目录失败 {}: {error}", updates_dir.display()))?;
    let target = updates_dir.join(&safe_file_name);

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|error| format!("创建下载客户端失败: {error}"))?;
    let bytes = client
        .get(url)
        .send()
        .await
        .map_err(|error| format!("下载更新失败: {error}"))?
        .error_for_status()
        .map_err(|error| format!("下载更新失败: {error}"))?
        .bytes()
        .await
        .map_err(|error| format!("读取更新文件失败: {error}"))?;
    fs::write(&target, &bytes)
        .map_err(|error| format!("保存更新文件失败 {}: {error}", target.display()))?;

    Ok(DownloadedUpdate {
        file_path: target.to_string_lossy().to_string(),
        file_name: safe_file_name,
        size_bytes: bytes.len() as u64,
    })
}

#[command]
pub fn install_desktop_update(path: String) -> Result<String, String> {
    let path = PathBuf::from(path.trim());
    if !path.exists() {
        return Err("更新安装包不存在，请重新下载".to_string());
    }
    open_path(&path)?;
    Ok("Installer opened".to_string())
}

fn safe_download_file_name(value: &str) -> String {
    let trimmed = value.trim();
    let fallback = "termsync-desktop-update";
    let name = if trimmed.is_empty() {
        fallback
    } else {
        trimmed
    };
    name.chars()
        .map(|ch| match ch {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            _ if ch.is_control() => '_',
            _ => ch,
        })
        .collect()
}

fn open_path(path: &PathBuf) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                "Start-Process -LiteralPath $args[0]",
                &path.to_string_lossy(),
            ])
            .spawn()
            .map_err(|error| format!("打开安装包失败: {error}"))?;
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(path)
            .spawn()
            .map_err(|error| format!("打开安装包失败: {error}"))?;
        return Ok(());
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(path)
            .spawn()
            .map_err(|error| format!("打开安装包失败: {error}"))?;
        return Ok(());
    }
}

#[command]
pub fn debug_log(message: String) -> Result<String, String> {
    crate::log_debug(&format!("frontend:{message}"));
    Ok("logged".to_string())
}

#[command]
pub fn write_clipboard_text(text: String) -> Result<String, String> {
    let mut clipboard = Clipboard::new().map_err(|error| format!("无法访问系统剪贴板: {error}"))?;
    clipboard
        .set_text(text)
        .map_err(|error| format!("写入系统剪贴板失败: {error}"))?;
    Ok("Clipboard updated".to_string())
}

#[command]
pub fn read_clipboard_text() -> Result<String, String> {
    let mut clipboard = Clipboard::new().map_err(|error| format!("无法访问系统剪贴板: {error}"))?;
    clipboard
        .get_text()
        .map_err(|error| format!("读取系统剪贴板失败: {error}"))
}

fn screenshots_dir() -> Result<PathBuf, String> {
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .ok_or_else(|| "无法定位用户主目录".to_string())?;
    Ok(PathBuf::from(home).join("Pictures").join("Screenshots"))
}

#[command]
pub fn save_clipboard_image_to_screenshots() -> Result<String, String> {
    let mut clipboard = Clipboard::new().map_err(|error| format!("无法访问系统剪贴板: {error}"))?;
    let image = clipboard
        .get_image()
        .map_err(|error| format!("剪贴板中没有可保存的图片: {error}"))?;

    let dir = screenshots_dir()?;
    fs::create_dir_all(&dir)
        .map_err(|error| format!("创建截图目录失败 {}: {error}", dir.to_string_lossy()))?;

    let file_name = format!(
        "tty1_clipboard_{}.png",
        Local::now().format("%Y%m%d_%H%M%S_%3f")
    );
    let path = dir.join(file_name);
    image::save_buffer_with_format(
        &path,
        image.bytes.as_ref(),
        image.width as u32,
        image.height as u32,
        ColorType::Rgba8,
        ImageFormat::Png,
    )
    .map_err(|error| format!("保存剪贴板图片失败: {error}"))?;

    path.canonicalize()
        .unwrap_or(path)
        .to_str()
        .map(|value| value.to_string())
        .ok_or_else(|| "图片路径包含无法处理的字符".to_string())
}

#[command]
pub fn window_minimize(window: tauri::WebviewWindow) -> Result<String, String> {
    window
        .minimize()
        .map_err(|error| format!("窗口最小化失败: {error}"))?;
    Ok("Window minimized".to_string())
}

#[command]
pub fn window_toggle_maximize(window: tauri::WebviewWindow) -> Result<bool, String> {
    let maximized = window
        .is_maximized()
        .map_err(|error| format!("读取窗口状态失败: {error}"))?;
    if maximized {
        window
            .unmaximize()
            .map_err(|error| format!("窗口还原失败: {error}"))?;
        Ok(false)
    } else {
        window
            .maximize()
            .map_err(|error| format!("窗口最大化失败: {error}"))?;
        Ok(true)
    }
}

#[command]
pub fn window_is_maximized(window: tauri::WebviewWindow) -> Result<bool, String> {
    window
        .is_maximized()
        .map_err(|error| format!("读取窗口状态失败: {error}"))
}

#[command]
pub fn window_start_dragging(window: tauri::WebviewWindow) -> Result<String, String> {
    let maximized = window
        .is_maximized()
        .map_err(|error| format!("读取窗口状态失败: {error}"))?;
    if maximized {
        window
            .unmaximize()
            .map_err(|error| format!("窗口还原失败: {error}"))?;
    }
    window
        .start_dragging()
        .map_err(|error| format!("启动窗口拖动失败: {error}"))?;
    Ok("Window dragging started".to_string())
}

#[command]
pub fn window_close(window: tauri::WebviewWindow) -> Result<String, String> {
    window
        .close()
        .map_err(|error| format!("关闭窗口失败: {error}"))?;
    Ok("Window closed".to_string())
}

#[command]
pub fn window_destroy(window: tauri::WebviewWindow) -> Result<String, String> {
    window
        .destroy()
        .map_err(|error| format!("关闭窗口失败: {error}"))?;
    Ok("Window destroyed".to_string())
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
    let parsed =
        serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({ "message": text }));

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

#[command]
pub async fn proxy_default_ai_request(
    server_url: String,
    token: String,
    body: Value,
) -> Result<AiProxyResponse, String> {
    let token = token.trim();
    if token.is_empty() {
        return Err("Server device token is required".to_string());
    }

    let client = api_client::http_client()?;
    let url = format!("{}/api/ai/chat", api_client::server_base_url(&server_url)?);

    crate::log_debug(&format!("command:proxy_default_ai_request url={url}"));

    let response = client
        .post(url)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .map_err(|err| format!("Default AI request failed: {err}"))?;

    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|err| format!("Failed to read default AI response: {err}"))?;
    let parsed =
        serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({ "message": text }));

    crate::log_debug(&format!(
        "command:proxy_default_ai_request:done status={}",
        status.as_u16()
    ));

    Ok(AiProxyResponse {
        ok: status.is_success(),
        status: status.as_u16(),
        body: parsed,
    })
}
