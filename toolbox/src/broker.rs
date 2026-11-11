//! `serve`: the per-jail request broker.
//!
//! One of these is started by each jail runner. It owns two Unix sockets under
//! `$XDG_RUNTIME_DIR/llm-custody/brokers/<broker-id>/`, holds requests in
//! memory while the operator decides, and performs an approved install through
//! exactly the same `Toolbox::add` the host CLI uses - there is no second
//! install path to keep in step.

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

use crate::json::{self, Json};
use crate::paths::Layout;
use crate::proto;
use crate::toolbox::Toolbox;
use crate::util::{self, fail, Result};

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
}

enum Outcome {
    Approved { commands: Vec<String> },
    Denied(String),
    /// Nobody answered before the hold time ran out. Separate from `Denied`
    /// because the agent treats a denial as final.
    TimedOut(String),
    Failed(String),
}

struct Pending {
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
    /// Last count published to the terminal. Emission is on change only -
    /// nothing is gained by repeating a count, and an agent that spams
    /// requests should not get to decide how often this writes to a terminal.
    last_published: Mutex<Option<usize>>,
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

fn cleanup(dir: &Path) {
    let _ = fs::remove_file(dir.join(proto::REQUEST_SOCKET));
    let _ = fs::remove_file(dir.join(proto::CONTROL_SOCKET));
    let _ = fs::remove_file(dir.join(proto::META_FILE));
    let _ = fs::remove_file(dir.join(proto::PENDING_FILE));
    let _ = fs::remove_dir(dir);
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
            return fail("this socket only accepts package requests");
        }

        let attr = msg.str_field("attr").to_string();
        let reason = msg.str_field("reason").trim().to_string();
        proto::validate_attr(&attr)?;
        proto::validate_reason(&reason)?;

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
                    attr: attr.clone(),
                    reason: reason.clone(),
                    created: util::now_secs(),
                    tx,
                },
            );
        }
        util::note(format!("request {id}: {attr} ({})", if reason.is_empty() { "no reason given" } else { &reason }));
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
                .str("attr", &attr)
                .num("timeout", self.timeout.as_secs())
                .finish(),
        )?;

        let outcome = self.wait_for_outcome(&id, &rx, &mut reader, stream);
        let reply = match outcome {
            Some(Outcome::Approved { commands }) => {
                let mut o = proto::ok_response().str("id", &id).str("attr", &attr);
                if !commands.is_empty() {
                    o = o.str("commands", &commands.join(" "));
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
                let reply = self.approve(msg.str_field("id"))?;
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
    /// the moment this returns, not just the one that asked.
    fn approve(&self, id: &str) -> Result<String> {
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
        util::note(format!("request {id}: approved, installing {}", p.attr));
        match self.toolbox.add(std::slice::from_ref(&p.attr)) {
            Ok(outcome) => {
                let commands = outcome.new_commands.clone();
                // A client that gave up in the meantime is not an error: the
                // package is installed and the next jail to look will find it.
                let delivered = p.tx.send(Outcome::Approved { commands: commands.clone() }).is_ok();
                let mut o = proto::ok_response()
                    .str("id", id)
                    .str("attr", &p.attr)
                    .str("commands", &commands.join(" "));
                if !delivered {
                    o = o.str("note", "installed, but the jail client had already gone away");
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

/// Everything the host CLI needs to talk to one broker.
pub struct BrokerHandle {
    pub id: String,
    pub dir: PathBuf,
    pub label: String,
}

/// Live brokers, with dead registrations cleaned up on the way past.
pub fn discover(layout: &Layout) -> Vec<BrokerHandle> {
    let root = layout.brokers();
    let entries = match fs::read_dir(&root) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for entry in entries.filter_map(|e| e.ok()) {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let id = entry.file_name().to_string_lossy().into_owned();
        let meta = match fs::read_to_string(dir.join(proto::META_FILE)) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let parsed = match json::parse(meta.trim()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let pid = parsed.get("pid").and_then(Json::as_u64).unwrap_or(0) as u32;
        // A broker killed outright (SIGKILL, a reboot with a persistent
        // runtime dir) never ran its handler. Nothing else will ever clean
        // this up, and leaving it makes `requests` report a queue that cannot
        // be answered.
        if pid == 0 || !util::pid_alive(pid) {
            cleanup(&dir);
            continue;
        }
        out.push(BrokerHandle { id, dir, label: parsed.str_field("label").to_string() });
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

/// One control request/response round trip.
pub fn control_call(handle: &BrokerHandle, msg: &str, read_timeout: Option<Duration>) -> Result<Json> {
    let path = handle.dir.join(proto::CONTROL_SOCKET);
    let mut stream = util::ctx(
        UnixStream::connect(&path),
        format!("connecting to broker {}", handle.id),
    )?;
    // A broker that has wedged must not wedge the caller with it. The read
    // side is the caller's choice because the two uses differ by orders of
    // magnitude: listing reads a map, approving waits on a nix build.
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_read_timeout(read_timeout);
    proto::write_message(&mut stream, msg)?;
    let peer = util::ctx(stream.try_clone(), "cloning control socket")?;
    let mut reader = BufReader::new(peer);
    match proto::read_message(&mut reader)? {
        Some(v) => Ok(v),
        None => fail(format!("broker {} closed the connection without answering", handle.id)),
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
