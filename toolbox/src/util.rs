//! Errors, exit codes and the small filesystem primitives everything else
//! builds on.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Anything the operator did wrong or nix refused to do.
pub const EXIT_ERROR: i32 = 1;
/// A malformed command line. Separate from EXIT_ERROR so a wrapper script can
/// tell "you typed it wrong" from "the install failed".
pub const EXIT_USAGE: i32 = 2;
/// A package request the operator denied. Only `custody-request` returns it,
/// and a jailed agent is meant to read it as a final answer rather than retry.
pub const EXIT_DENIED: i32 = 3;
/// A request nobody answered, or whose broker went away underneath it.
pub const EXIT_UNANSWERED: i32 = 4;

#[derive(Debug)]
pub struct Error {
    pub msg: String,
    pub code: i32,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.msg)
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error { msg: e.to_string(), code: EXIT_ERROR }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn fail<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error { msg: msg.into(), code: EXIT_ERROR })
}

pub fn usage_err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error { msg: msg.into(), code: EXIT_USAGE })
}

/// Everything diagnostic goes to stderr so a piped `list` or `requests` keeps
/// stdout machine-readable, the same split the shell implementation had.
pub fn note(msg: impl AsRef<str>) {
    eprintln!("llm-custody-toolbox: {}", msg.as_ref());
}

/// Adds context to an io error without losing the original message - "No such
/// file or directory" on its own has never told anyone which file.
pub fn ctx<T>(r: io::Result<T>, what: impl fmt::Display) -> Result<T> {
    r.map_err(|e| Error { msg: format!("{what}: {e}"), code: EXIT_ERROR })
}

/// Distinguishes the temp files of two concurrent writers in one process. The
/// pid alone does not: the broker services requests on several threads.
static SEQ: AtomicU64 = AtomicU64::new(0);

/// Write-to-temp-then-rename, which is the whole of "atomically" for every
/// piece of state this program owns. A reader (another CLI invocation, a
/// concurrent broker thread) therefore sees either the previous content or the
/// new one, never a half-written file - and a lease file truncated by a crash
/// would otherwise read back as a nameless profile element.
///
/// The temp file is created in the destination directory because rename(2) is
/// only atomic within one filesystem.
pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("state");
    let tmp = dir.join(format!(
        ".{}.tmp.{}.{}",
        name,
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    ctx(fs::write(&tmp, contents), format!("writing {}", tmp.display()))?;
    match fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            fail(format!("renaming into {}: {e}", path.display()))
        }
    }
}

/// Replace a symlink in place. `std::os::unix::fs::symlink` fails on an
/// existing path, and unlink-then-create would leave the link missing for a
/// moment - which for `current` is the moment a running jail resolves its
/// PATH through it.
pub fn symlink_atomic(target: &Path, link: &Path) -> Result<()> {
    use std::os::unix::fs::symlink;
    let dir = link.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(
        ".link.tmp.{}.{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = fs::remove_file(&tmp);
    ctx(symlink(target, &tmp), format!("linking {}", tmp.display()))?;
    match fs::rename(&tmp, link) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            fail(format!("renaming link into {}: {e}", link.display()))
        }
    }
}

pub fn mkdir_p(path: &Path) -> Result<()> {
    ctx(fs::create_dir_all(path), format!("creating {}", path.display()))
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn mtime_secs(path: &Path) -> Result<u64> {
    let md = ctx(fs::metadata(path), format!("stat {}", path.display()))?;
    let t = ctx(md.modified(), format!("mtime of {}", path.display()))?;
    Ok(t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0))
}

/// `30d`, `12h`, `90m`, `3600s`, or a bare number in `default_unit`. The shell
/// implementation took a bare count of days for a lease lifetime and `gc`
/// spells its period `30d`, so both have to keep working.
pub fn parse_duration(s: &str, default_unit: char) -> Result<Duration> {
    let s = s.trim();
    if s.is_empty() {
        return usage_err("empty duration");
    }
    let (digits, unit) = match s.chars().last().unwrap() {
        c @ ('s' | 'm' | 'h' | 'd' | 'w') => (&s[..s.len() - 1], c),
        _ => (s, default_unit),
    };
    let n: u64 = match digits.parse() {
        Ok(n) => n,
        Err(_) => {
            return usage_err(format!(
                "not a duration: {s} (want a number, optionally with s/m/h/d/w)"
            ))
        }
    };
    let mult = match unit {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        'w' => 604800,
        _ => return usage_err(format!("unknown duration unit: {unit}")),
    };
    Ok(Duration::from_secs(n.saturating_mul(mult)))
}

