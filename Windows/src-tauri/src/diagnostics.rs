//! Bounded local lifecycle records. Never include snapshots, prompts or credentials.
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

const MAX_LOG_BYTES: u64 = 1024 * 1024;
static LOGGER: OnceLock<Mutex<Logger>> = OnceLock::new();

struct Logger {
    path: PathBuf,
}
impl Logger {
    fn write(&self, event: &str, fields: Value) -> std::io::Result<()> {
        if fs::metadata(&self.path).is_ok_and(|m| m.len() >= MAX_LOG_BYTES) {
            fs::rename(&self.path, self.path.with_extension("log.1"))?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        serde_json::to_writer(
            &mut file,
            &json!({
                "time": chrono::Utc::now().to_rfc3339(), "pid": std::process::id(),
                "event": event, "fields": fields,
            }),
        )?;
        file.write_all(b"\n")?;
        file.flush()
    }
}

pub fn init() {
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let dir = PathBuf::from(local).join("com.wuruoye.tokenbar.windows/logs");
        if fs::create_dir_all(&dir).is_ok() {
            let _ = LOGGER.set(Mutex::new(Logger {
                path: dir.join("runtime.log"),
            }));
        }
    }
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        // A panic payload can contain user data; record only code location and stack.
        record(
            "panic",
            json!({
                "location": info.location().map(|p| format!("{}:{}:{}", p.file(), p.line(), p.column())),
                "thread": std::thread::current().name(),
                "stack": std::backtrace::Backtrace::force_capture().to_string().chars().take(16000).collect::<String>(),
            }),
        );
        previous(info);
    }));
    record(
        "launch",
        json!({"version": env!("CARGO_PKG_VERSION"),
        "background": std::env::args().any(|arg| arg == "--background")}),
    );
}

pub fn record(event: &str, fields: Value) {
    if let Some(logger) = LOGGER.get() {
        // Diagnostics must never block an exit or deadlock a panic handler.
        if let Ok(logger) = logger.try_lock() {
            let _ = logger.write(event, fields);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rotates_at_one_megabyte_and_retains_complete_json_lines() {
        let dir = tempfile::tempdir().unwrap();
        let logger = Logger {
            path: dir.path().join("runtime.log"),
        };
        fs::write(&logger.path, vec![b'x'; MAX_LOG_BYTES as usize]).unwrap();
        logger
            .write("exit-requested", json!({"code":null}))
            .unwrap();
        assert_eq!(
            fs::metadata(logger.path.with_extension("log.1"))
                .unwrap()
                .len(),
            MAX_LOG_BYTES
        );
        let entry: Value = serde_json::from_slice(&fs::read(&logger.path).unwrap()).unwrap();
        assert_eq!(entry["event"], "exit-requested");
        // Replacement also has to work on Windows when the previous rotation exists.
        fs::write(&logger.path, vec![b'y'; MAX_LOG_BYTES as usize]).unwrap();
        logger.write("exit", json!({})).unwrap();
        assert_eq!(
            fs::read(logger.path.with_extension("log.1")).unwrap()[0],
            b'y'
        );
    }
}
