//! `custody-request`: the jail-side entry point.
//!
//! Reached inside the sandbox as `custody-request <attr> [--reason TEXT]`,
//! `custody-request --mount <path|name> [--reason TEXT]` or
//! `custody-request --domain <name> [--reason TEXT]`, which is the same binary
//! under a different name. It sends one bounded message per attribute, path
//! or domain to the broker socket bound into the jail, each on a connection
//! of its own, and waits for the operator's answers on those connections.
//!
//! Nothing here is trusted by the broker: the validation in proto.rs runs on
//! the broker side too, and this copy exists only to fail fast with a readable
//! message instead of a protocol error.

use std::env;
use std::io::BufReader;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use crate::json;
use crate::proto;
use crate::util::{fail, usage_err, Error, Result, EXIT_DENIED, EXIT_UNANSWERED};

fn say(msg: impl AsRef<str>) {
    eprintln!("custody-request: {}", msg.as_ref());
}

pub fn usage() {
    print!(
        "\
Usage: custody-request <nixpkgs-attr>... [--reason TEXT]
       custody-request --mount <host-path|name>... [--reason TEXT]
       custody-request --domain <name>... [--reason TEXT]

Ask the operator of this sandbox to add a package to the toolbox, which is
the shared profile on this jail's PATH, to attach a host directory to this
jail, or to let this jail reach a domain its network filter blocks. Several
asks in one call reach the operator together, each answered on its own.
Blocks until every one is answered.

  --mount PATH    ask for a host path instead of a package (repeatable). PATH
                  is a best guess: the operator can mount a different path
                  for it, and decides how it is attached - read-only, a
                  synced copy, or the real tree. The answer names what was
                  mounted and where it is
  --mount NAME    the same with no path to guess: a bare name (no slash) for
                  what is needed, and the operator picks the path
  --domain NAME   ask for a blocked domain instead of a package (repeatable).
                  A blocked name resolves to 0.0.0.0 or fails to connect.
                  Fails at once, exit 1, when this jail has no network filter
  --reason TEXT   why it is needed; the operator sees this
  --socket PATH   broker socket (default: {sock}, or ${env})

Exit status: 0 approved, {denied} denied, {unanswered} nobody answered.

Only bare nixpkgs attribute names are accepted - `ripgrep`, `python3Packages.black`.
Flake references are refused: choosing a flake to fetch is the operator's call.
Mount paths must be absolute; a mount argument without a slash is a name.
Domains are plain host names such as
registry.npmjs.org: no wildcard, no IP address, no trailing dot.
",
        sock = proto::JAIL_SOCKET_PATH,
        env = proto::SOCKET_ENV,
        denied = EXIT_DENIED,
        unanswered = EXIT_UNANSWERED,
    );
}

pub fn run(args: &[String]) -> Result<()> {
    // (kind, name) pairs in command-line order.
    let mut wants: Vec<(&str, String)> = Vec::new();
    let mut reason = String::new();
    let mut socket: Option<PathBuf> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                usage();
                return Ok(());
            }
            "--reason" | "-m" => {
                i += 1;
                match args.get(i) {
                    Some(v) => reason = v.clone(),
                    None => return usage_err("--reason needs a value"),
                }
            }
            "--socket" => {
                i += 1;
                match args.get(i) {
                    Some(v) => socket = Some(PathBuf::from(v)),
                    None => return usage_err("--socket needs a value"),
                }
            }
            "--mount" => {
                i += 1;
                match args.get(i) {
                    Some(v) => wants.push((proto::KIND_MOUNT, v.clone())),
                    None => return usage_err("--mount needs a host path"),
                }
            }
            "--domain" => {
                i += 1;
                match args.get(i) {
                    Some(v) => wants.push((proto::KIND_DOMAIN, v.clone())),
                    None => return usage_err("--domain needs a domain name"),
                }
            }
            a if a.starts_with('-') => return usage_err(format!("unknown option: {a}")),
            a => wants.push((proto::KIND_PACKAGE, a.to_string())),
        }
        i += 1;
    }

    if wants.is_empty() {
        usage();
        return usage_err(
            "name at least one nixpkgs attribute, --mount a host path or --domain a name",
        );
    }
    for (kind, name) in wants.iter_mut() {
        match *kind {
            proto::KIND_MOUNT => proto::validate_mount_ask(name)?,
            // Sent in the normalized form, so the operator approves exactly
            // the name the whitelist will hold.
            proto::KIND_DOMAIN => *name = proto::validate_domain(name)?,
            _ => proto::validate_attr(name)?,
        }
    }
    proto::validate_reason(&reason)?;

    let socket = socket.unwrap_or_else(|| {
        env::var_os(proto::SOCKET_ENV)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(proto::JAIL_SOCKET_PATH))
    });

    // Each attribute or path is its own request, so the operator can approve
    // the one that matters and refuse the rest. All of them are queued before
    // the first answer is awaited: the operator sees the whole ask in one
    // list and can settle it in one pass.
    let mut worst: Option<Error> = None;
    let mut note = |e: Error| {
        say(&e.msg);
        // A denial is the answer to the question; an error means the
        // question never got asked. The latter is the more useful
        // thing to exit with.
        let keep = match &worst {
            None => true,
            Some(prev) => prev.code == EXIT_DENIED && e.code != EXIT_DENIED,
        };
        if keep {
            worst = Some(e);
        }
    };
    let mut waiting: Vec<(&str, BufReader<UnixStream>)> = Vec::new();
    for (kind, name) in &wants {
        // The first reply is read here, before the next request goes out, so
        // the broker numbers the requests in command-line order.
        let mut reader = match ask(&socket, kind, name, &reason) {
            Ok(r) => r,
            Err(e) => {
                note(e);
                continue;
            }
        };
        match step(name, &mut reader) {
            Ok(true) => {}
            Ok(false) => waiting.push((name.as_str(), reader)),
            Err(e) => note(e),
        }
    }
    // In command-line order. An answer to a later request waits in its socket
    // until the earlier ones are settled.
    for (name, mut reader) in waiting {
        loop {
            match step(name, &mut reader) {
                Ok(true) => break,
                Ok(false) => {}
                Err(e) => {
                    note(e);
                    break;
                }
            }
        }
    }
    // Each failure was already reported above, per attribute. The error that
    // carries the exit status is blanked so the top level does not print a
    // second, less specific copy of it.
    match worst {
        Some(e) => Err(Error { msg: String::new(), code: e.code }),
        None => Ok(()),
    }
}

