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
mod domain;
mod json;
mod launch;
mod nix;
mod packages;
mod paths;
mod proto;
mod request;
mod session;
mod toolbox;
mod util;

use std::io::Write;
use std::path::PathBuf;

use paths::Layout;
use session::Registry;
use toolbox::Toolbox;
use util::{usage_err, Result};

fn usage() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pid PID] [--pause] <command> [ARG...]

  launch TOOL ...   start a sandboxed tool, no TOOL lists them
  mount ...         attach a host tree to a live session, or detach one
  sync ...          fold a live session's isolated trees back to the host
  domain ...        a live session's network whitelist and blocked names
  session list      the live sessions and what each one has outstanding
  request ...       the package, mount and domain requests jailed agents
                    wait on
  toolbox ...       the package profile every jail sees on its PATH
  lease ...         how long an added package survives without being used
  serve             the per-jail request broker, started by the runner

Options:
  --dir PATH   toolbox profile to act on (toolbox, lease, request, serve).
               Without it: the toolbox of the most recently started session
               ($XDG_RUNTIME_DIR/llm-custody/current.toolbox), else
               $LLMCUSTODY_TOOLBOX_DIR or ~/.config/llm-custody/toolbox
  --pid PID    which live session to act on (mount, sync, domain, request).
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
synced, how many trees are attached, how many requests are waiting, how
many domains were allowed after launch and how many distinct names the
network filter blocked (or that it has none), and the sync, mount and
domain launchers of that session.

Sessions register under $XDG_RUNTIME_DIR/llm-custody as <pid>.state.
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
        Some("domain") => domain::usage(),
        Some("session") => usage_session(),
        Some("request") => brokerctl::usage(),
        Some("toolbox") => packages::usage_toolbox(),
        Some("lease") => packages::usage_lease(),
        Some("serve") => broker::usage(),
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
        ("toolbox", "rm") | ("lease", "rm") => "remove",
        ("mount", "rm") | ("mount", "umount") => "remove",
        ("domain", "rm") => "remove",
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

/// The command words, and through the modules they dispatch to, every
/// subcommand and flag, are described a second time in lib/completions.nix
/// (`commands`), by hand. Adding or renaming one here or in a group's module
/// needs the matching entry there; nothing checks the two against each other.
fn run(g: Global) -> Result<()> {
    let (cmd, rest): (String, Vec<String>) = match g.args.split_first() {
        Some((c, r)) => (c.clone(), r.to_vec()),
        // Nothing to guess at with this few commands: show them.
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
        "domain" => cmd_domain(&g, &rest),
        "session" => cmd_session(&rest),
        "request" => brokerctl::cmd_request(&g, &rest),
        "toolbox" => packages::cmd_toolbox(&g, &rest),
        "lease" => packages::cmd_lease(&g, &rest),
        "serve" => {
            if wants_help(&rest) {
                broker::usage();
                return Ok(());
            }
            broker::cmd_serve(g.toolbox()?, &rest)
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

fn cmd_domain(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) {
        domain::usage();
        return Ok(());
    }
    // Only the subcommand is unaliased, as for mount: the rest is a domain
    // name and its flags, which domain.rs parses.
    let mut args = args.to_vec();
    if let Some(first) = args.first_mut() {
        *first = unalias("domain", first).to_string();
    }
    domain::run(&Registry::open(), g.pid.as_deref(), g.layout()?, &args)
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
        assert_eq!(unalias("lease", "rm"), "remove");
        assert_eq!(unalias("toolbox", "ls"), "list");
        assert_eq!(unalias("lease", "ls"), "list");
        assert_eq!(unalias("request", "ls"), "list");
        assert_eq!(unalias("session", "ls"), "list");
        assert_eq!(unalias("mount", "rm"), "remove");
        assert_eq!(unalias("mount", "umount"), "remove");
        assert_eq!(unalias("domain", "rm"), "remove");
        assert_eq!(unalias("domain", "ls"), "list");
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
