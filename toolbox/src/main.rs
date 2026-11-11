//! `llm-custody`: the host side of the sandbox, in one command.
//!
//! Starts a jailed tool, attaches a host tree to a running one, folds its
//! work back, answers what it asked for, and owns the package profile it sees
//! on its PATH. The pieces themselves have not moved: the runners are still
//! shell scripts this only execs, the mount controller and the sync-back are
//! still reached through the launchers a session registers, and `serve` is
//! still started by the runner rather than by hand.
//!
//! The jail cannot install anything itself - read-only /nix/store, no binary
//! cache in the domain whitelist - so this is the half of that which runs
//! where realizing a derivation is possible. Everything an agent can reach
//! goes through `serve`, and an operator still has to say yes.

mod broker;
mod brokerctl;
mod json;
mod launch;
mod nix;
mod paths;
mod proto;
mod request;
mod session;
mod toolbox;
mod util;

use std::io::{BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::time::Duration;

use paths::Layout;
use session::Registry;
use toolbox::{LeaseState, PinResult, Toolbox};
use util::{usage_err, Result};

fn usage() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pid PID] [--pause] <command> [ARG...]

  launch TOOL ...   start a sandboxed tool, no TOOL lists them
  mount ...         attach a host tree to a live session, or detach one
  sync ...          fold a live session's isolated trees back to the host
  session list      the live sessions and what each one has outstanding
  request ...       the package and mount requests jailed agents wait on
  toolbox ...       the package profile every jail sees on its PATH
  lease ...         how long an added package survives without being used
  serve             the per-jail request broker, started by the runner

Options:
  --dir PATH   toolbox profile to act on (toolbox, lease, request, serve).
               Without it: the toolbox of the most recently started session
               ($XDG_RUNTIME_DIR/llm-custody/current.toolbox), else
               $LLMCUSTODY_TOOLBOX_DIR or ~/.config/llm-custody/toolbox
  --pid PID    which live session to act on (mount, sync, request).
               Without it: the most recently started one
  --pause      wait for a keypress before exiting, so a pane a terminal
               keybinding spawned does not close over the output

llm-custody <command> --help explains one command, as does
llm-custody help <command>.
"
    );
}

fn usage_mount() {
    print!(
        "\
Usage: llm-custody [--pid PID] [--pause] mount [COMMAND [ARG...]]

Attach a host tree to a running jail, or detach one. The session's own mount
controller does the work; this only finds it.

  add [--mode ro|full|limited|none|overlay] [--guest PATH] [--name NAME] HOSTPATH
                   ro is the default. full hands the jail the real tree
                   read-write, limited and none bind a copy that syncs back
                   on request, overlay is copy-on-write
  remove [--auto|--discard] NAME|GUESTPATH   (aliases: rm, umount)
  list             what this session has attached
  docks            the guest directories a live mount can go under
  (no command)     prompt for a host path and add it read-only

A mount lands under a dock (/workspace or /mnt) so it can be detached again;
anything else is fixed for the life of the session.
"
    );
}

fn usage_sync() {
    print!(
        "\
Usage: llm-custody [--pid PID] [--pause] sync [-- ARG...]

Fold the isolated trees of a live session back into the host trees they were
copied from, without waiting for the session to end. Arguments after -- go to
the session's own sync-back (--auto to skip the per-tree prompt, --discard to
throw the jail's version away).

A session that works in the host trees directly has nothing to fold back,
which is reported and is not an error.
"
    );
}

fn usage_session() {
    print!(
        "\
Usage: llm-custody session list

One block per live session: pid, tool and workspace, then the git mode,
whether the workspace is an overlay, how many paths are written but not
synced, how many trees are attached, how many requests are waiting, and the
sync and mount launchers of that session.

Sessions register under $XDG_RUNTIME_DIR/llm-custody as <pid>.state.
"
    );
}

fn usage_request() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pid PID] request <command> [ARG...]