/// Connects and sends one request. The returned reader is the connection:
/// the broker drops a request whose client hangs up, so it has to stay open
/// until the answer was read from it.
fn ask(socket: &PathBuf, kind: &str, attr: &str, reason: &str) -> Result<BufReader<UnixStream>> {
    let mut stream = match UnixStream::connect(socket) {
        Ok(s) => s,
        Err(e) => {
            return fail(format!(
                "no package broker at {} ({e}) - this sandbox was started without one, \
                 so ask the operator directly",
                socket.display()
            ))
        }
    };
    // `attr` carries the path of a mount request and the name of a domain
    // request as well: one field, one queue, one set of hook arguments on the
    // host side.
    let msg = json::Obj::new()
        .str("op", "request")
        .str("kind", kind)
        .str("attr", attr)
        .str("reason", reason)
        .finish();
    proto::write_message(&mut stream, &msg)?;
    Ok(BufReader::new(stream))
}

/// Reads one broker message about `attr` and reports it. `Ok(true)` is an
/// approval, `Ok(false)` the acknowledgement that the request is queued, and
/// every other final answer is the error carrying its exit status.
fn step(attr: &str, reader: &mut BufReader<UnixStream>) -> Result<bool> {
    // No read timeout: the broker owns the deadline and always answers, and a
    // client-side one would only ever fire early and leave the operator
    // approving something nobody is waiting for. A broker that dies closes the
    // socket, which surfaces as end-of-stream below.
    let msg = match proto::read_message(reader)? {
        Some(m) => m,
        None => {
            return Err(Error {
                msg: format!("the broker went away before answering about {attr}"),
                code: EXIT_UNANSWERED,
            })
        }
    };
    match msg.str_field("status") {
        "pending" => {
            say(format!(
                "{attr}: request {} is waiting for the operator (up to {})",
                msg.str_field("id"),
                crate::util::human_duration(std::time::Duration::from_secs(
                    msg.get("timeout").and_then(json::Json::as_u64).unwrap_or(0)
                ))
            ));
            Ok(false)
        }
        proto::STATUS_OK => {
            let commands = msg.str_field("commands");
            let guest = msg.str_field("guest");
            let host = msg.str_field("host");
            let scope = msg.str_field("scope");
            if !scope.is_empty() {
                say(format!("{attr}: approved, reachable now ({scope})"));
            } else if !guest.is_empty() && !host.is_empty() && host != attr {
                // The operator answered with a path of their own, so the
                // one asked for is not what is behind the mount.
                say(format!("{attr}: approved, the operator mounted {host} at {guest}"));
            } else if !guest.is_empty() {
                say(format!("{attr}: approved, mounted at {guest}"));
            } else if commands.is_empty() {
                say(format!("{attr}: approved and installed"));
            } else {
                say(format!("{attr}: approved, now on PATH: {commands}"));
            }
            Ok(true)
        }
        proto::STATUS_DENIED => {
            return Err(Error {
                msg: format!("{attr}: refused - {}", msg.str_field("message")),
                code: EXIT_DENIED,
            })
        }
        // Deliberately not EXIT_DENIED: the agent is told a refusal is a
        // final answer, and "the operator was away from the terminal" is
        // not one. Exit 4 says the question was never answered.
        proto::STATUS_TIMEOUT => {
            return Err(Error {
                msg: format!("{attr}: unanswered - {}", msg.str_field("message")),
                code: EXIT_UNANSWERED,
            })
        }
        proto::STATUS_ERROR => {
            return fail(format!("{attr}: {}", msg.str_field("message")))
        }
        other => return fail(format!("{attr}: unexpected broker status {other}")),
    }
}
