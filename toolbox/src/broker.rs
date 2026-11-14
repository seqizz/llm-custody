//! `serve`: the per-jail request broker.
//!
//! One of these is started by each jail runner. It owns two Unix sockets under
//! `$XDG_RUNTIME_DIR/llm-custody/brokers/<broker-id>/`, holds requests in
//! memory while the operator decides, and performs an approved install through
//! exactly the same `Toolbox::add` the host CLI uses - there is no second
//! install path to keep in step. An approved mount request likewise runs the
//! session's own mount launcher (`--mount-cmd`), the same command the
//! operator's keybinding runs, and an approved domain request runs the
//! session's domain launcher (`--domain-cmd`), the same one behind
//! `llm-custody domain`.

use std::collections::HashMap;
use std::fs;
use std::io::BufReader;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::json;
use crate::paths::{self, Layout};
use crate::proto;
use crate::toolbox::Toolbox;
use crate::util::{self, fail, usage_err, Result};

/// How often a waiting request thread looks up from its socket to notice an
/// approval. Also the worst-case delay between the operator approving and the
/// jail client being told.
const POLL: Duration = Duration::from_millis(200);

/// A jailed agent can open as many connections as it likes; this is what stops
/// that from being interesting. Past the cap, further requests are refused
/// immediately instead of being queued.
const MAX_PENDING: usize = 32;

pub struct ServeOpts {
    pub broker_id: String,
    pub label: String,
    pub timeout: Duration,
    /// Whether this terminal takes user variables. Passed in by the runner
    /// rather than re-derived here: several sites publish these variables and
    /// they have to agree, so the decision stays made in exactly one place.
    pub uservar: bool,
    /// Optional host-side notification command, run on every queue change.
    pub notify_hook: Option<PathBuf>,
    /// The session's mount launcher, run as `<cmd> add --mode M -- PATH` to
    /// approve a mount request. Absent for a jail started without one, where
    /// a mount request is accepted into the queue but cannot be approved.
    pub mount_cmd: Option<PathBuf>,
    /// The session's domain launcher, run as `<cmd> add [--persist] -- NAME`
    /// to approve a domain request. Absent exactly when the jail runs without
    /// a network filter, where every domain is reachable already and a domain
    /// request is answered with an error on the spot.
    pub domain_cmd: Option<PathBuf>,
}

/// What an approval did, which depends on what was asked for.
enum Done {
    /// The commands the package put on the jail's PATH; empty when it was
    /// already installed or ships no bin/.
    Package { commands: Vec<String> },
    /// Where the tree was attached inside the jail, and in which mode.
    Mount { guest: String, mode: String },
    /// How long the domain stays allowed: `session` or `persist`.
    Domain { scope: String },
}

impl Done {
    /// The fields a reply carries beyond `id` and `attr`. The operator's
    /// reply and the jail client's differ on purpose: the operator is told
    /// the mount mode they chose and gets `commands` even when it is empty,
    /// while the client's reply names only what it can act on, and its
    /// reader tells the three kinds apart by which field is present.
    fn fields(&self, for_operator: bool) -> Vec<(&'static str, String)> {
        match self {
            Done::Package { commands } if commands.is_empty() && !for_operator => Vec::new(),
            Done::Package { commands } => vec![("commands", commands.join(" "))],
            Done::Mount { guest, mode } if for_operator => {
                vec![("guest", guest.clone()), ("mode", mode.clone())]
            }
            Done::Mount { guest, .. } => vec![("guest", guest.clone())],
            Done::Domain { scope } => vec![("scope", scope.clone())],
        }
    }

    /// The word for having done it, for the note an operator gets when the
    /// jail client stopped waiting in the meantime.
    fn verb(&self) -> &'static str {
        match self {
            Done::Package { .. } => "installed",
            Done::Mount { .. } => "mounted",
            Done::Domain { .. } => "allowed",
        }
    }
}

enum Outcome {
    Approved(Done),
    Denied(String),
    /// Nobody answered before the hold time ran out. Separate from `Denied`
    /// because the agent treats a denial as final.
    TimedOut(String),
    Failed(String),
}

struct Pending {
    /// `proto::KIND_PACKAGE`, `proto::KIND_MOUNT` or `proto::KIND_DOMAIN`.
    kind: String,
    /// The nixpkgs attribute, the host path of a mount request, or the
    /// lowercased name of a domain request.
    attr: String,
    reason: String,
    created: u64,
    tx: Sender<Outcome>,
}

struct Broker {
    toolbox: Toolbox,
    pending: Mutex<HashMap<String, Pending>>,
    seq: AtomicU64,
    id: String,
    label: String,
    timeout: Duration,
    started: u64,
    dir: PathBuf,
    uservar: bool,
    notify_hook: Option<PathBuf>,
    mount_cmd: Option<PathBuf>,
    domain_cmd: Option<PathBuf>,
    /// Last count published to the terminal. Emission is on change only -
    /// nothing is gained by repeating a count, and an agent that spams
    /// requests should not get to decide how often this writes to a terminal.
    last_published: Mutex<Option<usize>>,
}

/// `llm-custody serve --help`.
pub fn usage() {
    print!(
        "\
Usage: llm-custody [--dir PATH] serve [OPTION...]

The request broker for one jail. Started by the jail runner, not usually by
hand: it owns the two sockets a jailed custody-request talks to and holds the
client's connection open until the operator answers.

  --broker-id ID     registration name under $XDG_RUNTIME_DIR/llm-custody/
                     brokers (the runner passes its own pid)
  --label TEXT       how this jail reads in the request list
  --timeout PERIOD   how long an unanswered request blocks its client
  --uservar 0|1      publish the pending count as a terminal user variable
  --notify-hook PATH run on every queue change, with <event> <id> <attr>
                     <reason> <count> <label> as separate arguments and no
                     shell involved. Its failure is never the request's
                     problem. $LLMCUSTODY_NOTIFY_HOOK is the default
  --mount-cmd PATH   the session's mount launcher; an approved mount request
                     runs it as `add --mode M -- PATH`
  --domain-cmd PATH  the session's domain launcher; an approved domain
                     request runs it as `add [--persist] -- NAME`. Without
                     it (no network filter) a domain request fails at once

Also runs one prune and gc in the background, which is what keeps expired
leases from accumulating without anyone remembering to look.
$LLMCUSTODY_TOOLBOX_AUTOPRUNE=0 turns that off.
"
    );
}