What jailed agents have asked for and are blocked on. A package goes into the
toolbox profile, a mount attaches a host directory to the jail that asked.

  list             pending requests from every running jail (alias: ls)
                   [--json] machine-readable, for a terminal integration
  answer           the same queue, interactively: pick a numbered row to
                   approve or deny it without typing a request id (a mount
                   then asks for its mode)
  approve ID       grant it and unblock the jail
                   [--mode ro|full|limited|none|overlay] how a mount is
                   attached (default ro, ignored for a package)
  deny ID          refuse it [--reason TEXT]

--pid restricts all of this to one session's broker.
"
    );
}

fn usage_toolbox() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pause] toolbox <command> [ARG...]

The package profile bound into every jail at /toolbox and prepended to its
PATH. Adding to it is live: a running jail finds the command on its next PATH
lookup.

  add PKG...        install nixpkgs attributes and start their {days}-day lease.
                    ALSO HOW YOU RENEW ONE: re-running add on something
                    already installed skips the install and just pushes its
                    lease out, so answering the same request again keeps the
                    package alive for another {days} days
                    (aliases: install, i)
  remove PKG...     remove them again (alias: rm)
  list              show what is installed
  upgrade [PKG...]  rebuild installed packages against their flake refs
  (no command)      prompt for packages to add

A bare name is resolved against $LLMCUSTODY_TOOLBOX_FLAKE (default nixpkgs);
anything containing # or : is passed to nix verbatim as a flake reference.
Jailed clients may only ask for bare attributes.

The whole request block an agent printed can be pasted as-is:
  llm-custody toolbox add required packages: lua5_4, shellcheck
",
        days = paths::DEFAULT_LEASE_DAYS
    );
}

fn usage_lease() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pause] lease <command> [ARG...]

A package added to the toolbox holds a {days}-day lease, so provisioning is not
a one-way ratchet: what an afternoon needed does not stay on every future
jail's PATH, with its whole closure pinned, until someone remembers to look.

  list              each package, the age of its lease and when it expires;
                    the unleased ones are the permanent ones (alias: ls)
                    [--older-than PERIOD]
  renew PKG...      push a lease out without touching the profile
  pin PKG...        drop the lease, making the package permanent
                    (add or renew it again to put it back under a lease)
  prune             remove the packages whose lease has expired, then drop
                    the generations that held them. Every jail start does
                    this on its own, so running it by hand is for pruning
                    early or with another lifetime
                    [--older-than PERIOD] lifetime to apply, e.g. 30d
                    [--dry-run] report without removing
  gc                drop the profile generations every add leaves behind
                    [--older-than PERIOD] [--dry-run]
",
        days = paths::DEFAULT_LEASE_DAYS
    );
}

fn usage_serve() {
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

Also runs one prune and gc in the background, which is what keeps expired
leases from accumulating without anyone remembering to look.
$LLMCUSTODY_TOOLBOX_AUTOPRUNE=0 turns that off.
"
    );
}

/// `llm-custody help mount` and `llm-custody mount --help` are the same
/// question asked two ways, so they end in the same place.
fn help_for(topic: Option<&str>) -> Result<()> {
    match topic {
        None => usage(),
        Some("launch") => launch::usage(),
        Some("mount") => usage_mount(),
        Some("sync") => usage_sync(),
        Some("session") => usage_session(),
        Some("request") => usage_request(),
        Some("toolbox") => usage_toolbox(),
        Some("lease") => usage_lease(),
        Some("serve") => usage_serve(),
        Some("custody-request") => request::usage(),
        Some(other) => return usage_err(format!("no help for: {other} (try --help)")),
    }
    Ok(())
}

/// The aliases accepted for typing comfort, resolved to the one name each
/// dispatch below knows. One table rather than alternatives spread over the
/// match arms: the accepted set stays visible, and a `rm` that means `remove`
/// in one place cannot quietly mean something else in another.
fn unalias<'a>(group: &str, cmd: &'a str) -> &'a str {
    match (group, cmd) {
        ("toolbox", "install") | ("toolbox", "i") => "add",
        ("toolbox", "rm") => "remove",
        ("mount", "rm") | ("mount", "umount") => "remove",
        (_, "ls") => "list",
        _ => cmd,
    }
}

