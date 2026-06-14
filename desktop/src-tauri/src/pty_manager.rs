use parking_lot::Mutex;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::thread;
use sysinfo::{Pid, ProcessRefreshKind, System, UpdateKind};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
pub struct PtyOutputEvent {
    pub session_id: String,
    pub data: String,
    pub cwd: Option<String>,
    pub running_program: Option<String>,
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
    pub running_program: Option<String>,
}

struct PtySession {
    child: Box<dyn Child + Send + Sync>,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    title: String,
    cols: u16,
    rows: u16,
    pid: Option<u32>,
    cwd: Option<String>,
    running_program: Option<String>,
    cwd_from_shell_integration: bool,
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
    ) -> Result<SessionDescriptor, String> {
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
    ) -> Result<SessionDescriptor, String> {
        if let Some(existing) = self.describe_session(&session_id) {
            return Ok(existing);
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
        let shell_reports_cwd = Self::is_powershell(&shell);
        crate::log_debug(&format!(
            "pty:create_session session={} shell={}",
            session_id, shell
        ));

        let mut cmd = CommandBuilder::new(&shell);
        cmd.env("TERM", "xterm-256color");
        Self::configure_shell_integration(&shell, &mut cmd);
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
        let mut cwd_system = System::new();
        let initial_cwd = Self::process_cwd(&mut cwd_system, pid).or_else(|| {
            cwd_override
                .filter(|cwd| Path::new(cwd).is_dir())
                .map(ToOwned::to_owned)
        });

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("Failed to get PTY writer: {e}"))?;
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("Failed to clone PTY reader: {e}"))?;

        let session_title = title.unwrap_or_else(|| "Terminal".to_string());
        let session = Arc::new(Mutex::new(PtySession {
            child,
            master: pair.master,
            writer,
            title: session_title.clone(),
            cols,
            rows,
            pid,
            cwd: initial_cwd.clone(),
            running_program: None,
            cwd_from_shell_integration: false,
        }));

        self.sessions
            .lock()
            .insert(session_id.clone(), Arc::clone(&session));

        let app_handle = app.clone();
        let sessions = Arc::clone(&self.sessions);
        let session_for_reader = Arc::clone(&session);
        let session_id_for_reader = session_id.clone();
        let pid_for_reader = pid;
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            let mut cwd_system = System::new();
            let mut osc_buffer = String::new();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buf[..n]).to_string();
                        osc_buffer.push_str(&data);
                        let osc_cwd = Self::extract_last_osc7_cwd(&mut osc_buffer);
                        let cwd = if let Some(cwd_value) = osc_cwd {
                            let mut session = session_for_reader.lock();
                            session.cwd = Some(cwd_value.clone());
                            session.cwd_from_shell_integration = true;
                            Some(cwd_value)
                        } else {
                            let should_poll_process_cwd = {
                                let session = session_for_reader.lock();
                                !shell_reports_cwd || !session.cwd_from_shell_integration
                            };
                            if should_poll_process_cwd {
                                let cwd = Self::process_cwd(&mut cwd_system, pid_for_reader);
                                if let Some(ref cwd_value) = cwd {
                                    session_for_reader.lock().cwd = Some(cwd_value.clone());
                                }
                                cwd
                            } else {
                                session_for_reader.lock().cwd.clone()
                            }
                        };
                        let _ = app_handle.emit(
                            "pty-output",
                            PtyOutputEvent {
                                session_id: session_id_for_reader.clone(),
                                data,
                                cwd,
                                running_program: None,
                            },
                        );
                    }
                    Err(_) => break,
                }
            }

            let should_emit_exit = {
                let mut sessions = sessions.lock();
                let is_current = sessions
                    .get(&session_id_for_reader)
                    .map(|current| Arc::ptr_eq(current, &session_for_reader))
                    .unwrap_or(false);
                if is_current {
                    sessions.remove(&session_id_for_reader);
                }
                is_current
            };
            if !should_emit_exit {
                return;
            }
            let _ = app_handle.emit(
                "pty-exit",
                PtyExitEvent {
                    session_id: session_id_for_reader,
                },
            );
        });

        Ok(SessionDescriptor {
            session_id,
            title: session_title,
            cols,
            rows,
            cwd: initial_cwd,
            running_program: None,
        })
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
        let sessions: Vec<(String, Arc<Mutex<PtySession>>)> = self
            .sessions
            .lock()
            .iter()
            .map(|(session_id, session)| (session_id.clone(), Arc::clone(session)))
            .collect();

        let mut system = System::new();
        system.refresh_processes_specifics(ProcessRefreshKind::new().with_cwd(UpdateKind::Always));

        sessions
            .into_iter()
            .map(|(session_id, session)| {
                let mut session = session.lock();
                let cwd = Self::choose_described_cwd(
                    session.cwd_from_shell_integration,
                    session.cwd.clone(),
                    Self::process_cwd_from_system(&system, session.pid),
                );
                session.cwd = cwd.clone();
                let running_program = Self::running_program_name_from_system(&system, session.pid);
                session.running_program = running_program.clone();
                SessionDescriptor {
                    session_id,
                    title: session.title.clone(),
                    cols: session.cols,
                    rows: session.rows,
                    cwd,
                    running_program,
                }
            })
            .collect()
    }

    pub fn has_session(&self, session_id: &str) -> bool {
        self.sessions.lock().contains_key(session_id)
    }

    fn describe_session(&self, session_id: &str) -> Option<SessionDescriptor> {
        let session = self.sessions.lock().get(session_id).cloned()?;
        let session = session.lock();
        Some(SessionDescriptor {
            session_id: session_id.to_string(),
            title: session.title.clone(),
            cols: session.cols,
            rows: session.rows,
            cwd: session.cwd.clone(),
            running_program: session.running_program.clone(),
        })
    }

    fn process_cwd(system: &mut System, pid: Option<u32>) -> Option<String> {
        let pid = Pid::from_u32(pid?);
        if !system
            .refresh_process_specifics(pid, ProcessRefreshKind::new().with_cwd(UpdateKind::Always))
        {
            return None;
        }
        Self::process_cwd_from_system(system, Some(pid.as_u32()))
    }

    fn process_cwd_from_system(system: &System, pid: Option<u32>) -> Option<String> {
        let pid = Pid::from_u32(pid?);
        system
            .process(pid)
            .and_then(|process| process.cwd())
            .map(|path| path.to_string_lossy().into_owned())
    }

    fn running_program_name_from_system(system: &System, shell_pid: Option<u32>) -> Option<String> {
        let shell_pid = Pid::from_u32(shell_pid?);
        system
            .processes()
            .iter()
            .filter_map(|(pid, process)| {
                if *pid == shell_pid || !Self::is_descendant_process(system, *pid, shell_pid) {
                    return None;
                }
                let name = Self::display_process_name(process.name())?;
                Some((process.start_time(), pid.as_u32(), name))
            })
            .max_by_key(|(start_time, pid, _)| (*start_time, *pid))
            .map(|(_, _, name)| name)
    }

    fn is_descendant_process(system: &System, pid: Pid, ancestor_pid: Pid) -> bool {
        let mut current_pid = pid;
        for _ in 0..32 {
            let Some(parent_pid) = system
                .process(current_pid)
                .and_then(|process| process.parent())
            else {
                return false;
            };
            if parent_pid == ancestor_pid {
                return true;
            }
            current_pid = parent_pid;
        }
        false
    }

    fn display_process_name(name: &str) -> Option<String> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return None;
        }
        #[cfg(windows)]
        {
            Some(trimmed.strip_suffix(".exe").unwrap_or(trimmed).to_string())
        }
        #[cfg(not(windows))]
        {
            Some(trimmed.to_string())
        }
    }

    fn choose_described_cwd(
        cwd_from_shell_integration: bool,
        cached_cwd: Option<String>,
        process_cwd: Option<String>,
    ) -> Option<String> {
        if cwd_from_shell_integration {
            cached_cwd.or(process_cwd)
        } else {
            process_cwd.or(cached_cwd)
        }
    }

    fn configure_shell_integration(shell: &str, cmd: &mut CommandBuilder) {
        if Self::is_powershell(shell) {
            cmd.arg("-NoExit");
            cmd.arg("-Command");
            cmd.arg(Self::powershell_cwd_prompt_script());
        }
    }

    fn is_powershell(shell: &str) -> bool {
        Path::new(shell)
            .file_stem()
            .and_then(|name| name.to_str())
            .map(|name| {
                let name = name.to_ascii_lowercase();
                name == "pwsh" || name == "powershell"
            })
            .unwrap_or(false)
    }

    fn powershell_cwd_prompt_script() -> &'static str {
        "$global:__tty1_original_prompt = (Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock; function global:prompt { try { $p = (Get-Location).ProviderPath; if ($p) { $u = [System.Uri]::new($p).AbsoluteUri; [Console]::Write(\"$([char]27)]7;$u$([char]7)\") } } catch {}; if ($global:__tty1_original_prompt) { & $global:__tty1_original_prompt } else { \"PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) \" } }"
    }

    fn extract_last_osc7_cwd(buffer: &mut String) -> Option<String> {
        const OSC7_PREFIX: &str = "\x1b]7;";
        const ST: &str = "\x1b\\";

        let mut found = None;
        let mut search_start = 0;

        while let Some(relative_prefix_start) = buffer[search_start..].find(OSC7_PREFIX) {
            let prefix_start = search_start + relative_prefix_start;
            let uri_start = prefix_start + OSC7_PREFIX.len();
            let remainder = &buffer[uri_start..];
            let bell_end = remainder.find('\x07').map(|index| (index, 1));
            let st_end = remainder.find(ST).map(|index| (index, ST.len()));
            let Some((uri_len, terminator_len)) = Self::earliest_osc_terminator(bell_end, st_end)
            else {
                *buffer = buffer[prefix_start..].to_string();
                if buffer.len() > 8192 {
                    let keep_from = buffer
                        .char_indices()
                        .rev()
                        .take_while(|(index, _)| buffer.len().saturating_sub(*index) <= 8192)
                        .last()
                        .map(|(index, _)| index)
                        .unwrap_or(0);
                    *buffer = buffer[keep_from..].to_string();
                }
                return found;
            };

            let uri = &buffer[uri_start..uri_start + uri_len];
            if let Some(cwd) = Self::cwd_from_osc7_uri(uri) {
                found = Some(cwd);
            }
            search_start = uri_start + uri_len + terminator_len;
        }

        Self::keep_possible_osc7_prefix(buffer);
        found
    }

    fn keep_possible_osc7_prefix(buffer: &mut String) {
        const OSC7_PREFIX: &str = "\x1b]7;";
        let max_suffix_len = OSC7_PREFIX.len().saturating_sub(1).min(buffer.len());
        for len in (1..=max_suffix_len).rev() {
            let start = buffer.len() - len;
            if !buffer.is_char_boundary(start) {
                continue;
            }
            let suffix = &buffer[start..];
            if OSC7_PREFIX.starts_with(suffix) {
                *buffer = suffix.to_string();
                return;
            }
        }
        buffer.clear();
    }

    fn earliest_osc_terminator(
        bell_end: Option<(usize, usize)>,
        st_end: Option<(usize, usize)>,
    ) -> Option<(usize, usize)> {
        match (bell_end, st_end) {
            (Some(bell), Some(st)) => Some(if bell.0 <= st.0 { bell } else { st }),
            (Some(bell), None) => Some(bell),
            (None, Some(st)) => Some(st),
            (None, None) => None,
        }
    }

    fn cwd_from_osc7_uri(uri: &str) -> Option<String> {
        let rest = uri.strip_prefix("file://")?;
        let (host, raw_path) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index..]),
            None => ("", rest),
        };
        let decoded = Self::percent_decode(raw_path)?;
        let path = Self::osc7_path_to_local_path(host, &decoded);
        Path::new(&path).is_dir().then_some(path)
    }

    fn osc7_path_to_local_path(host: &str, path: &str) -> String {
        #[cfg(windows)]
        {
            use std::path::MAIN_SEPARATOR;

            let normalized =
                if path.len() >= 3 && path.as_bytes()[0] == b'/' && path.as_bytes()[2] == b':' {
                    &path[1..]
                } else {
                    path
                };
            let with_separators = normalized.replace('/', &MAIN_SEPARATOR.to_string());
            if !host.is_empty() && !host.eq_ignore_ascii_case("localhost") {
                format!(
                    "\\\\{}\\{}",
                    host,
                    with_separators.trim_start_matches(MAIN_SEPARATOR)
                )
            } else {
                with_separators
            }
        }
        #[cfg(not(windows))]
        {
            path.to_string()
        }
    }

    fn percent_decode(input: &str) -> Option<String> {
        let mut bytes = Vec::with_capacity(input.len());
        let mut chars = input.chars();
        while let Some(ch) = chars.next() {
            if ch == '%' {
                let high = chars.next().and_then(Self::hex_value)?;
                let low = chars.next().and_then(Self::hex_value)?;
                bytes.push((high << 4) | low);
            } else {
                let mut buf = [0u8; 4];
                bytes.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
            }
        }
        String::from_utf8(bytes).ok()
    }

    fn hex_value(ch: char) -> Option<u8> {
        match ch {
            '0'..='9' => Some(ch as u8 - b'0'),
            'a'..='f' => Some(ch as u8 - b'a' + 10),
            'A'..='F' => Some(ch as u8 - b'A' + 10),
            _ => None,
        }
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

#[cfg(test)]
mod tests {
    use super::PtyManager;

    #[test]
    fn described_cwd_prefers_shell_integration_over_process_cwd() {
        let cwd = PtyManager::choose_described_cwd(
            true,
            Some("C:\\Users\\me\\project".to_string()),
            Some("E:\\Work\\Code\\tty1\\desktop\\src-tauri".to_string()),
        );

        assert_eq!(cwd.as_deref(), Some("C:\\Users\\me\\project"));
    }

    #[test]
    fn described_cwd_uses_process_cwd_without_shell_integration() {
        let cwd = PtyManager::choose_described_cwd(
            false,
            Some("C:\\Users\\me\\project".to_string()),
            Some("E:\\Work\\Code\\tty1\\desktop\\src-tauri".to_string()),
        );

        assert_eq!(
            cwd.as_deref(),
            Some("E:\\Work\\Code\\tty1\\desktop\\src-tauri")
        );
    }

    #[test]
    fn possible_osc7_prefix_handles_multibyte_suffix() {
        let mut buffer = "PS E:\\Work\\Code\\关问> ".to_string();
        PtyManager::keep_possible_osc7_prefix(&mut buffer);
        assert_eq!(buffer, "");
    }
}
