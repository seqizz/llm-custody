//! `custody-request`: the jail-side entry point.
//!
//! Reached inside the sandbox as `custody-request <attr> [--reason TEXT]`,
//! which is the same binary under a different name. It sends one bounded
//! message per attribute to the broker socket bound into the jail and waits
//! for the operator's answer on the same connection.
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

Ask the operator of this sandbox to add a package to the toolbox, which is
the shared profile on this jail's PATH. Blocks until the request is answered.

  --reason TEXT   why the package is needed; the operator sees this
  --socket PATH   broker socket (default: {sock}, or ${env})

Exit status: 0 approved, {denied} denied, {unanswered} nobody answered.

Only bare nixpkgs attribute names are accepted - `ripgrep`, `python3Packages.black`.
Flake references are refused: choosing a flake to fetch is the operator's call.
",
        sock = proto::JAIL_SOCKET_PATH,
        env = proto::SOCKET_ENV,
        denied = EXIT_DENIED,
        unanswered = EXIT_UNANSWERED,
    );
}

pub fn run(args: &[String]) -> Result<()> {
    let mut attrs: Vec<String> = Vec::new();
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
            a if a.starts_with('-') => return usage_err(format!("unknown option: {a}")),
            a => attrs.push(a.to_string()),
        }
        i += 1;
    }

    if attrs.is_empty() {
        usage();
        return usage_err("name at least one nixpkgs attribute");
    }
    for a in &attrs {
        proto::validate_attr(a)?;
    }
    proto::validate_reason(&reason)?;

    let socket = socket.unwrap_or_else(|| {
        env::var_os(proto::SOCKET_ENV)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(proto::JAIL_SOCKET_PATH))
    });

    // Each attribute is its own request, so the operator can approve the one
    // that matters and refuse the rest. Sequential on purpose: a reply usually
    // needs a human, and three prompts at once is worse than three in a row.
    let mut worst: Option<Error> = None;
    for attr in &attrs {
        match one(&socket, attr, &reason) {
            Ok(()) => {}
            Err(e) => {
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

fn one(socket: &PathBuf, attr: &str, reason: &str) -> Result<()> {
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
    let msg = json::Obj::new()
        .str("op", "request")
        .str("attr", attr)
        .str("reason", reason)
        .finish();
    proto::write_message(&mut stream, &msg)?;

    let peer = stream.try_clone()?;
    let mut reader = BufReader::new(peer);

    // No read timeout: the broker owns the deadline and always answers, and a
    // client-side one would only ever fire early and leave the operator
    // approving something nobody is waiting for. A broker that dies closes the
    // socket, which surfaces as end-of-stream below.
    loop {
        let msg = match proto::read_message(&mut reader)? {
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
            }
            proto::STATUS_OK => {
                let commands = msg.str_field("commands");
                if commands.is_empty() {
                    say(format!("{attr}: approved and installed"));
                } else {
                    say(format!("{attr}: approved, now on PATH: {commands}"));
                }
                return Ok(());
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
}
