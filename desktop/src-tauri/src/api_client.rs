use reqwest::Certificate;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseInfo {
    pub available: bool,
    pub platform: String,
    #[serde(default)]
    pub version_name: String,
    #[serde(default)]
    pub file_name: String,
    #[serde(default)]
    pub download_url: String,
    #[serde(default)]
    pub size: String,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredDevice {
    pub id: String,
    pub name: String,
    pub token: String,
    #[serde(rename = "type")]
    pub device_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterDeviceResponse {
    pub success: bool,
    pub device: RegisteredDevice,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingDesktopSummary {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingCodeResponse {
    pub success: bool,
    pub code: String,
    pub desktop: PairingDesktopSummary,
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevicePairing {
    pub desktop_id: String,
    pub desktop_name: String,
    pub mobile_id: String,
    pub mobile_name: String,
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletePairingResponse {
    pub success: bool,
    pub pairing: DevicePairing,
}

pub fn http_client() -> Result<reqwest::Client, String> {
    let cert = Certificate::from_pem(include_bytes!("../../assets/server.crt"))
        .map_err(|e| format!("Failed to load bundled certificate: {e}"))?;

    reqwest::Client::builder()
        .use_rustls_tls()
        .add_root_certificate(cert)
        .build()
        .map_err(|e| format!("Failed to build API client: {e}"))
}

pub fn server_base_url(server_url: &str) -> Result<String, String> {
    let trimmed = server_url.trim();
    if trimmed.is_empty() {
        return Err("Server URL is required".to_string());
    }

    let mut url = trimmed
        .replace("wss://", "https://")
        .replace("ws://", "http://");
    if let Some(idx) = url.find("/ws") {
        url.truncate(idx);
    }
    Ok(url.trim_end_matches('/').to_string())
}

pub async fn register_device(
    server_url: String,
    name: String,
    device_type: String,
) -> Result<RegisterDeviceResponse, String> {
    let client = http_client()?;
    let url = format!("{}/api/register", server_base_url(&server_url)?);

    client
        .post(url)
        .json(&serde_json::json!({
            "name": name,
            "type": device_type,
        }))
        .send()
        .await
        .map_err(|e| format!("Register request failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Register request failed: {e}"))?
        .json::<RegisterDeviceResponse>()
        .await
        .map_err(|e| format!("Failed to parse register response: {e}"))
}

pub async fn generate_pairing_code(
    server_url: String,
    token: String,
) -> Result<PairingCodeResponse, String> {
    let client = http_client()?;
    let url = format!("{}/api/pairing/start", server_base_url(&server_url)?);

    client
        .post(url)
        .json(&serde_json::json!({ "token": token }))
        .send()
        .await
        .map_err(|e| format!("Pairing request failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Pairing request failed: {e}"))?
        .json::<PairingCodeResponse>()
        .await
        .map_err(|e| format!("Failed to parse pairing response: {e}"))
}

pub async fn complete_pairing(
    server_url: String,
    token: String,
    code: String,
) -> Result<CompletePairingResponse, String> {
    let client = http_client()?;
    let url = format!("{}/api/pairing/complete", server_base_url(&server_url)?);

    client
        .post(url)
        .json(&serde_json::json!({
            "token": token,
            "code": code,
        }))
        .send()
        .await
        .map_err(|e| format!("Pairing completion request failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Pairing completion request failed: {e}"))?
        .json::<CompletePairingResponse>()
        .await
        .map_err(|e| format!("Failed to parse pairing completion response: {e}"))
}

pub async fn fetch_latest_release(
    server_url: String,
    platform: &str,
) -> Result<ReleaseInfo, String> {
    let client = http_client()?;
    let url = format!(
        "{}/api/releases/latest?platform={}",
        server_base_url(&server_url)?,
        platform
    );

    client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("Release request failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Release request failed: {e}"))?
        .json::<ReleaseInfo>()
        .await
        .map_err(|e| format!("Failed to parse release response: {e}"))
}
