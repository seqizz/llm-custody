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
/// PATH_MAX; anything longer is not a path the host could mount anyway.
pub const MAX_PATH: usize = 4096;
/// The DNS limit for a name in dotted form, without the trailing dot.
pub const MAX_DOMAIN: usize = 253;
const MAX_LABEL: usize = 63;

/// What a request asks for. A package goes into the toolbox profile, a mount
/// attaches a host directory to the jail that asked, a domain is added to that
/// jail's network whitelist. All three travel the same socket, hold the same
/// place in the queue and are answered the same way; only the approval step
/// differs.
pub const KIND_PACKAGE: &str = "package";
pub const KIND_MOUNT: &str = "mount";
pub const KIND_DOMAIN: &str = "domain";

/// How long an approved domain stays allowed. `session` ends with the jail,
/// `persist` also appends it to the state root's domains file so the next
/// launch starts with it. Like a mount mode, only the operator picks this.
pub const DOMAIN_MODES: [&str; 2] = ["session", "persist"];
pub const DEFAULT_DOMAIN_MODE: &str = "session";

pub fn validate_domain_mode(mode: &str) -> Result<()> {
    if DOMAIN_MODES.contains(&mode) {
        Ok(())
    } else {
        fail(format!("domain mode must be one of {} (got: {mode})", DOMAIN_MODES.join("|")))
    }
}

/// Validate a domain name and return it lowercased, which is the form every
/// later step (the queue, the domain launcher, dnsmasq) sees.
///
/// The name ends up in a dnsmasq `server=/NAME/IP` line, so anything outside
/// letters, digits, `-` and `.` would be config injection: a `/` adds a field,
/// a `#` starts a comment, a newline starts a new directive. The rules are
/// plain LDH hostname syntax and match `domain_valid` in lib/net-filter.sh,
/// which the domain launcher applies again on its side.
///
/// At least two labels: a bare TLD would whitelist a whole registry. No
/// wildcard and no trailing dot, because dnsmasq already matches subdomains
/// and a second spelling of the same name would only confuse list/remove.
/// Not an IP literal: an address is not something DNS whitelisting can grant,
/// and inet_aton accepts hex (`0x7f`) and short (`127.1`) forms, so every
/// label being a number in one of those spellings is what is refused.
pub fn validate_domain(name: &str) -> Result<String> {
    let name = name.to_ascii_lowercase();
    if name.is_empty() {
        return fail("empty domain name");
    }
    if name.len() > MAX_DOMAIN {
        return fail(format!("domain name longer than {MAX_DOMAIN} characters"));
    }
    // Before any check whose message echoes the name: an error is printed
    // to the operator's terminal too.
    if name.chars().any(|c| c.is_control()) {
        return fail("domain name contains control characters");
    }
    if !name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '.') {
        return fail(format!("domain name may only contain letters, digits, - and . (got: {name})"));
    }
    if name.ends_with('.') {
        return fail(format!("domain name must not end with a dot: {name}"));
    }
    let labels: Vec<&str> = name.split('.').collect();
    if labels.len() < 2 {
        return fail(format!("domain name needs at least two labels: {name}"));
    }
    for label in &labels {
        if label.is_empty() {
            return fail(format!("domain name has an empty label: {name}"));
        }
        if label.len() > MAX_LABEL {
            return fail(format!("domain label longer than {MAX_LABEL} characters: {name}"));
        }
        if label.starts_with('-') || label.ends_with('-') {
            return fail(format!("domain label must not start or end with -: {name}"));
        }
    }
    if labels.iter().all(|l| numeric_label(l)) {
        return fail(format!("an IP address is not a domain name: {name}"));
    }
    Ok(name)
}

/// A label inet_aton would read as a number: decimal, octal (also all
/// digits) or `0x` hex.
fn numeric_label(label: &str) -> bool {
    if label.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    match label.strip_prefix("0x") {
        Some(hex) => hex.chars().all(|c| c.is_ascii_hexdigit()),
        None => false,
    }
}

/// How an approved mount is attached. The operator picks this at approval
/// time; a jailed client cannot name one, because `full` hands it the real
/// tree read-write and that choice is the operator's.
pub const MOUNT_MODES: [&str; 6] = ["ro", "full", "limited", "none", "overlay", "copy"];
pub const DEFAULT_MOUNT_MODE: &str = "ro";