/// `llm-custody serve`: the runner's command line, parsed into `ServeOpts`.
pub fn cmd_serve(tb: Toolbox, args: &[String]) -> Result<()> {
    let mut broker_id = std::process::id().to_string();
    let mut label = String::new();
    // Long enough that an operator can be away from the terminal, short enough
    // that an abandoned jail's requests do not pile up forever.
    let mut timeout = Duration::from_secs(30 * 60);
    // Off unless the runner says this terminal takes user variables. Not
    // re-derived from the environment here on purpose: the runner already
    // decides it once for every publisher, and a second opinion is how they
    // drift apart.
    let mut uservar = false;
    let mut notify_hook = std::env::var_os("LLMCUSTODY_NOTIFY_HOOK")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let mut mount_cmd = None;
    let mut domain_cmd = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--uservar" => {
                i += 1;
                match args.get(i).map(String::as_str) {
                    Some("1") => uservar = true,
                    Some("0") => uservar = false,
                    _ => return usage_err("--uservar takes 0 or 1"),
                }
            }
            "--notify-hook" => {
                i += 1;
                match args.get(i) {
                    Some(v) => notify_hook = Some(PathBuf::from(v)),
                    None => return usage_err("--notify-hook needs a path"),
                }
            }
            "--mount-cmd" => {
                i += 1;
                match args.get(i) {
                    Some(v) => mount_cmd = Some(PathBuf::from(v)),
                    None => return usage_err("--mount-cmd needs a path"),
                }
            }
            "--domain-cmd" => {
                i += 1;
                match args.get(i) {
                    Some(v) => domain_cmd = Some(PathBuf::from(v)),
                    None => return usage_err("--domain-cmd needs a path"),
                }
            }
            "--broker-id" => {
                i += 1;
                match args.get(i) {
                    Some(v) => broker_id = v.clone(),
                    None => return usage_err("--broker-id needs a value"),
                }
            }
            "--label" => {
                i += 1;
                match args.get(i) {
                    Some(v) => label = v.clone(),
                    None => return usage_err("--label needs a value"),
                }
            }
            "--timeout" => {
                i += 1;
                match args.get(i) {
                    Some(v) => timeout = util::parse_duration(v, 'm')?,
                    None => return usage_err("--timeout needs a period, e.g. 30m"),
                }
            }
            a => return usage_err(format!("serve: unknown option: {a} (try --help)")),
        }
        i += 1;
    }
    if !paths::lease_name_ok(&broker_id) {
        return usage_err(format!("not usable as a broker id: {broker_id}"));
    }
    serve(
        tb.layout,
        ServeOpts {
            broker_id,
            label,
            timeout,
            uservar,
            notify_hook,
            mount_cmd,
            domain_cmd,
        },
    )
}

pub fn serve(layout: Layout, opts: ServeOpts) -> Result<()> {
    let dir = layout.broker(&opts.broker_id);
    util::mkdir_p(&dir)?;
    // The sockets carry approval authority for one of them and a package
    // request channel for the other; neither is anyone else's business.
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));

    let request_path = dir.join(proto::REQUEST_SOCKET);
    let control_path = dir.join(proto::CONTROL_SOCKET);
    let meta_path = dir.join(proto::META_FILE);

    // A broker that died without cleaning up leaves its socket files behind,
    // and bind(2) refuses an existing path.
    let _ = fs::remove_file(&request_path);
    let _ = fs::remove_file(&control_path);

    let request_sock = util::ctx(
        UnixListener::bind(&request_path),
        format!("binding {}", request_path.display()),
    )?;
    let control_sock = util::ctx(
        UnixListener::bind(&control_path),
        format!("binding {}", control_path.display()),
    )?;
    let _ = fs::set_permissions(&request_path, fs::Permissions::from_mode(0o600));
    let _ = fs::set_permissions(&control_path, fs::Permissions::from_mode(0o600));

    let started = util::now_secs();
    let meta = json::Obj::new()
        .num("pid", std::process::id() as u64)
        .str("broker", &opts.broker_id)
        .str("label", &opts.label)
        .str("toolbox", &layout.dir.to_string_lossy())
        .num("started", started)
        .num("timeout", opts.timeout.as_secs())
        .finish();
    util::write_atomic(&meta_path, format!("{meta}\n").as_bytes())?;

    // Every file this directory will ever hold, because the handler's final
    // rmdir fails on a non-empty directory and a missed one therefore leaks
    // the whole registration. The pending file does not exist yet; unlinking
    // something absent is harmless, and listing it here is what keeps this in
    // step with cleanup() below.
    signals::install_cleanup(
        vec![
            request_path.clone(),
            control_path.clone(),
            meta_path.clone(),
            dir.join(proto::PENDING_FILE),
        ],
        &dir,
    );
    // After the handler is installed, so a parent that is already gone takes
    // the registration with it instead of leaving it behind.
    signals::die_with_parent();

    let broker = Arc::new(Broker {
        toolbox: Toolbox::new(layout),
        pending: Mutex::new(HashMap::new()),
        seq: AtomicU64::new(0),
        id: opts.broker_id.clone(),
        label: opts.label.clone(),
        timeout: opts.timeout,
        started,
        dir: dir.clone(),
        uservar: opts.uservar,
        notify_hook: opts.notify_hook.clone(),
        mount_cmd: opts.mount_cmd.clone(),
        domain_cmd: opts.domain_cmd.clone(),
        last_published: Mutex::new(None),
    });
    // Start from a known-empty queue rather than leaving whatever a previous
    // broker left behind, and clear a user variable a crashed one may have
    // left set on this terminal.
    broker.announce("start", "", "", "");

    util::note(format!(
        "broker {} listening ({}), requests held for up to {}",
        opts.broker_id,
        request_path.display(),
        util::human_duration(opts.timeout)
    ));

    start_expiry_pass(Arc::clone(&broker));

    // The control listener runs on its own thread so an approval is never
    // waiting behind a jail client that opened a connection and went quiet.
    {
        let b = Arc::clone(&broker);
        std::thread::spawn(move || {
            for stream in control_sock.incoming() {
                match stream {
                    Ok(s) => {
                        let b = Arc::clone(&b);
                        std::thread::spawn(move || b.handle_control(s));
                    }
                    Err(e) => util::note(format!("control socket: {e}")),
                }
            }
        });
    }

    for stream in request_sock.incoming() {
        match stream {
            Ok(s) => {
                let b = Arc::clone(&broker);
                std::thread::spawn(move || b.handle_request(s));
            }
            Err(e) => util::note(format!("request socket: {e}")),
        }
    }

    cleanup(&dir);
    Ok(())
}