/// True when the first argument is a request for this command's own usage.
/// Only the first: `mount add --help` belongs to the mount controller, and
/// `launch pi --help` to pi's runner.
fn wants_help(args: &[String]) -> bool {
    matches!(args.first().map(String::as_str), Some("-h") | Some("--help") | Some("help"))
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();

    // `custody-request` is this binary under another name, symlinked into the
    // jail's PATH by the runner. Dispatching on argv[0] keeps it one build
    // artifact and one copy of the protocol code.
    let called_as = argv
        .first()
        .map(PathBuf::from)
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    if called_as == "custody-request" {
        finish(request::run(&argv[1..]), false, "custody-request");
    }

    let g = match parse_global(&argv[1..]) {
        Ok(v) => v,
        Err(e) => finish(Err(e), false, "llm-custody"),
    };
    let pause = g.pause;
    finish(run(g), pause, "llm-custody");
}

/// Prints whatever went wrong and leaves with the right status. A
/// keybinding-spawned pane dies with the process, taking the nix build log
/// with it, so `--pause` holds it open - including, deliberately, for a failed
/// install, which is the case actually worth reading.
///
/// An empty message means the failure has already been reported in more detail
/// than a single line could carry - `custody-request` says something per
/// attribute and then fails as a whole, and a launcher this only ran has
/// already spoken in its own voice.
fn finish(r: Result<()>, pause: bool, prefix: &str) -> ! {
    let code = match r {
        Ok(()) => 0,
        Err(e) => {
            if !e.msg.is_empty() {
                eprintln!("{prefix}: {}", e.msg);
            }
            e.code
        }
    };
    if pause {
        eprint!("\n[enter to close] ");
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
    }
    std::process::exit(code)
}

struct Global {
    dir: Option<PathBuf>,
    /// Which live session, for the commands that act on one.
    pid: Option<String>,
    pause: bool,
    args: Vec<String>,
}

impl Global {
    /// The toolbox profile and, where it matters, the one session this
    /// invocation may see.
    fn layout(&self) -> Result<Layout> {
        Ok(Layout::resolve(self.dir.clone())?.with_broker_filter(self.pid.clone()))
    }

    fn toolbox(&self) -> Result<Toolbox> {
        Ok(Toolbox::new(self.layout()?))
    }
}

/// Global options come before the command; the first word that is not one of
/// them starts the command and everything after it belongs to that command.
fn parse_global(args: &[String]) -> Result<Global> {
    let mut dir = None;
    let mut pid = None;
    let mut pause = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                usage();
                std::process::exit(0);
            }
            "--dir" => {
                i += 1;
                match args.get(i) {
                    Some(v) => dir = Some(PathBuf::from(v)),
                    None => return usage_err("--dir needs an argument"),
                }
            }
            "--pid" => {
                i += 1;
                match args.get(i) {
                    Some(v) if session::pid_ok(v) => pid = Some(v.clone()),
                    Some(v) => return usage_err(format!("not a pid: {v}")),
                    None => return usage_err("--pid needs an argument"),
                }
            }
            "--pause" => pause = true,
            _ => break,
        }
        i += 1;
    }
    Ok(Global { dir, pid, pause, args: args[i..].to_vec() })
}

fn run(g: Global) -> Result<()> {
    let (cmd, rest): (String, Vec<String>) = match g.args.split_first() {
        Some((c, r)) => (c.clone(), r.to_vec()),
        // Nothing to guess at with eight commands: show them.
        None => {
            usage();
            return Ok(());
        }
    };
    match cmd.as_str() {
        "help" => help_for(rest.first().map(String::as_str)),
        "launch" => launch::run(&rest),
        "mount" => cmd_mount(&g, &rest),
        "sync" => cmd_sync(&g, &rest),
        "session" => cmd_session(&rest),
        "request" => cmd_request(&g, &rest),
        "toolbox" => cmd_toolbox(&g, &rest),
        "lease" => cmd_lease(&g, &rest),
        "serve" => {
            if wants_help(&rest) {
                usage_serve();
                return Ok(());
            }
            cmd_serve(g.toolbox()?, &rest)
        }
        other => usage_err(format!("unknown command: {other} (try --help)")),
    }
}