pub fn validate_mount_mode(mode: &str) -> Result<()> {
    if MOUNT_MODES.contains(&mode) {
        Ok(())
    } else {
        fail(format!("mount mode must be one of {} (got: {mode})", MOUNT_MODES.join("|")))
    }
}

/// A mount request names a host path, and the grammar is the host's: absolute,
/// no control characters (it is shown to the operator), no `..` component (a
/// request shown as `/srv/data/../../etc` is a request to read as the
/// resolved path, and the operator should see that path). The host side still
/// decides whether the path exists and what, if anything, to do with it.
pub fn validate_mount_path(path: &str) -> Result<()> {
    if path.is_empty() {
        return fail("empty mount path");
    }
    if path.len() > MAX_PATH {
        return fail(format!("mount path longer than {MAX_PATH} bytes"));
    }
    if !path.starts_with('/') {
        return fail(format!("mount path must be absolute: {path}"));
    }
    if path.chars().any(|c| c.is_control()) {
        return fail("mount path contains control characters");
    }
    if path.split('/').any(|c| c == "..") {
        return fail(format!("mount path must not contain '..': {path}"));
    }
    Ok(())
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mount_paths() {
        assert!(validate_mount_path("/srv/data").is_ok());
        assert!(validate_mount_path("/").is_ok());
        assert!(validate_mount_path("/with space/and:colon").is_ok());
        assert!(validate_mount_path("").is_err());
        assert!(validate_mount_path("srv/data").is_err());
        assert!(validate_mount_path("/srv/../etc").is_err());
        assert!(validate_mount_path("/srv/data\n").is_err());
        assert!(validate_mount_path(&format!("/{}", "a".repeat(MAX_PATH))).is_err());
        // A dot-dot inside a name is a name, not a traversal.
        assert!(validate_mount_path("/srv/a..b").is_ok());
    }

    #[test]
    fn domains() {
        assert_eq!(validate_domain("registry.npmjs.org").unwrap(), "registry.npmjs.org");
        // Lowercased, since that is the form dnsmasq and the domains file use.
        assert_eq!(validate_domain("GitHub.COM").unwrap(), "github.com");
        assert!(validate_domain("a-b.c0.io").is_ok());
        assert!(validate_domain(&format!("{}.com", "a".repeat(63))).is_ok());

        // Config injection into `server=/NAME/IP`.
        assert!(validate_domain("a/b.com").is_err());
        assert!(validate_domain("a/b#c").is_err());
        assert!(validate_domain("x/1.2.3.4").is_err());
        assert!(validate_domain("evil.com#comment").is_err());
        assert!(validate_domain("evil.com\nserver=/x/1.1.1.1").is_err());
        assert!(validate_domain("evil.com\n").is_err());
        assert!(validate_domain("evil .com").is_err());

        assert!(validate_domain("").is_err());
        assert!(validate_domain("com").is_err(), "bare TLD");
        assert!(validate_domain("a..com").is_err());
        assert!(validate_domain(".a.com").is_err());
        assert!(validate_domain("a.com.").is_err());
        assert!(validate_domain("*.a.com").is_err());
        assert!(validate_domain("-a.com").is_err());
        assert!(validate_domain("a-.com").is_err());
        assert!(validate_domain(&format!("{}.com", "a".repeat(64))).is_err());
        let long = format!("{}.com", vec!["a".repeat(60); 5].join("."));
        assert!(long.len() > MAX_DOMAIN);
        assert!(validate_domain(&long).is_err());

        // IP literals, including the spellings inet_aton also accepts.
        assert!(validate_domain("1.2.3.4").is_err());
        assert!(validate_domain("127.1").is_err());
        assert!(validate_domain("0x7f.0.0.1").is_err());
        assert!(validate_domain("[::1]").is_err());
        assert!(validate_domain("::1").is_err());
        // A numeric label among names is fine.
        assert!(validate_domain("1.2.3.example.com").is_ok());
        assert!(validate_domain("0xfeed.dev").is_ok());
    }

    #[test]
    fn domain_modes() {
        for m in DOMAIN_MODES {
            assert!(validate_domain_mode(m).is_ok());
        }
        assert!(validate_domain_mode("ro").is_err());
        assert!(validate_domain_mode("").is_err());
    }

    #[test]
    fn mount_modes() {
        for m in MOUNT_MODES {
            assert!(validate_mount_mode(m).is_ok());
        }
        assert!(validate_mount_mode("rw").is_err());
        assert!(validate_mount_mode("").is_err());
    }
}