pub(crate) fn cleanup(dir: &Path) {
    let _ = fs::remove_file(dir.join(proto::REQUEST_SOCKET));
    let _ = fs::remove_file(dir.join(proto::CONTROL_SOCKET));
    let _ = fs::remove_file(dir.join(proto::META_FILE));
    let _ = fs::remove_file(dir.join(proto::PENDING_FILE));
    let _ = fs::remove_dir(dir);
}

/// Drop expired leases, and the generations nothing needs any more, once per
/// session.
///
/// Provisioning is otherwise a one-way ratchet: a package added for one
/// afternoon stays on every future jail's PATH, with its whole closure pinned,
/// until somebody remembers its name. Leaving that to an operator-run `prune`
/// means it happens on the days somebody remembers, which is not a policy.
/// A jail start is the one moment that reliably happens, and the broker is the
/// part of it already running host-side with a `Toolbox` and its lock.
///
/// On a thread, because nothing here belongs on the launch path: the runner is
/// waiting for `request.sock` to appear, not for nix. Best effort in every
/// direction - a failure is a line in `broker.log` and nothing else, and a
/// toolbox busy with another session's approve just makes this wait on the
/// lock. `LLMCUSTODY_TOOLBOX_AUTOPRUNE=0` turns it off for a host that would
/// rather drive it by hand.
///
/// Unpinning only. Reclaiming the store stays with whatever
/// `nix-collect-garbage` the host already runs, which is where the policy for
/// the rest of the store lives.
fn start_expiry_pass(broker: Arc<Broker>) {
    if std::env::var("LLMCUSTODY_TOOLBOX_AUTOPRUNE").is_ok_and(|v| v == "0") {
        util::note("auto-prune disabled by LLMCUSTODY_TOOLBOX_AUTOPRUNE=0");
        return;
    }
    std::thread::spawn(move || {
        let period = broker.toolbox.layout.lease_period;
        match broker.toolbox.prune(period, false) {
            Ok(o) if o.removed.is_empty() && o.orphaned.is_empty() => {}
            Ok(o) => util::note(format!(
                "auto-prune: {} expired lease(s) dropped ({}), {} generation(s)",
                o.removed.len() + o.orphaned.len(),
                o.removed.iter().chain(o.orphaned.iter()).cloned().collect::<Vec<_>>().join(" "),
                o.generations_dropped
            )),
            Err(e) => util::note(format!("auto-prune: {}", e.msg)),
        }
        // The generations `prune` wipes are only the ones that held what it
        // just removed. Every `add` and `upgrade` also leaves its predecessor
        // behind as a GC root pinning a whole old closure, and those are
        // exactly what no later `nix-collect-garbage` can reach: the toolbox
        // lives outside /nix/var/nix/profiles, so even `-d` does not know it
        // exists. Same period as the leases, floored at a day so a short
        // LLMCUSTODY_TOOLBOX_LEASE_DAYS cannot round down into "drop every
        // generation but the current one".
        let days = std::cmp::max(1, period.as_secs() / 86400);
        match broker.toolbox.gc(Some(&format!("{days}d")), false) {
            Ok(0) => {}
            Ok(n) => util::note(format!("auto-prune: {n} stale generation(s) dropped")),
            Err(e) => util::note(format!("auto-prune: {}", e.msg)),
        }
    });
}

/// The mount launcher's command line for an approved mount request.
///
/// Same discipline as the hook: the path came from inside a jail, so it is
/// one argv entry after a `--`, never part of a string anything re-parses.
/// The mode is the operator's, validated before it gets here.
fn mount_command(launcher: &Path, mode: &str, path: &str) -> std::process::Command {
    let mut cmd = std::process::Command::new(launcher);
    cmd.args(["add", "--mode", mode, "--", path])
        .stdin(std::process::Stdio::null());
    cmd
}

/// The domain launcher's command line for an approved domain request.
///
/// The name was validated (LDH only) before it got here, but it still came
/// from inside a jail, so it gets the same treatment as a mount path: one argv
/// entry after a `--`. `persist` is the operator's choice.
fn domain_command(launcher: &Path, persist: bool, name: &str) -> std::process::Command {
    let mut cmd = std::process::Command::new(launcher);
    cmd.arg("add");
    if persist {
        cmd.arg("--persist");
    }
    cmd.args(["--", name]).stdin(std::process::Stdio::null());
    cmd
}

/// The last non-empty line a launcher wrote to stderr: its own statement of
/// what went wrong, and the one line of it the operator and the agent get to
/// read, since neither can see the broker log.
fn last_line(stderr: &str) -> Option<&str> {
    stderr.lines().map(str::trim).filter(|l| !l.is_empty()).last()
}

/// A successful launcher's commentary (the mode it used, a warning about a
/// bound .git) is worth having in the broker log next to the request it
/// belongs to.
fn relay(tag: &str, stderr: &str) {
    for line in stderr.lines().map(str::trim).filter(|l| !l.is_empty()) {
        util::note(format!("{tag}: {line}"));
    }
}

