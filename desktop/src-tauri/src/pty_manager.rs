use parking_lot::Mutex;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::thread;
use sysinfo::{Pid, System};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
pub struct PtyOutputEvent {
    pub session_id: String,
    pub data: String,
}

#[derive(Clone, Serialize)]
pub struct PtyExitEvent {
    pub session_id: String,
}

#[derive(Clone, Serialize)]
pub struct SessionDescriptor {
    pub session_id: String,
    pub title: String,
    pub cols: u16,
    pub rows: u16,
    pub cwd: Option<String>,
}

struct PtySession {
    child: Box<dyn Child + Send + Sync>,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    title: String,
    cols: u16,
    rows: u16,
    pid: Option<u32>,
}

#[derive(Clone, Default)]
pub struct PtyManager {
    sessions: Arc<Mutex<HashMap<String, Arc<Mutex<PtySession>>>>>,
}

impl PtyManager {
    pub fn create_session(
        &self,
        app: &AppHandle,
        session_id: String,
        cols: u16,
        rows: u16,
        title: Option<String>,
        shell: Option<String>,
        cwd: Option<String>,
    ) -> Result<String, String> {
        self.create_session_with_shell(
            app,
            session_id,
            cols,
            rows,
            title,
            shell.as_deref(),
            cwd.as_deref(),
        )
    }

    pub fn create_session_with_shell(
        &self,
        app: &AppHandle,
        session_id: String,
        cols: u16,
        rows: u16,
        title: Option<String>,
        shell_override: Option<&str>,
        cwd_override: Option<&str>,
    ) -> Result<String, String> {
        if self.has_session(&session_id) {
            return Ok(session_id);
        }

        let pty_system = native_pty_system();
        let size = PtySize {
            cols,
            rows,
            pixel_width: 0,
            pixel_height: 0,
        };

        let pair = pty_system
            .openpty(size)
            .map_err(|e| format!("Failed to open PTY: {e}"))?;

        let shell = shell_override
            .map(ToOwned::to_owned)
            .unwrap_or_else(Self::detect_shell);
        crate::log_debug(&format!(
            "pty:create_session session={} shell={}",
            session_id, shell
        ));

        let mut cmd = CommandBuilder::new(&shell);
        cmd.env("TERM", "xterm-256color");
        if let Some(cwd) = cwd_override.filter(|cwd| Path::new(cwd).is_dir()) {
            cmd.cwd(cwd);
        }

        let child = pair.slave.spawn_command(cmd).map_err(|e| {
            format!(
                "Failed to spawn '{}': {}. Check the shell path in settings.",
                shell, e
            )
        })?;
        let pid = child.process_id();

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("Failed to get PTY writer: {e}"))?;
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("Failed to clone PTY reader: {e}"))?;

        let session = Arc::new(Mutex::new(PtySession {
            child,
            master: pair.master,
            writer,
            title: title.unwrap_or_else(|| "Terminal".to_string()),
            cols,
            rows,
            pid,
        }));

        self.sessions
            .lock()
            .insert(session_id.clone(), Arc::clone(&session));

        let app_handle = app.clone();
        let sessions = Arc::clone(&self.sessions);
        let session_id_for_reader = session_id.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buf[..n]).to_string();
                        let _ = app_handle.emit(
                            "pty-output",
                            PtyOutputEvent {
                                session_id: session_id_for_reader.clone(),
                                data,
                            },
                        );
                    }
                    Err(_) => break,
                }
            }

            sessions.lock().remove(&session_id_for_reader);
            let _ = app_handle.emit(
                "pty-exit",
                PtyExitEvent {
                    session_id: session_id_for_reader,
                },
            );
        });

        Ok(session_id)
    }

    pub fn write_input(&self, session_id: &str, data: &[u8]) -> Result<(), String> {
        let session = self
            .sessions
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Session {session_id} not found"))?;

        let mut session = session.lock();
        session
            .writer
            .write_all(data)
            .map_err(|e| format!("Failed to write to PTY: {e}"))?;
        session
            .writer
            .flush()
            .map_err(|e| format!("Failed to flush PTY: {e}"))?;
        Ok(())
    }

    pub fn resize(&self, session_id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let session = self
            .sessions
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| format!("Session {session_id} not found"))?;

        let mut session = session.lock();
        session
            .master
            .resize(PtySize {
                cols,
                rows,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Failed to resize PTY: {e}"))?;
        session.cols = cols;
        session.rows = rows;
        Ok(())
    }

    pub fn update_session_title(&self, session_id: &str, title: &str) -> bool {
        let session = self.sessions.lock().get(session_id).cloned();
        let Some(session) = session else {
            return false;
        };

        session.lock().title = title.to_string();
        true
    }

    pub fn close_session(&self, session_id: &str) -> Result<(), String> {
        let session = self
            .sessions
            .lock()
            .remove(session_id)
            .ok_or_else(|| format!("Session {session_id} not found"))?;

        let mut session = session.lock();
        session
            .child
            .kill()
            .map_err(|e| format!("Failed to stop PTY child: {e}"))?;
        Ok(())
    }

    pub fn describe_sessions(&self) -> Vec<SessionDescriptor> {
        let mut system = System::new_all();
        system.refresh_all();
        self.sessions
            .lock()
            .iter()
            .map(|(session_id, session)| {
                let session = session.lock();
                let cwd = session.pid.and_then(|pid| {
                    system
                        .process(Pid::from_u32(pid))
                        .and_then(|process| process.cwd())
                        .map(|path| path.to_string_lossy().into_owned())
                });
                SessionDescriptor {
                    session_id: session_id.clone(),
                    title: session.title.clone(),
                    cols: session.cols,
                    rows: session.rows,
                    cwd,
                }
            })
            .collect()
    }

    pub fn has_session(&self, session_id: &str) -> bool {
        self.sessions.lock().contains_key(session_id)
    }

    fn detect_shell() -> String {
        #[cfg(windows)]
        {
            let candidates = [
                "pwsh.exe",
                r"C:\Program Files\PowerShell\7\pwsh.exe",
                "powershell.exe",
                "cmd.exe",
            ];

            for candidate in candidates {
                if candidate.contains('\\') {
                    if Path::new(candidate).exists() {
                        return candidate.to_string();
                    }
                    continue;
                }

                if Command::new("where")
                    .arg(candidate)
                    .output()
                    .map(|output| output.status.success())
                    .unwrap_or(false)
                {
                    return candidate.to_string();
                }
            }

            "powershell.exe".to_string()
        }

        #[cfg(not(windows))]
        {
            "bash".to_string()
        }
    }
}
