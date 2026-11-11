//! The broker wire protocol: one JSON object per line, in both directions.
//!
//! Framing is a newline and every message is bounded, because one end of the
//! request socket is inside a jail. A client that sends no newline, or sends
//! megabytes without one, must cost the broker a bounded amount of memory and
//! then be dropped.
//!
//! There are two sockets and they are not interchangeable:
//!
//!   * `request.sock` is bound into the jail. It accepts exactly one
//!     operation, `request`, and nothing else is even parsed from it.
//!   * `control.sock` never leaves the host. It is where `requests`,
//!     `approve` and `deny` are spoken.
//!
//! That split is the whole of the authorization model. A single socket with an
//! `approve` operation on it would let the jailed agent approve its own
//! requests, and peer credentials cannot tell the two apart because the jail
//! runs as the same uid as the operator.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;

use crate::json::{self, Json};
use crate::util::{fail, Result};

/// Where the request socket is bound inside the jail.
pub const JAIL_SOCKET_PATH: &str = "/run/custody-request.sock";
/// Lets the runner move that path without rebuilding the client.
pub const SOCKET_ENV: &str = "CUSTODY_REQUEST_SOCKET";

pub const REQUEST_SOCKET: &str = "request.sock";
pub const CONTROL_SOCKET: &str = "control.sock";
pub const META_FILE: &str = "meta";
/// Number of requests currently waiting, rewritten on every queue change.
/// The user variable and the notification hook are both best-effort and both
/// go out once per change; this file is the state a second terminal can read
/// at any time, and the thing that makes a missed notification recoverable.
pub const PENDING_FILE: &str = "pending";

/// Terminal user variable carrying that same count - empty when the queue is
/// empty, so a consumer tests it for emptiness exactly like `llm_custody_dirty`.
pub const REQUESTS_VAR: &str = "llm_custody_requests";

/// Generous for a request (an attribute plus a sentence of justification) and
/// still small enough that a few hundred wedged connections cost nothing.
pub const MAX_LINE: usize = 8 * 1024;
pub const MAX_ATTR: usize = 128;
pub const MAX_REASON: usize = 512;

/// Only bare nixpkgs attributes are accepted from a jail.
///
/// Not a style preference: a flake reference is a URL, and a URL is a fetch
/// the sandbox would be choosing on the host's behalf, with the host's
/// network and the host's nix. Keeping the grammar to an attribute means the
/// only thing a jailed agent can name is something in the flake the operator
/// already configured. Host-side `add` still takes full refs.
pub fn validate_attr(attr: &str) -> Result<()> {
    if attr.is_empty() {
        return fail("empty package attribute");
    }
    if attr.len() > MAX_ATTR {
        return fail(format!("package attribute longer than {MAX_ATTR} characters"));
    }
    let first = attr.chars().next().unwrap();
    if !(first.is_ascii_alphanumeric() || first == '_') {
        return fail(format!("package attribute must start with a letter or digit: {attr}"));
    }
    for c in attr.chars() {
        let ok = c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '+' | '.');
        if !ok {
            return fail(format!(
                "package attribute may only contain letters, digits and _-+. (got: {attr})"
            ));
        }
    }
    if attr.contains("..") || attr.ends_with('.') {
        return fail(format!("malformed attribute path: {attr}"));
    }
    Ok(())
}

/// A reason is shown to the operator in a terminal, so control characters are
/// rejected rather than escaped: a request that can repaint the screen it is
/// being reviewed on is a request that can lie about itself.
pub fn validate_reason(reason: &str) -> Result<()> {
    if reason.len() > MAX_REASON {
        return fail(format!("reason longer than {MAX_REASON} characters"));
    }
    if reason.chars().any(|c| c.is_control()) {
        return fail("reason contains control characters");
    }
    Ok(())
}

/// Read one newline-terminated message, refusing anything longer than
/// `MAX_LINE`. `Ok(None)` is a clean end of stream, i.e. the peer hung up.
pub fn read_message<R: Read>(reader: &mut BufReader<R>) -> Result<Option<Json>> {
    let mut buf = Vec::new();
    // Capped by construction: `take` cannot yield more than MAX_LINE bytes, so
    // a peer that never sends a newline gets dropped instead of growing this.
    let n = match reader.take(MAX_LINE as u64).read_until(b'\n', &mut buf) {
        Ok(n) => n,
        Err(e) => return fail(format!("reading request: {e}")),
    };
    if n == 0 {
        return Ok(None);
    }
    if !buf.ends_with(b"\n") {
        return fail(format!("message longer than {MAX_LINE} bytes, or not newline-framed"));
    }
    let text = match std::str::from_utf8(&buf) {
        Ok(t) => t,
        Err(_) => return fail("message is not UTF-8"),
    };
    match json::parse(text.trim_end()) {
        Ok(v) => Ok(Some(v)),
        Err(e) => fail(format!("malformed message: {e}")),
    }
}

pub fn write_message(stream: &mut UnixStream, msg: &str) -> Result<()> {
    let mut line = String::with_capacity(msg.len() + 1);
    line.push_str(msg);
    line.push('\n');
    match stream.write_all(line.as_bytes()).and_then(|_| stream.flush()) {
        Ok(()) => Ok(()),
        Err(e) => fail(format!("writing response: {e}")),
    }
}

pub fn ok_response() -> json::Obj {
    json::Obj::new().str("status", "ok")
}

pub fn error_response(msg: &str) -> String {
    json::Obj::new().str("status", "error").str("message", msg).finish()
}

pub fn denied_response(msg: &str) -> String {
    json::Obj::new().str("status", "denied").str("message", msg).finish()
}

/// Distinct from a denial on purpose: the agent is told a denial is a final
/// answer, and nobody having looked at the queue for half an hour is not an
/// answer at all. The client exits 4 for this and 3 for a denial.
pub fn timeout_response(msg: &str) -> String {
    json::Obj::new().str("status", "timeout").str("message", msg).finish()
}

/// The statuses a client distinguishes. Anything else is a protocol error.
pub const STATUS_OK: &str = "ok";
pub const STATUS_DENIED: &str = "denied";
pub const STATUS_ERROR: &str = "error";
pub const STATUS_TIMEOUT: &str = "timeout";