fn cmd_mount(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) {
        usage_mount();
        return Ok(());
    }
    let target = Registry::open().resolve_mount(g.pid.as_deref())?;
    let args = if args.is_empty() { session::prompt_for_mount()? } else { mount_args(args) };
    session::run_launcher(&target, &args, g.pause)
}

/// What the session's mount controller is handed. Only the subcommand is
/// touched, and only to resolve an alias: everything else is the controller's
/// to parse, and a mount path must arrive exactly as it was typed.
fn mount_args(args: &[String]) -> Vec<String> {
    let mut args = args.to_vec();
    if let Some(first) = args.first_mut() {
        *first = unalias("mount", first).to_string();
    }
    args
}

fn cmd_sync(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) {
        usage_sync();
        return Ok(());
    }
    // A leading `--` only separates our arguments from the sync-back's, which
    // is how the shell front end spelled it and what muscle memory types.
    let args = match args.split_first() {
        Some((first, rest)) if first == "--" => rest.to_vec(),
        _ => args.to_vec(),
    };
    match Registry::open().resolve_sync(g.pid.as_deref())? {
        session::SyncTarget::Launcher(p) => session::run_launcher(&p, &args, g.pause),
        // Not an error: the operator asked for their changes on the host and
        // they are already there.
        session::SyncTarget::Direct { pid, workspace, reason } => {
            eprintln!("nothing to sync: pid {pid} works in {workspace} directly");
            eprintln!("                 {reason} - the host tree already has the changes");
            Ok(())
        }
    }
}

fn cmd_session(args: &[String]) -> Result<()> {
    if wants_help(args) || args.is_empty() {
        usage_session();
        return Ok(());
    }
    match unalias("session", &args[0]) {
        "list" => Registry::open().list(),
        other => usage_err(format!("session: unknown command: {other} (try --help)")),
    }
}

fn cmd_request(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) || args.is_empty() {
        usage_request();
        return Ok(());
    }
    let tb = g.toolbox()?;
    let (cmd, rest) = args.split_first().expect("checked above");
    match unalias("request", cmd) {
        "list" => cmd_requests(&tb, rest),
        "answer" => brokerctl::answer(&tb.layout),
        "approve" => cmd_approve(&tb, rest),
        "deny" => cmd_deny(&tb, rest),
        other => usage_err(format!("request: unknown command: {other} (try --help)")),
    }
}

fn cmd_toolbox(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) {
        usage_toolbox();
        return Ok(());
    }
    let tb = g.toolbox()?;
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.clone(), r.to_vec()),
        // A keybinding's way in: ask for the one thing it cannot know.
        None => ("add".to_string(), prompt_for_add()?),
    };
    match unalias("toolbox", &cmd) {
        "add" => cmd_add(&tb, &normalize(&rest)?),
        "remove" => cmd_remove(&tb, &normalize(&rest)?),
        "list" => tb.list(),
        "upgrade" => cmd_upgrade(&tb, &rest),
        other => usage_err(format!("toolbox: unknown command: {other} (try --help)")),
    }
}

fn cmd_lease(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) || args.is_empty() {
        usage_lease();
        return Ok(());
    }
    let tb = g.toolbox()?;
    let (cmd, rest) = args.split_first().expect("checked above");
    match unalias("lease", cmd) {
        "list" => cmd_leases(&tb, rest),
        "renew" => cmd_renew(&tb, &normalize(rest)?),
        "pin" => cmd_pin(&tb, &normalize(rest)?),
        "prune" => cmd_prune(&tb, rest),
        "gc" => cmd_gc(&tb, rest),
        other => usage_err(format!("lease: unknown command: {other} (try --help)")),
    }
}

/// The typed line comes back as one argument, which normalize() splits - it
/// has to handle a pasted request block anyway.
fn prompt_for_add() -> Result<Vec<String>> {
    if !std::io::stdin().is_terminal() {
        usage_toolbox();
        std::process::exit(0);
    }
    eprint!("package(s) to add: ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    if line.trim().is_empty() {
        return usage_err("nothing to add");
    }
    Ok(vec![line.trim().to_string()])
}