/// Renders a duration the way the reports read it back out: whole days once it
/// is worth counting in days, otherwise hours or minutes.
pub fn human_duration(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 86400 {
        format!("{}d", s / 86400)
    } else if s >= 3600 {
        format!("{}h", s / 3600)
    } else if s >= 60 {
        format!("{}m", s / 60)
    } else {
        format!("{s}s")
    }
}

/// Does this pid still exist? Used to tell a broker that exited without
/// cleaning up (SIGKILL, a host crash) from one that is merely busy, so a
/// stale registration directory can be removed instead of reported.
pub fn pid_alive(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding. Twenty lines rather than a dependency, for
/// the one caller below - OSC 1337 carries its value this way.
fn base64(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 63] as char);
        out.push(B64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64[n as usize & 63] as char } else { '=' });
    }
    out
}

/// Publish a terminal user variable (OSC 1337 SetUserVar), the same way the
/// jail runner does - see its `emit_uservar`, which this has to stay
/// byte-compatible with because both write the same variables to the same
/// terminal.
///
/// Written to /dev/tty rather than stdout so it cannot end up in a redirected
/// log, which matters here because the broker's stdout *is* a log file.
///
/// Safe to do while the jailed tool owns the terminal: the kernel serialises
/// tty writes, so a single write() of a complete sequence cannot interleave
/// with the tool's own output, and SetUserVar moves no cursor and changes no
/// SGR state, so a terminal that receives it renders nothing. The one write
/// here is therefore deliberate and not an accident of formatting.
///
/// Every failure is ignored: a session with no controlling terminal is the
/// normal headless case, not an error.
pub fn emit_uservar(name: &str, value: &str) {
    use std::io::Write;
    let tmux = matches!(std::env::var_os("TMUX"), Some(v) if !v.is_empty());
    let seq = uservar_sequence(name, value, tmux);
    if let Ok(mut tty) = fs::OpenOptions::new().write(true).open("/dev/tty") {
        // One write_all of one buffer: see the note above about why that is
        // what makes this safe mid-session.
        let _ = tty.write_all(seq.as_bytes());
    }
}

/// Split out from the write so it can be tested without a terminal.
fn uservar_sequence(name: &str, value: &str, tmux: bool) -> String {
    let osc = format!("\x1b]1337;SetUserVar={name}={}\x07", base64(value.as_bytes()));
    if tmux {
        // tmux does not forward an OSC it does not understand to the outer
        // terminal unless it is wrapped in DCS passthrough, with every ESC in
        // the payload doubled.
        format!("\x1bPtmux;{}\x1b\\", osc.replace('\x1b', "\x1b\x1b"))
    } else {
        osc
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
        assert_eq!(base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        // The values actually sent: a small count, and the empty string that
        // means "nothing pending".
        assert_eq!(base64(b"3"), "Mw==");
    }

    #[test]
    fn uservar_sequence_shape() {
        assert_eq!(
            uservar_sequence("llm_custody_requests", "3", false),
            "\x1b]1337;SetUserVar=llm_custody_requests=Mw==\x07"
        );
        // Clearing sends an empty value, not a zero.
        assert_eq!(
            uservar_sequence("llm_custody_requests", "", false),
            "\x1b]1337;SetUserVar=llm_custody_requests=\x07"
        );
    }

    #[test]
    fn tmux_wrapping_doubles_every_escape() {
        let seq = uservar_sequence("v", "1", true);
        assert!(seq.starts_with("\x1bPtmux;"));
        assert!(seq.ends_with("\x1b\\"));
        // The payload's own ESC is doubled; the wrapper's two are not.
        assert_eq!(seq, "\x1bPtmux;\x1b\x1b]1337;SetUserVar=v=MQ==\x07\x1b\\");
    }

    #[test]
    fn durations_accept_both_notations() {
        assert_eq!(parse_duration("30", 'd').unwrap().as_secs(), 30 * 86400);
        assert_eq!(parse_duration("30d", 'd').unwrap().as_secs(), 30 * 86400);
        assert_eq!(parse_duration("90m", 'd').unwrap().as_secs(), 5400);
        assert!(parse_duration("bogus", 'd').is_err());
        assert!(parse_duration("", 'd').is_err());
    }
}
