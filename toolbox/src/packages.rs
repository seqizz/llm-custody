//! The `toolbox` and `lease` command groups: the operator's view of the
//! package profile, its argument handling and what each outcome prints. The
//! profile operations themselves are in toolbox.rs; this is only their CLI.

use std::io::{BufRead, IsTerminal, Write};
use std::time::Duration;

use crate::json;
use crate::paths;
use crate::toolbox::{LeaseRow, LeaseState, PinResult, RemoveResult, Toolbox};
use crate::util::{self, fail, usage_err, Result};
use crate::{unalias, wants_help, Global};

pub fn usage_toolbox() {
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
  remove PKG...     uninstall them, leased or permanent, and drop their
                    leases; same as `lease remove` (alias: rm)
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

pub fn usage_lease() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pause] lease <command> [ARG...]

A package added to the toolbox holds a {days}-day lease, so provisioning is not
a one-way ratchet: what an afternoon needed does not stay on every future
jail's PATH, with its whole closure pinned, until someone remembers to look.

  list              each package, the age of its lease and when it expires;
                    the unleased ones are the permanent ones (alias: ls)
                    [--older-than PERIOD]
                    [--json] machine-readable, for a terminal integration
  renew PKG...      push a lease out without touching the profile
  pin PKG...        drop the lease, making the package permanent
                    (add or renew it again to put it back under a lease)
  remove PKG...     uninstall a package now, leased or permanent; a lease
                    whose package is already gone is dropped too (alias: rm)
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

pub fn cmd_toolbox(g: &Global, args: &[String]) -> Result<()> {
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

pub fn cmd_lease(g: &Global, args: &[String]) -> Result<()> {
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
        "remove" => cmd_remove(&tb, &normalize(rest)?),
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
    let mut missing = Vec::new();
    let mut removed = false;
    for (name, r) in tb.remove(names)? {
        match r {
            RemoveResult::Removed => {
                removed = true;
                util::note(format!("{name} removed"));
            }
            RemoveResult::LeaseOnly => util::note(format!(
                "{name}: no such profile element - dropped its lease only"
            )),
            RemoveResult::NotInstalled => missing.push(name),
        }
    }
    if removed {
        // The removal is live, same as prune's.
        util::note("running jails lose these from their PATH immediately");
    }
    // The rest is done by now; the failure exit is so a script notices the
    // name it got wrong.
    if !missing.is_empty() {
        return fail(format!(
            "not installed and not leased: {} - check the list command",
            missing.join(" ")
        ));
    }
    Ok(())
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
    // --json is this command's alone, so it is taken out before the options
    // the three period-taking commands share are parsed.
    let as_json = args.iter().any(|a| a == "--json");
    let args: Vec<String> = args.iter().filter(|a| *a != "--json").cloned().collect();
    let (period, dry) = take_period(&args, "leases")?;
    if dry {
        return usage_err("leases: --dry-run makes no sense here, it never changes anything");
    }
    let period = period_or_default(tb, period)?;
    let rows = tb.lease_report(period)?;
    if as_json {
        println!("{}", leases_json(&rows, period));
        return Ok(());
    }
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

/// `lease list --json`, for a terminal integration: one object per package
/// with its `state` (`leased`, `expired`, `orphan` for a lease whose element
/// is gone, `permanent`), plus `age` and `left` in seconds where a lease
/// exists to measure them from. `period` is the lifetime the states were
/// judged against.
fn leases_json(rows: &[LeaseRow], period: Duration) -> String {
    let items: Vec<String> = rows
        .iter()
        .map(|row| {
            let o = json::Obj::new().str("name", &row.name);
            match row.state {
                LeaseState::Live { age, left } => {
                    o.str("state", "leased").num("age", age).num("left", left)
                }
                LeaseState::Expired { age } => o.str("state", "expired").num("age", age),
                LeaseState::Orphaned { age } => o.str("state", "orphan").num("age", age),
                LeaseState::Permanent => o.str("state", "permanent"),
            }
            .finish()
        })
        .collect();
    json::Obj::new()
        .num("period", period.as_secs())
        .raw("packages", &format!("[{}]", items.join(",")))
        .finish()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lease_json_carries_state_and_times() {
        let rows = vec![
            LeaseRow { name: "jq".to_string(), state: LeaseState::Live { age: 60, left: 40 } },
            LeaseRow { name: "old".to_string(), state: LeaseState::Expired { age: 200 } },
            LeaseRow { name: "gone".to_string(), state: LeaseState::Orphaned { age: 300 } },
            LeaseRow { name: "git".to_string(), state: LeaseState::Permanent },
        ];
        let v = json::parse(&leases_json(&rows, Duration::from_secs(100))).expect("valid json");
        assert_eq!(v.get("period").and_then(json::Json::as_u64), Some(100));
        let pkgs = v.get("packages").and_then(json::Json::as_arr).expect("packages array");
        let states: Vec<&str> = pkgs.iter().map(|p| p.str_field("state")).collect();
        assert_eq!(states, ["leased", "expired", "orphan", "permanent"]);
        assert_eq!(pkgs[0].str_field("name"), "jq");
        assert_eq!(pkgs[0].get("left").and_then(json::Json::as_u64), Some(40));
        assert_eq!(pkgs[1].get("age").and_then(json::Json::as_u64), Some(200));
        assert!(pkgs[1].get("left").is_none());
        assert!(pkgs[3].get("age").is_none());

        let empty = json::parse(&leases_json(&[], Duration::from_secs(1))).expect("valid json");
        assert_eq!(empty.get("packages").and_then(json::Json::as_arr).map(<[_]>::len), Some(0));
    }
}