/// Agents are asked to print their request as `required packages: a, b`, so
/// that shape is accepted verbatim - the operator pastes the line instead of
/// retyping the names out of it. Commas are separators in that format and are
/// never part of an attribute name.
fn normalize(args: &[String]) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for arg in args {
        for word in arg.split([',', ' ', '\t']) {
            let w = word.trim();
            if w.is_empty() {
                continue;
            }
            if matches!(
                w,
                "required" | "required:" | "good-to-have" | "good-to-have:" | "packages"
                    | "packages:"
            ) {
                continue;
            }
            out.push(w.to_string());
        }
    }
    if out.is_empty() {
        return usage_err("no package names given");
    }
    Ok(out)
}

fn cmd_add(tb: &Toolbox, attrs: &[String]) -> Result<()> {
    let outcome = tb.add(attrs)?;
    if !outcome.renewed.is_empty() {
        util::note(format!(
            "already installed, lease renewed: {}",
            outcome.renewed.join(" ")
        ));
    }
    if outcome.unleased {
        util::note(
            "could not read element names from nix - no lease recorded, these will never expire",
        );
    }
    if !outcome.installed.is_empty() {
        if outcome.new_commands.is_empty() {
            util::note("no new commands (already present, or the package ships no bin/)");
        } else {
            util::note(format!(
                "now on the jail PATH: {}",
                outcome.new_commands.join(" ")
            ));
        }
    }
    Ok(())
}

fn cmd_remove(tb: &Toolbox, names: &[String]) -> Result<()> {
    tb.remove(names)
}

fn cmd_renew(tb: &Toolbox, names: &[String]) -> Result<()> {
    for (name, was_permanent) in tb.renew(names)? {
        if was_permanent {
            util::note(format!("{name} was permanent, now leased again"));
        } else {
            util::note(format!("{name} renewed"));
        }
    }
    Ok(())
}

fn cmd_pin(tb: &Toolbox, names: &[String]) -> Result<()> {
    for (name, r) in tb.pin(names)? {
        match r {
            PinResult::Pinned => util::note(format!("{name} pinned, it will never be pruned")),
            PinResult::AlreadyPermanent => {
                util::note(format!("{name} holds no lease, already permanent"))
            }
            PinResult::NotInstalled => util::note(format!(
                "{name} is not an installed element - check the list command"
            )),
        }
    }
    Ok(())
}

fn cmd_upgrade(tb: &Toolbox, args: &[String]) -> Result<()> {
    if let Some(a) = args.iter().find(|a| a.starts_with('-')) {
        return usage_err(format!("upgrade: unknown option: {a} (it takes package names only)"));
    }
    if tb.upgrade(args)? {
        util::note("live for running jails on their next PATH lookup");
        util::note("the previous generation is still pinned - run gc to drop it");
    } else {
        util::note("nothing changed, the installed refs already resolve to this");
    }
    Ok(())
}

/// `--older-than`, shared by leases, prune and gc. Returns the raw string too,
/// because gc hands its period to nix rather than interpreting it here.
fn take_period(args: &[String], cmd: &str) -> Result<(Option<String>, bool)> {
    let mut period = None;
    let mut dry = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--older-than" => {
                i += 1;
                match args.get(i) {
                    Some(v) => period = Some(v.clone()),
                    None => return usage_err("--older-than needs a period, e.g. 30d"),
                }
            }
            "--dry-run" => dry = true,
            a => return usage_err(format!("{cmd}: unknown option: {a} (try --help)")),
        }
        i += 1;
    }
    Ok((period, dry))
}

fn period_or_default(tb: &Toolbox, period: Option<String>) -> Result<Duration> {
    match period {
        Some(p) => util::parse_duration(&p, 'd'),
        None => Ok(tb.layout.lease_period),
    }
}

