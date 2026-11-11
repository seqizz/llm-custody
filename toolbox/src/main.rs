//! `llm-custody-toolbox`: host-side owner of the package profile a jail sees
//! on its PATH, and of the broker that lets a jailed agent ask for an addition.
//!
//! The jail cannot install anything itself - read-only /nix/store, no binary
//! cache in the domain whitelist - so this is the half of that which runs
//! where realizing a derivation is possible. Everything an agent can reach
//! goes through `serve`, and an operator still has to say yes.

mod broker;
mod brokerctl;
mod json;
mod nix;
mod paths;
mod proto;
mod request;
mod toolbox;
mod util;

use std::io::{BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::time::Duration;

use paths::Layout;
use toolbox::{LeaseState, PinResult, Toolbox};
use util::{usage_err, Result};

fn usage() {
    print!(
        "\
Usage: llm-custody-toolbox [--dir PATH] [--pause] <command> [ARG...]

  add PKG...        install nixpkgs attributes into the toolbox profile and
                    start their {days}-day lease. ALSO HOW YOU RENEW ONE: re-running
                    add on something already installed skips the install and
                    just pushes its lease out, so answering the same request
                    again keeps the package alive for another {days} days
  remove PKG...     remove them again (alias: rm)
  renew PKG...      push a lease out without touching the profile
  pin PKG...        drop the lease, making the package permanent
                    (add or renew it again to put it back under a lease)
  list              show what is installed
  leases            show each package, the age of its lease and when it
                    expires; the unleased ones are the permanent ones
                    [--older-than PERIOD]
  upgrade [PKG...]  rebuild installed packages against their flake refs
  prune             remove the packages whose lease has expired, then drop
                    the generations that held them. Every jail start does
                    this on its own (see serve), so running it by hand is
                    for pruning early or with another lifetime
                    [--older-than PERIOD] lifetime to apply, e.g. 30d
                    [--dry-run] report without removing
  gc                drop the profile generations every add leaves behind
                    [--older-than PERIOD] [--dry-run]

  serve             run the request broker for one jail (started by the
                    jail runner, not usually by hand)
                    [--broker-id ID] [--label TEXT] [--timeout PERIOD]
                    [--uservar 0|1] [--notify-hook PATH]
                    The hook runs on every queue change, with
                    <event> <id> <attr> <reason> <count> <label> as
                    separate arguments and no shell involved. Its
                    failure is never the request's problem.
                    $LLMCUSTODY_NOTIFY_HOOK is the default.
                    Also runs one prune + gc in the background, which is
                    what keeps expired leases from accumulating without
                    anyone remembering to look.
                    $LLMCUSTODY_TOOLBOX_AUTOPRUNE=0 turns that off.
  requests          pending package requests from running jails
                    [--json] machine-readable, for a terminal integration
  answer            the same queue, interactively: pick a numbered row to
                    approve or deny it without typing a request id
  approve ID        install a pending request and unblock the jail
  deny ID           refuse it [--reason TEXT]

  (no args)         prompt for packages to add
  --pause           wait for a keypress before exiting, so a pane a terminal
                    keybinding spawned does not close over the output

A bare name is resolved against $LLMCUSTODY_TOOLBOX_FLAKE (default nixpkgs);
anything containing # or : is passed to nix verbatim as a flake reference.
Jailed clients may only ask for bare attributes.

The whole request block an agent printed can be pasted as-is:
  llm-custody-toolbox add required packages: lua5_4, shellcheck

Without --dir: the toolbox of the most recently started session
($XDG_RUNTIME_DIR/llm-custody/current.toolbox), else
$LLMCUSTODY_TOOLBOX_DIR or ~/.config/llm-custody/toolbox.
",
        days = paths::DEFAULT_LEASE_DAYS
    );
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

    let (pause, rest) = match parse_global(&argv[1..]) {
        Ok(v) => v,
        Err(e) => finish(Err(e), false, "llm-custody-toolbox"),
    };
    finish(run(rest), pause, "llm-custody-toolbox");
}

/// Prints whatever went wrong and leaves with the right status. A
/// keybinding-spawned pane dies with the process, taking the nix build log
/// with it, so `--pause` holds it open - including, deliberately, for a failed
/// install, which is the case actually worth reading.
///
/// An empty message means the failure has already been reported in more detail
/// than a single line could carry - `custody-request` says something per
/// attribute and then fails as a whole.
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
    args: Vec<String>,
}

fn parse_global(args: &[String]) -> Result<(bool, Global)> {
    let mut dir = None;
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
            "--pause" => pause = true,
            _ => break,
        }
        i += 1;
    }
    Ok((pause, Global { dir, args: args[i..].to_vec() }))
}

fn run(g: Global) -> Result<()> {
    let layout = Layout::resolve(g.dir)?;
    let args = g.args;
    let (cmd, rest): (String, Vec<String>) = match args.split_first() {
        Some((c, r)) => (c.clone(), r.to_vec()),
        None => (prompt_for_add()?, Vec::new()),
    };
    // The interactive path returns the whole typed line as one argument, which
    // normalize() below splits - it has to handle a pasted request block
    // anyway.
    let (cmd, rest) = if let Some(line) = cmd.strip_prefix('\u{1}') {
        ("add".to_string(), vec![line.to_string()])
    } else {
        (cmd, rest)
    };

    let tb = Toolbox::new(layout);
    match cmd.as_str() {
        "list" | "ls" => tb.list(),
        "add" | "install" | "i" => cmd_add(&tb, &normalize(&rest)?),
        "remove" | "rm" => cmd_remove(&tb, &normalize(&rest)?),
        "renew" => cmd_renew(&tb, &normalize(&rest)?),
        "pin" => cmd_pin(&tb, &normalize(&rest)?),
        "upgrade" | "up" => cmd_upgrade(&tb, &rest),
        "leases" => cmd_leases(&tb, &rest),
        "prune" => cmd_prune(&tb, &rest),
        "gc" => cmd_gc(&tb, &rest),
        "serve" => cmd_serve(tb, &rest),
        "requests" => cmd_requests(&tb, &rest),
        "answer" => brokerctl::answer(&tb.layout),
        "approve" => cmd_approve(&tb, &rest),
        "deny" => cmd_deny(&tb, &rest),
        // Reachable when the binary is invoked by its real name; the jail
        // normally gets here through the custody-request symlink.
        "request" => request::run(&rest),
        other => usage_err(format!("unknown command: {other} (try --help)")),
    }
}

fn prompt_for_add() -> Result<String> {
    if !std::io::stdin().is_terminal() {
        usage();
        std::process::exit(0);
    }
    eprint!("package(s) to add: ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    if line.trim().is_empty() {
        return usage_err("nothing to add");
    }
    // Marked so run() can tell it apart from a subcommand name.
    Ok(format!("\u{1}{}", line.trim()))
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
        broker::ServeOpts { broker_id, label, timeout, uservar, notify_hook },
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
    match args.first() {
        Some(id) if !id.starts_with('-') => brokerctl::approve(&tb.layout, id),
        _ => usage_err("approve needs a request id - see the requests command"),
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