/// Run the session's domain launcher and return the scope it reports.
///
/// The launcher prints `NAME<TAB>session|persist` on stdout and its
/// diagnostics on stderr. Exit 2 is a name it refused, anything else non-zero
/// a failure to apply it; either way the last stderr line is what the
/// operator and the agent get to read.
fn run_domain(launcher: &Path, persist: bool, name: &str) -> Result<String> {
    let out = util::ctx(
        domain_command(launcher, persist, name).output(),
        format!("running {}", launcher.display()),
    )?;
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() {
        let why = last_line(&stderr).unwrap_or("domain launcher failed");
        return match out.status.code() {
            Some(2) => fail(format!("domain launcher refused {name}: {why}")),
            _ => fail(format!("allowing {name} failed: {why}")),
        };
    }
    relay("domain", &stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    let scope = stdout
        .lines()
        .last()
        .and_then(|l| l.split('\t').nth(1))
        .map(str::trim)
        .unwrap_or("");
    // A launcher that printed nothing still applied the name, so the
    // operator's own choice is the truthful fallback.
    Ok(if scope.is_empty() {
        if persist { "persist" } else { proto::DEFAULT_DOMAIN_MODE }.to_string()
    } else {
        scope.to_string()
    })
}

/// The notification hook's command line.
///
/// Separate from `run_hook` so the argv can be asserted on without spawning
/// anything - the property that matters is the shape of the argument vector,
/// and this is where it is decided.
///
/// Six values, every one of them its own entry, with no shell anywhere in the
/// path. The attribute and the reason come from inside a jail, so a hook that
/// re-split them would be handing an agent's string to something that runs it.
fn hook_command(
    hook: &Path,
    event: &str,
    id: &str,
    attr: &str,
    reason: &str,
    count: usize,
    label: &str,
) -> std::process::Command {
    let count = count.to_string();
    let mut cmd = std::process::Command::new(hook);
    cmd.args([event, id, attr, reason, count.as_str(), label])
        .stdin(std::process::Stdio::null());
    cmd
}

/// Run the session's mount launcher and return the guest path it reports.
///
/// The launcher prints exactly one line on stdout, `GUEST<TAB>POINT<TAB>FIXED`,
/// and everything else on stderr; a failure's stderr is what the operator and
/// the agent both get to read, since neither can see the broker log.
fn run_mount(launcher: &Path, mode: &str, path: &str) -> Result<String> {
    let out = util::ctx(
        mount_command(launcher, mode, path).output(),
        format!("running {}", launcher.display()),
    )?;
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() {
        let why = last_line(&stderr).unwrap_or("mount launcher failed");
        return fail(format!("mounting {path} failed: {why}"));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let guest = stdout
        .lines()
        .last()
        .and_then(|l| l.split('\t').next())
        .unwrap_or("")
        .to_string();
    if guest.is_empty() {
        return fail(format!("mount launcher reported no guest path for {path}"));
    }
    relay("mount", &stderr);
    Ok(guest)
}

impl Broker {
    // ---- telling the operator something is waiting -----------------------

    /// Called after every change to the queue, and never with the pending
    /// lock held.
    ///
    /// Three sinks, in increasing order of how much can go wrong with them:
    /// the `pending` file (always, cheap, what a second terminal reads), the
    /// terminal user variable (on change, best-effort), and the notification
    /// hook (best-effort, someone else's code). None of them can fail the
    /// request that triggered them - by the time this runs, the queue has
    /// already changed and the jail client is already waiting on the answer.
    fn announce(&self, event: &str, id: &str, attr: &str, reason: &str) {
        let count = self.pending.lock().unwrap().len();

        let _ = util::write_atomic(
            &self.dir.join(proto::PENDING_FILE),
            format!("{count}\n").as_bytes(),
        );

        if self.uservar {
            let mut last = self.last_published.lock().unwrap();
            if *last != Some(count) {
                // Empty rather than "0" when the queue drains, so a consumer
                // tests this variable for emptiness exactly like the other
                // ones the runner publishes.
                let value = if count == 0 { String::new() } else { count.to_string() };
                util::emit_uservar(proto::REQUESTS_VAR, &value);
                *last = Some(count);
            }
        }

        self.run_hook(event, id, attr, reason, count);
    }

    /// Run the operator's notification command, if there is one.
    ///
    /// Every field goes out as its own argv entry: an attribute and a reason
    /// both arrive here from inside a jail, and the one thing that must never
    /// happen to them is being pasted into a command line for a shell to
    /// re-parse. There is no shell in this path at all.
    ///
    /// Fire and forget. The child is waited on by a thread that exists only
    /// to reap it - a hook that blocks, hangs or exits non-zero must not hold
    /// up the request thread or change its outcome.
    fn run_hook(&self, event: &str, id: &str, attr: &str, reason: &str, count: usize) {
        let hook = match &self.notify_hook {
            Some(h) => h.clone(),
            None => return,
        };
        let mut cmd = hook_command(&hook, event, id, attr, reason, count, &self.label);
        match cmd.spawn() {
            Ok(mut child) => {
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
            }
            // Said once per occurrence into the broker log, never escalated:
            // a missing or unexecutable hook is a misconfiguration to notice
            // later, not a reason to refuse a package request now.
            Err(e) => util::note(format!("notify hook {}: {e}", hook.display())),
        }
    }

    // ---- jail-facing socket ---------------------------------------------

    fn handle_request(&self, mut stream: UnixStream) {
        if let Err(e) = self.handle_request_inner(&mut stream) {
            let _ = proto::write_message(&mut stream, &proto::error_response(&e.msg));
        }
    }

    fn handle_request_inner(&self, stream: &mut UnixStream) -> Result<()> {
        let peer = util::ctx(stream.try_clone(), "cloning request socket")?;
        let mut reader = BufReader::new(peer);
        let msg = match proto::read_message(&mut reader)? {
            Some(m) => m,
            // Connected and hung up without asking anything.
            None => return Ok(()),
        };

        // This socket has exactly one verb. Approval lives on the control
        // socket, which is never bound into a jail - see proto.rs.
        if msg.str_field("op") != "request" {
            return fail("this socket only accepts package, mount and domain requests");
        }

        // A message with no kind is a package request from a client built
        // before mounts existed.
        let kind = match msg.str_field("kind") {
            "" => proto::KIND_PACKAGE.to_string(),
            k => k.to_string(),
        };
        let mut attr = msg.str_field("attr").to_string();
        let reason = msg.str_field("reason").trim().to_string();
        match kind.as_str() {
            proto::KIND_PACKAGE => proto::validate_attr(&attr)?,
            proto::KIND_MOUNT => proto::validate_mount_path(&attr)?,
            proto::KIND_DOMAIN => attr = proto::validate_domain(&attr)?,
            other => return fail(format!("unknown request kind: {other}")),
        }
        proto::validate_reason(&reason)?;
        // Answered now rather than queued: without a filter there is nothing
        // to approve, and an agent blocked for the whole hold time on a
        // question nobody needs to answer is worse than an instant error. A
        // plain error, so the client exits 1 rather than "denied" or
        // "unanswered", neither of which would be true.
        if kind == proto::KIND_DOMAIN && self.domain_cmd.is_none() {
            return fail(
                "network filter is off for this session, every domain is already reachable",
            );
        }

        let id = format!("{}.{}", self.id, self.seq.fetch_add(1, Ordering::Relaxed) + 1);
        let (tx, rx) = mpsc::channel();
        {
            let mut pending = self.pending.lock().unwrap();
            if pending.len() >= MAX_PENDING {
                return fail(format!(
                    "{MAX_PENDING} requests are already waiting for an answer - ask the operator \
                     to work through those first"
                ));
            }
            pending.insert(
                id.clone(),
                Pending {
                    kind: kind.clone(),
                    attr: attr.clone(),
                    reason: reason.clone(),
                    created: util::now_secs(),
                    tx,
                },
            );
        }
        util::note(format!(
            "request {id}: {}{attr} ({})",
            match kind.as_str() {
                proto::KIND_MOUNT => "mount ",
                proto::KIND_DOMAIN => "domain ",
                _ => "",
            },
            if reason.is_empty() { "no reason given" } else { &reason }
        ));
        // After the lock above is dropped, so announce() can count the queue.
        self.announce("request", &id, &attr, &reason);

        // Acknowledged before the wait so the agent can print something
        // useful, and so the operator and the agent are looking at the same
        // request id.
        proto::write_message(
            stream,
            &json::Obj::new()
                .str("status", "pending")
                .str("id", &id)
                .str("kind", &kind)
                .str("attr", &attr)
                .num("timeout", self.timeout.as_secs())
                .finish(),
        )?;

        let outcome = self.wait_for_outcome(&id, &rx, &mut reader, stream);
        let reply = match outcome {
            Some(Outcome::Approved(done)) => {
                let mut o = proto::ok_response().str("id", &id).str("attr", &attr);
                for (key, value) in &done.fields(false) {
                    o = o.str(key, value);
                }
                o.finish()
            }
            Some(Outcome::Denied(why)) => proto::denied_response(&why),
            Some(Outcome::TimedOut(why)) => proto::timeout_response(&why),
            Some(Outcome::Failed(why)) => proto::error_response(&why),
            // The client is gone; nothing to answer.
            None => return Ok(()),
        };
        proto::write_message(stream, &reply)
    }

    /// Blocks until the request is answered, the client disconnects, or the
    /// hold time runs out. Returns `None` when there is nobody left to answer.
    fn wait_for_outcome(
        &self,
        id: &str,
        rx: &Receiver<Outcome>,
        reader: &mut BufReader<UnixStream>,
        stream: &UnixStream,
    ) -> Option<Outcome> {
        let deadline = Instant::now() + self.timeout;
        let _ = stream.set_read_timeout(Some(POLL));
        loop {
            match rx.try_recv() {
                Ok(o) => return Some(o),
                // The entry was taken out of the map and dropped without an
                // answer, which only happens if the broker is shutting down.
                Err(TryRecvError::Disconnected) => {
                    self.forget(id);
                    return Some(Outcome::Failed("broker is shutting down".to_string()));
                }
                Err(TryRecvError::Empty) => {}
            }

            // A jail client that went away must not leave its request in the
            // operator's queue until the timeout. The client sends nothing
            // after its request, so any readable byte is either EOF or a
            // protocol violation.
            let mut byte = [0u8; 1];
            use std::io::Read;
            match reader.read(&mut byte) {
                Ok(0) => {
                    self.forget(id);
                    util::note(format!("request {id}: client disconnected"));
                    return None;
                }
                Ok(_) => {
                    self.forget(id);
                    util::note(format!("request {id}: unexpected data from client, dropped"));
                    return None;
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => {
                    self.forget(id);
                    return None;
                }
            }

            if Instant::now() >= deadline {
                self.forget(id);
                util::note(format!("request {id}: timed out"));
                return Some(Outcome::TimedOut(format!(
                    "nobody answered within {}",
                    util::human_duration(self.timeout)
                )));
            }
        }
    }

    /// Drop a request nobody will answer any more (the client went away, or
    /// the hold time ran out) and republish the queue, so a badge does not
    /// keep advertising work the operator can no longer act on.
    fn forget(&self, id: &str) {
        // Only when this call is the one that removed it. A client that hangs
        // up while its approval is still building lands here with the entry
        // already gone, and announcing then would fire a `dropped` hook for a
        // request that was approved - with an empty attribute, since there is
        // no longer anything to read it from. The queue is also unchanged in
        // that case, so there is nothing to republish.
        let gone = self.pending.lock().unwrap().remove(id);
        if let Some(p) = gone {
            self.announce("dropped", id, &p.attr, &p.reason);
        }
    }

    // ---- host-facing socket ---------------------------------------------

    fn handle_control(&self, mut stream: UnixStream) {
        if let Err(e) = self.handle_control_inner(&mut stream) {
            let _ = proto::write_message(&mut stream, &proto::error_response(&e.msg));
        }
    }

    fn handle_control_inner(&self, stream: &mut UnixStream) -> Result<()> {
        let peer = util::ctx(stream.try_clone(), "cloning control socket")?;
        let mut reader = BufReader::new(peer);
        let msg = match proto::read_message(&mut reader)? {
            Some(m) => m,
            None => return Ok(()),
        };
        match msg.str_field("op") {
            "list" => {
                let reply = self.list_reply();
                proto::write_message(stream, &reply)
            }
            "approve" => {
                let reply = self.approve(msg.str_field("id"), msg.str_field("mode"))?;
                proto::write_message(stream, &reply)
            }
            "deny" => {
                let reply = self.deny(msg.str_field("id"), msg.str_field("reason"))?;
                proto::write_message(stream, &reply)
            }
            other => fail(format!("unknown control operation: {other}")),
        }
    }

    fn list_reply(&self) -> String {
        let now = util::now_secs();
        let pending = self.pending.lock().unwrap();
        let mut ids: Vec<&String> = pending.keys().collect();
        ids.sort();
        let mut arr = String::from("[");
        for (i, id) in ids.iter().enumerate() {
            let p = &pending[*id];
            if i > 0 {
                arr.push(',');
            }
            arr.push_str(
                &json::Obj::new()
                    .str("id", id)
                    .str("kind", &p.kind)
                    .str("attr", &p.attr)
                    .str("reason", &p.reason)
                    .num("age", now.saturating_sub(p.created))
                    .finish(),
            );
        }
        arr.push(']');
        proto::ok_response()
            .str("broker", &self.id)
            .str("label", &self.label)
            .num("started", self.started)
            .raw("requests", &arr)
            .finish()
    }

    /// Approval installs through the ordinary `Toolbox::add`, which also means
    /// it takes the ordinary toolbox lock, creates or renews the lease, and
    /// retargets `current` - so the package is visible to *every* running jail
    /// the moment this returns, not just the one that asked. A mount request
    /// runs the session's mount launcher instead, with the mode the operator
    /// chose (`mode`; empty means read-only), and a domain request runs the
    /// session's domain launcher (`mode` is `session` or `persist`, empty
    /// means `session`).
    fn approve(&self, id: &str, mode: &str) -> Result<String> {
        // Checked before the request leaves the queue: a mount or domain
        // nobody can perform, or a mode that does not fit the request, should
        // leave it listed rather than be consumed by a failed approval.
        let (kind, launcher, mode) = {
            let pending = self.pending.lock().unwrap();
            let p = match pending.get(id) {
                None => return fail(format!("no pending request with id {id}")),
                Some(p) => p,
            };
            match p.kind.as_str() {
                proto::KIND_MOUNT => {
                    let mode = if mode.is_empty() { proto::DEFAULT_MOUNT_MODE } else { mode };
                    proto::validate_mount_mode(mode)?;
                    match &self.mount_cmd {
                        Some(l) => (p.kind.clone(), Some(l.clone()), mode),
                        None => {
                            return fail(
                                "this jail was started without a mount launcher, so the request \
                                 cannot be approved - deny it, or restart the session",
                            )
                        }
                    }
                }
                proto::KIND_DOMAIN => {
                    let mode = if mode.is_empty() { proto::DEFAULT_DOMAIN_MODE } else { mode };
                    proto::validate_domain_mode(mode)?;
                    match &self.domain_cmd {
                        Some(l) => (p.kind.clone(), Some(l.clone()), mode),
                        // The request socket already refuses a domain request
                        // in this case; kept as a check rather than an assert
                        // so a broker bug cannot turn into a panic.
                        None => {
                            return fail(
                                "this jail runs without a network filter, so there is no \
                                 domain to allow - deny the request",
                            )
                        }
                    }
                }
                // The mode means nothing for a package.
                _ => (p.kind.clone(), None, ""),
            }
        };
        // Taken out of the map before the install so a second `approve` of the
        // same id cannot start a second one, and so the lock below is never
        // held while the pending map is.
        let p = match self.pending.lock().unwrap().remove(id) {
            Some(p) => p,
            None => return fail(format!("no pending request with id {id}")),
        };
        // Announced before the install, not after: the request has left the
        // queue, and a nix build can take minutes during which the badge
        // would otherwise still be asking for attention.
        self.announce("approved", id, &p.attr, &p.reason);

        // Each kind differs only in what it runs and what that produces;
        // delivering the outcome and reporting a failure are the same for
        // all three, below.
        let done: Result<Done> = match (kind.as_str(), &launcher) {
            (proto::KIND_DOMAIN, Some(launcher)) => {
                util::note(format!("request {id}: approved, allowing {} ({mode})", p.attr));
                run_domain(launcher, mode == "persist", &p.attr).map(|scope| Done::Domain { scope })
            }
            (_, Some(launcher)) => {
                util::note(format!("request {id}: approved, mounting {} ({mode})", p.attr));
                run_mount(launcher, mode, &p.attr)
                    .map(|guest| Done::Mount { guest, mode: mode.to_string() })
            }
            (_, None) => {
                util::note(format!("request {id}: approved, installing {}", p.attr));
                self.toolbox
                    .add(std::slice::from_ref(&p.attr))
                    .map(|outcome| Done::Package { commands: outcome.new_commands })
            }
        };
        match done {
            Ok(done) => {
                let fields = done.fields(true);
                let verb = done.verb();
                // A client that gave up in the meantime is not an error: the
                // work is done, and for a package the next jail to look will
                // find it.
                let delivered = p.tx.send(Outcome::Approved(done)).is_ok();
                let mut o = proto::ok_response().str("id", id).str("attr", &p.attr);
                for (key, value) in &fields {
                    o = o.str(key, value);
                }
                if !delivered {
                    o = o.str("note", &format!("{verb}, but the jail client had already gone away"));
                }
                Ok(o.finish())
            }
            Err(e) => {
                // The waiting client is told the same thing the operator is.
                let _ = p.tx.send(Outcome::Failed(e.msg.clone()));
                Err(e)
            }
        }
    }

    fn deny(&self, id: &str, reason: &str) -> Result<String> {
        let p = match self.pending.lock().unwrap().remove(id) {
            Some(p) => p,
            None => return fail(format!("no pending request with id {id}")),
        };
        let why = if reason.trim().is_empty() {
            "the operator denied this request".to_string()
        } else {
            reason.trim().to_string()
        };
        // The operator's reason, not the agent's: on every other event the
        // reason field answers "why is this happening", and for a denial that
        // is the refusal, which is also the only part of it the operator has
        // not already read.
        self.announce("denied", id, &p.attr, &why);
        util::note(format!("request {id}: {} denied", p.attr));
        let _ = p.tx.send(Outcome::Denied(why));
        Ok(proto::ok_response().str("id", id).str("attr", &p.attr).finish())
    }
}

/// Removing the runtime registration when the runner stops the broker.
///
/// The jail runner also removes this directory from its own exit trap, and the
/// host CLI prunes registrations whose pid is gone - this is the first of
/// those three layers, and the only one that works for a broker started by
/// hand and interrupted at the terminal.
mod signals {
    use std::ffi::CString;
    use std::path::{Path, PathBuf};
    use std::sync::OnceLock;

    const SIGHUP: i32 = 1;
    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;

    /// `prctl(2)`'s PR_SET_PDEATHSIG.
    const PR_SET_PDEATHSIG: i32 = 1;

    // Declared rather than pulled in from the libc crate: a handful of symbols
    // out of the C library std already links is not worth a dependency, and
    // the three the handler uses are async-signal-safe, which is the only
    // property that matters there.
    extern "C" {
        fn signal(signum: i32, handler: usize) -> usize;
        fn unlink(path: *const u8) -> i32;
        fn rmdir(path: *const u8) -> i32;
        fn _exit(code: i32) -> !;
        fn prctl(option: i32, ...) -> i32;
        fn getppid() -> i32;
    }

    /// Ask the kernel to SIGTERM this process when its parent dies.
    ///
    /// The jail runner stops its broker from the exit trap, which covers every
    /// ordinary end of a session. It does not cover the runner being SIGKILLed
    /// or its terminal going away: the trap never runs, and the broker is left
    /// holding sockets for a jail that no longer exists - alive, so nothing
    /// prunes it, and listed by `requests` as a queue the operator cannot
    /// usefully answer. SIGTERM goes to the handler above, so the registration
    /// is cleaned up on the way out.
    ///
    /// Racy by nature: if the parent is already gone when this runs, no signal
    /// is ever sent, hence the immediate re-check.
    pub fn die_with_parent() {
        // prctl(2) is variadic and takes its arguments as unsigned long.
        unsafe {
            prctl(PR_SET_PDEATHSIG, SIGTERM as std::ffi::c_ulong);
            if getppid() == 1 {
                handler(SIGTERM);
            }
        }
    }

    static FILES: OnceLock<Vec<CString>> = OnceLock::new();
    static DIR: OnceLock<CString> = OnceLock::new();

    extern "C" fn handler(_sig: i32) {
        // Only unlink/rmdir/_exit run here. Allocation, formatting and locks
        // are all unsafe in a signal handler; reading an already-initialised
        // OnceLock is a plain atomic load.
        if let Some(files) = FILES.get() {
            for f in files {
                unsafe { unlink(f.as_ptr() as *const u8) };
            }
        }
        if let Some(dir) = DIR.get() {
            unsafe { rmdir(dir.as_ptr() as *const u8) };
        }
        unsafe { _exit(0) }
    }

    pub fn install_cleanup(files: Vec<PathBuf>, dir: &Path) {
        let as_c: Vec<CString> = files
            .iter()
            .filter_map(|p| CString::new(p.as_os_str().as_encoded_bytes()).ok())
            .collect();
        let _ = FILES.set(as_c);
        if let Ok(c) = CString::new(dir.as_os_str().as_encoded_bytes()) {
            let _ = DIR.set(c);
        }
        let h = handler as extern "C" fn(i32) as usize;
        unsafe {
            signal(SIGTERM, h);
            signal(SIGINT, h);
            signal(SIGHUP, h);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;

    /// What a jailed agent can put in `--reason`: separators, a command
    /// substitution, a backquote, a pipe, quotes. None of it means anything
    /// to the broker, but the hook is host-side code the broker starts, so
    /// this is the one place where re-parsing it would matter.
    const HOSTILE: &str = "need it; rm -rf / $(id) `id` && echo 'ok' | tee /tmp/x";

    #[test]
    fn hook_gets_six_separate_arguments() {
        let cmd = hook_command(
            Path::new("/notify"),
            "request",
            "41207.1",
            "shellcheck",
            HOSTILE,
            2,
            "pi /workspace/llm-custody",
        );
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(cmd.get_program(), OsStr::new("/notify"));
        assert_eq!(args.len(), 6);
        assert_eq!(args[0], OsStr::new("request"));
        assert_eq!(args[1], OsStr::new("41207.1"));
        assert_eq!(args[2], OsStr::new("shellcheck"));
        // Whole and unsplit, which is the entire point of the argv form.
        assert_eq!(args[3], OsStr::new(HOSTILE));
        assert_eq!(args[4], OsStr::new("2"));
        assert_eq!(args[5], OsStr::new("pi /workspace/llm-custody"));
    }

    /// The mount launcher gets the operator's mode and the agent's path as
    /// separate arguments, the path after a `--` so a path starting with a
    /// dash cannot read as an option.
    #[test]
    fn mount_launcher_gets_separate_arguments() {
        let cmd = mount_command(Path::new("/run/x/mount"), "limited", "/srv/-weird; rm -rf /");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(cmd.get_program(), OsStr::new("/run/x/mount"));
        assert_eq!(args.len(), 5);
        assert_eq!(args[0], OsStr::new("add"));
        assert_eq!(args[1], OsStr::new("--mode"));
        assert_eq!(args[2], OsStr::new("limited"));
        assert_eq!(args[3], OsStr::new("--"));
        assert_eq!(args[4], OsStr::new("/srv/-weird; rm -rf /"));
    }

    /// The domain launcher gets `add`, `--persist` only when the operator
    /// chose it, and the name after a `--`.
    #[test]
    fn domain_launcher_gets_separate_arguments() {
        let cmd = domain_command(Path::new("/run/x/domain"), false, "registry.npmjs.org");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(cmd.get_program(), OsStr::new("/run/x/domain"));
        assert_eq!(args, [OsStr::new("add"), OsStr::new("--"), OsStr::new("registry.npmjs.org")]);

        let cmd = domain_command(Path::new("/run/x/domain"), true, "-x.example.com");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(
            args,
            [
                OsStr::new("add"),
                OsStr::new("--persist"),
                OsStr::new("--"),
                OsStr::new("-x.example.com")
            ]
        );
    }

    /// Writes an executable /bin/sh script into a fresh temp dir. None when
    /// there is no /bin/sh, for the same reason as the hook test below.
    fn fake_launcher(tag: &str, body: &str) -> Option<(PathBuf, PathBuf)> {
        if !Path::new("/bin/sh").exists() {
            eprintln!("SKIP: no /bin/sh to write a launcher with");
            return None;
        }
        let dir = std::env::temp_dir().join(format!("llm-custody-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let launcher = dir.join("domain");
        // `@DIR@` rather than dirname "$0": a builtin-only script does not
        // depend on what PATH the test harness happens to have.
        let body = body.replace("@DIR@", &dir.display().to_string());
        fs::write(&launcher, format!("#!/bin/sh\n{body}")).expect("write launcher");
        fs::set_permissions(&launcher, fs::Permissions::from_mode(0o755)).expect("chmod launcher");
        Some((dir, launcher))
    }

    /// End to end against a launcher that records its argv. The name here
    /// is one validation refuses (asserted first), so this proves the argv
    /// form holds on its own, not only because the validator ran.
    #[test]
    fn a_hostile_domain_arrives_as_one_inert_argument() {
        let _exec = util::exec_test_lock();
        let tmp = std::env::temp_dir().join(format!("llm-custody-dombait-{}", std::process::id()));
        let bait = tmp.join("executed");
        let name = format!("x.com; touch {b} $(touch {b}) `touch {b}`", b = bait.display());
        assert!(proto::validate_domain(&name).is_err());
        assert!(proto::validate_domain(HOSTILE).is_err());

        let (dir, launcher) = match fake_launcher(
            "domain-argv",
            "printf '%s\\n' \"$@\" > '@DIR@/argv'\nprintf 'x.com\\tpersist\\n'\n",
        ) {
            Some(v) => v,
            None => return,
        };
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).expect("bait dir");

        let scope = run_domain(&launcher, true, &name).expect("launcher ran");
        assert_eq!(scope, "persist");
        let got: Vec<String> = fs::read_to_string(dir.join("argv"))
            .expect("launcher output")
            .lines()
            .map(String::from)
            .collect();
        assert_eq!(got, ["add", "--persist", "--", name.as_str()]);
        assert!(!bait.exists(), "the name was interpreted, not passed");

        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&tmp);
    }

    /// Exit 2 is the launcher refusing the name, and its stderr is the reason.
    #[test]
    fn a_refused_domain_reports_the_launchers_reason() {
        let _exec = util::exec_test_lock();
        let (dir, launcher) =
            match fake_launcher("domain-refuse", "echo 'domain: invalid name' >&2\nexit 2\n") {
                Some(v) => v,
                None => return,
            };
        let err = run_domain(&launcher, false, "x.com").unwrap_err();
        assert!(err.msg.contains("refused x.com"), "{}", err.msg);
        assert!(err.msg.contains("invalid name"), "{}", err.msg);
        let _ = fs::remove_dir_all(&dir);
    }

    /// The reply fields are the wire contract with the jail client and the
    /// operator CLI, so their names and presence are pinned here.
    #[test]
    fn approval_fields_per_kind_and_reader() {
        let pkg = Done::Package { commands: vec!["rg".to_string(), "fd".to_string()] };
        assert_eq!(pkg.fields(false), vec![("commands", "rg fd".to_string())]);
        assert_eq!(pkg.fields(true), vec![("commands", "rg fd".to_string())]);
        // Nothing new on PATH: the client gets no field, the operator an
        // empty one.
        let none = Done::Package { commands: Vec::new() };
        assert!(none.fields(false).is_empty());
        assert_eq!(none.fields(true), vec![("commands", String::new())]);

        let mount = Done::Mount { guest: "/mnt/x".to_string(), mode: "ro".to_string() };
        assert_eq!(mount.fields(false), vec![("guest", "/mnt/x".to_string())]);
        assert_eq!(
            mount.fields(true),
            vec![("guest", "/mnt/x".to_string()), ("mode", "ro".to_string())]
        );

        let domain = Done::Domain { scope: "session".to_string() };
        assert_eq!(domain.fields(false), vec![("scope", "session".to_string())]);
        assert_eq!(domain.fields(true), domain.fields(false));

        assert_eq!(pkg.verb(), "installed");
        assert_eq!(mount.verb(), "mounted");
        assert_eq!(domain.verb(), "allowed");
    }

    #[test]
    fn empty_fields_keep_their_place() {
        // `start` and `dropped` carry no attribute and no reason. An empty
        // string is still an argument: a hook reading its fourth and sixth
        // positional must not find the label and the count shifted into them.
        let cmd = hook_command(Path::new("/notify"), "start", "", "", "", 0, "pi /w");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(args.len(), 6);
        assert_eq!(args[2], OsStr::new(""));
        assert_eq!(args[3], OsStr::new(""));
        assert_eq!(args[4], OsStr::new("0"));
        assert_eq!(args[5], OsStr::new("pi /w"));
    }

    /// The same claim, end to end against a hook that reports what it was
    /// actually handed. The test above asserts what gets built; this asserts
    /// what arrives, and that nothing in the reason ran on the way.
    #[test]
    fn a_hostile_reason_arrives_as_one_inert_argument() {
        let _exec = util::exec_test_lock();
        // The hook has to be something executable, and /bin/sh is the only
        // interpreter present both on a developer's host and inside the nix
        // build sandbox. Skipping beats failing a build over the test
        // harness's own dependency.
        if !Path::new("/bin/sh").exists() {
            eprintln!("SKIP: no /bin/sh to write a hook with");
            return;
        }
        let dir = std::env::temp_dir().join(format!("llm-custody-hook-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let argv_out = dir.join("argv");
        let bait = dir.join("executed");

        // A reason that creates `bait` if, and only if, some layer re-parses
        // it as shell. Both forms of substitution, since a hook invoked
        // through `sh -c "$*"` would expand either.
        let reason = format!(
            "needs it; touch {bait} $(touch {bait}) `touch {bait}`",
            bait = bait.display()
        );

        let hook = dir.join("notify");
        // One argument per line: no value the broker sends can contain a
        // newline (validate_attr and validate_reason reject them), so lines
        // are an unambiguous framing here.
        fs::write(
            &hook,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", argv_out.display()),
        )
        .expect("write hook");
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).expect("chmod hook");

        let status = hook_command(&hook, "request", "41207.1", "shellcheck", &reason, 1, "pi /w")
            .status()
            .expect("spawn hook");
        assert!(status.success(), "hook exited {status}");

        let got: Vec<String> =
            fs::read_to_string(&argv_out).expect("hook output").lines().map(String::from).collect();
        assert_eq!(got.len(), 6, "hook saw {got:?}");
        assert_eq!(got[3], reason);
        assert!(!bait.exists(), "the reason was interpreted, not passed");

        let _ = fs::remove_dir_all(&dir);
    }
}