fn cmd_leases(tb: &Toolbox, args: &[String]) -> Result<()> {
    let (period, dry) = take_period(args, "leases")?;
    if dry {
        return usage_err("leases: --dry-run makes no sense here, it never changes anything");
    }
    let period = period_or_default(tb, period)?;
    let rows = tb.lease_report(period)?;
    if rows.is_empty() {
        util::note(format!("nothing installed in {}", tb.layout.dir.display()));
        return Ok(());
    }
    let w = rows.iter().map(|r| r.name.len()).max().unwrap_or(8).max(8);
    for row in &rows {
        let state = match row.state {
            LeaseState::Live { age, left } => format!(
                "leased {} ago, expires in {}",
                util::human_duration(Duration::from_secs(age)),
                util::human_duration(Duration::from_secs(left))
            ),
            LeaseState::Expired { age } => format!(
                "leased {} ago, EXPIRED",
                util::human_duration(Duration::from_secs(age))
            ),
            LeaseState::Orphaned { age } => format!(
                "leased {} ago, EXPIRED, no such profile element",
                util::human_duration(Duration::from_secs(age))
            ),
            LeaseState::Permanent => "permanent (no lease)".to_string(),
        };
        println!("{:<w$}  {}", row.name, state, w = w);
    }
    Ok(())
}

fn cmd_prune(tb: &Toolbox, args: &[String]) -> Result<()> {
    let (period, dry) = take_period(args, "prune")?;
    let period = period_or_default(tb, period)?;
    let outcome = tb.prune(period, dry)?;

    for name in &outcome.orphaned {
        util::note(format!(
            "{name}: lease expired, no such profile element - dropping the lease only"
        ));
    }
    for name in &outcome.removed {
        util::note(format!("{name}: lease expired"));
    }
    if outcome.removed.is_empty() && outcome.orphaned.is_empty() {
        util::note(format!(
            "no lease is older than {} (see: leases)",
            util::human_duration(period)
        ));
        return Ok(());
    }
    if outcome.dry_run {
        util::note("dry run, nothing removed");
        return Ok(());
    }
    util::note(format!(
        "{} package(s) pruned, {} generation(s) dropped",
        outcome.removed.len(),
        outcome.generations_dropped
    ));
    // Worth saying because the removal is live: a command a running jail had a
    // moment ago can be gone from its next PATH lookup. That is what a lease
    // is for, and the session carries on without it.
    util::note("running jails lose these from their PATH immediately");
    util::note("store paths are only unpinned - run nix-collect-garbage to reclaim them");
    Ok(())
}

fn cmd_gc(tb: &Toolbox, args: &[String]) -> Result<()> {
    let (period, dry) = take_period(args, "gc")?;
    let dropped = tb.gc(period.as_deref(), dry)?;
    util::note(format!("{dropped} generation(s) dropped"));
    // Said plainly because the obvious next question is why the store did not
    // shrink: this only unpins, it frees nothing on its own.
    util::note("store paths are only unpinned - run nix-collect-garbage to reclaim them");
    Ok(())
}

fn cmd_serve(tb: Toolbox, args: &[String]) -> Result<()> {
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
    broker::serve(
        tb.layout,
        broker::ServeOpts { broker_id, label, timeout, uservar, notify_hook, mount_cmd },
    )
}

fn cmd_requests(tb: &Toolbox, args: &[String]) -> Result<()> {
    match args.first().map(String::as_str) {
        None => brokerctl::requests(&tb.layout),
        Some("--json") => brokerctl::requests_json(&tb.layout),
        Some(a) => usage_err(format!("requests: unknown option: {a} (try --help)")),
    }
}

fn cmd_approve(tb: &Toolbox, args: &[String]) -> Result<()> {
    let mut id = None;
    let mut mode = String::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--mode" => {
                i += 1;
                match args.get(i) {
                    Some(v) => mode = v.clone(),
                    None => return usage_err("--mode needs a value"),
                }
            }
            a if a.starts_with('-') => return usage_err(format!("approve: unknown option: {a}")),
            a => id = Some(a.to_string()),
        }
        i += 1;
    }
    match id {
        Some(id) => brokerctl::approve(&tb.layout, &id, &mode),
        None => usage_err("approve needs a request id - see the requests command"),
    }
}

fn cmd_deny(tb: &Toolbox, args: &[String]) -> Result<()> {
    let mut id = None;
    let mut reason = String::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--reason" => {
                i += 1;
                match args.get(i) {
                    Some(v) => reason = v.clone(),
                    None => return usage_err("--reason needs a value"),
                }
            }
            a if a.starts_with('-') => return usage_err(format!("deny: unknown option: {a}")),
            a => id = Some(a.to_string()),
        }
        i += 1;
    }
    match id {
        Some(id) => brokerctl::deny(&tb.layout, &id, &reason),
        None => usage_err("deny needs a request id - see the requests command"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(line: &str) -> Vec<String> {
        line.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn global_options_are_only_the_ones_before_the_command() {
        let g = parse_global(&argv("--dir /tmp/tb --pid 4123 --pause request list --json")).unwrap();
        assert_eq!(g.dir, Some(PathBuf::from("/tmp/tb")));
        assert_eq!(g.pid.as_deref(), Some("4123"));
        assert!(g.pause);
        assert_eq!(g.args, argv("request list --json"));

        // The same spellings after the command belong to the command.
        let g = parse_global(&argv("mount add --mode full --pid 4123 /srv")).unwrap();
        assert_eq!(g.pid, None);
        assert!(!g.pause);
        assert_eq!(g.args, argv("mount add --mode full --pid 4123 /srv"));

        assert_eq!(parse_global(&argv("session list")).unwrap().args, argv("session list"));
        assert!(parse_global(&[]).unwrap().args.is_empty());
    }

    #[test]
    fn a_pid_is_checked_before_it_is_used_as_a_filename() {
        for bad in ["../../etc", "4123/x", "", "pi"] {
            match parse_global(&["--pid".to_string(), bad.to_string()]) {
                Err(e) => assert_eq!(e.code, util::EXIT_USAGE, "accepted --pid {bad:?}"),
                Ok(_) => panic!("accepted --pid {bad:?}"),
            }
        }
        assert!(parse_global(&argv("--pid")).is_err(), "--pid with no value");
        assert!(parse_global(&argv("--dir")).is_err(), "--dir with no value");
    }

    #[test]
    fn the_accepted_aliases_are_the_documented_ones() {
        assert_eq!(unalias("toolbox", "install"), "add");
        assert_eq!(unalias("toolbox", "i"), "add");
        assert_eq!(unalias("toolbox", "rm"), "remove");
        assert_eq!(unalias("toolbox", "ls"), "list");
        assert_eq!(unalias("lease", "ls"), "list");
        assert_eq!(unalias("request", "ls"), "list");
        assert_eq!(unalias("session", "ls"), "list");
        assert_eq!(unalias("mount", "rm"), "remove");
        assert_eq!(unalias("mount", "umount"), "remove");
        // An alias belongs to its own group only.
        assert_eq!(unalias("lease", "i"), "i");
        assert_eq!(unalias("toolbox", "umount"), "umount");
        // Canonical names pass through untouched.
        for name in ["add", "remove", "list", "upgrade", "prune", "gc", "answer"] {
            assert_eq!(unalias("toolbox", name), name);
            assert_eq!(unalias("lease", name), name);
        }
    }

    #[test]
    fn help_is_asked_for_in_the_first_position_only() {
        assert!(wants_help(&argv("--help")));
        assert!(wants_help(&argv("-h")));
        assert!(wants_help(&argv("help")));
        // These belong to the launcher or the runner this execs into.
        assert!(!wants_help(&argv("add --help")));
        assert!(!wants_help(&[]));
        assert!(help_for(Some("mount")).is_ok());
        assert_eq!(help_for(Some("nosuch")).unwrap_err().code, util::EXIT_USAGE);
    }

    #[test]
    fn mount_arguments_reach_the_controller_as_typed() {
        // Only the subcommand is rewritten; everything else is the
        // controller's to parse, including paths that look like options.
        assert_eq!(
            mount_args(&argv("umount --discard /mnt/notes")),
            argv("remove --discard /mnt/notes")
        );
        assert_eq!(mount_args(&argv("add --mode ro -- --weird")), argv("add --mode ro -- --weird"));
        assert_eq!(mount_args(&argv("list")), argv("list"));
    }
}
