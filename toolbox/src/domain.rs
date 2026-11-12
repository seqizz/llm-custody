//! `llm-custody domain`: the operator's view of one session's network
//! whitelist.
//!
//! Everything that changes the whitelist is done by the session's own domain
//! launcher (`$RUNDIR/domain`, registered as `<pid>.domain` and
//! `current.domain`), the same one the broker runs to approve an agent's
//! `custody-request --domain`. This side finds it, passes the arguments
//! through as an argv array and reformats its tab-separated output for a
//! human. There is no second implementation of add/remove to drift from the
//! shell one.
//!
//! The launcher's contract:
//!
//! ```text
//! add [--persist] -- NAME     stdout: NAME<TAB>session|persist
//! remove [--persist] -- NAME  stdout: NAME<TAB>removed
//! list                        stdout: NAME<TAB>SOURCE per line
//! blocked                     stdout: COUNT<TAB>NAME, allowed names excluded
//! ```
//!
//! Exit 0 on success, 2 for a name it refused, 1 for anything else, and its
//! diagnostics on stderr, which is passed straight to the operator.

use std::io::{IsTerminal, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::brokerctl::{self, Choice};
use crate::json;
use crate::paths::Layout;
use crate::proto;
use crate::session::Registry;
use crate::util::{self, fail, usage_err, Error, Result};

pub fn usage() {
    print!(
        "\
Usage: llm-custody [--pid PID] [--pause] domain [COMMAND [ARG...]]

The network whitelist of a live session: what it may reach, what it tried
to reach and was refused, and the domains its agent is waiting on.

  list [--json]              allowed domains and where each one came from
                             (default, file, flag, live) (alias: ls)
  blocked [--json]           names the filter refused, most hits first
  add [--persist] NAME       allow NAME for this session; --persist also
                             appends it to the domains file of the state root
  remove [--persist] NAME    stop allowing NAME now (alias: rm); --persist
                             also drops it from the domains file
  (no command)               interactive menu: pending domain requests,
                             allowed domains, blocked names

Only a session with a network filter has a whitelist to manage. Removing a
domain re-arms the filter for the remaining ones, and new connections to
them can be dropped for a moment while that happens.
"
    );
}

/// The `domain` command. `layout` is only used to find the brokers holding
/// pending domain requests, for the interactive menu.
pub fn run(registry: &Registry, pid: Option<&str>, layout: Layout, args: &[String]) -> Result<()> {
    let (launcher, owner) = registry.resolve_domain(pid)?;
    let (cmd, rest) = match args.split_first() {
        Some((c, r)) => (c.as_str(), r),
        None => {
            // Scoped to the session whose launcher this is, so the pending
            // list never offers another jail's requests under this one's
            // whitelist. Unknown owner: every broker, as `request answer`
            // would show.
            let layout = match owner {
                Some(p) if layout.broker_filter.is_none() => layout.with_broker_filter(Some(p)),
                _ => layout,
            };
            return menu(&launcher, &layout);
        }
    };
    match cmd {
        "list" | "ls" => cmd_list(&launcher, rest),
        "blocked" => cmd_blocked(&launcher, rest),
        "add" => {
            let (persist, name) = persist_and_name("add", rest)?;
            let scope = add(&launcher, persist, &name)?;
            util::note(format!("{name} allowed ({scope})"));
            Ok(())
        }
        "remove" | "rm" => {
            let (persist, name) = persist_and_name("remove", rest)?;
            remove(&launcher, persist, &name)?;
            util::note(format!(
                "{name} removed{}",
                if persist { ", also from the domains file" } else { " for this session" }
            ));
            Ok(())
        }
        other => usage_err(format!("domain: unknown command: {other} (try --help)")),
    }
}

/// `[--persist] [--] NAME`, the name validated and lowercased here so a typo
/// fails before the launcher takes its lock.
fn persist_and_name(cmd: &str, args: &[String]) -> Result<(bool, String)> {
    let mut persist = false;
    let mut name = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--persist" => persist = true,
            "--" => {
                if let Some(n) = args.get(i + 1) {
                    name = Some(n.clone());
                }
                if args.len() > i + 2 {
                    return usage_err(format!("{cmd}: one domain at a time"));
                }
                break;
            }
            a if a.starts_with('-') => return usage_err(format!("{cmd}: unknown option: {a}")),
            a => {
                if name.is_some() {
                    return usage_err(format!("{cmd}: one domain at a time"));
                }
                name = Some(a.to_string());
            }
        }
        i += 1;
    }
    match name {
        Some(n) => match proto::validate_domain(&n) {
            Ok(n) => Ok((persist, n)),
            Err(e) => usage_err(e.msg),
        },
        None => usage_err(format!("{cmd} needs a domain name")),
    }
}

/// `--json` or nothing.
fn json_flag(cmd: &str, args: &[String]) -> Result<bool> {
    match args {
        [] => Ok(false),
        [a] if a == "--json" => Ok(true),
        [a, ..] => usage_err(format!("{cmd}: unknown option: {a} (try --help)")),
    }
}

// ---- the launcher contract ---------------------------------------------

/// `NAME<TAB>SOURCE` lines. Anything without a tab is not part of the
/// contract and is skipped rather than guessed at.
pub fn parse_list(out: &str) -> Vec<(String, String)> {
    out.lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(n, s)| (n.trim().to_string(), s.trim().to_string()))
        .filter(|(n, _)| !n.is_empty())
        .collect()
}

/// `COUNT<TAB>NAME` lines, most hits first and then by name. The log the
/// counts come from has no useful order of its own, so hits are the order.
pub fn parse_blocked(out: &str) -> Vec<(u64, String)> {
    let mut rows: Vec<(u64, String)> = out
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .filter_map(|(c, n)| Some((c.trim().parse().ok()?, n.trim().to_string())))
        .filter(|(_, n): &(u64, String)| !n.is_empty())
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    rows
}

/// The argv for a mutation. Same discipline as the broker's: the name is
/// one entry after a `--`, so nothing in it is ever an option or a word for a
/// shell to split.
fn mutate_command(launcher: &Path, verb: &str, persist: bool, name: &str) -> Command {
    let mut cmd = Command::new(launcher);
    cmd.arg(verb);
    if persist {
        cmd.arg("--persist");
    }
    cmd.args(["--", name]);
    cmd
}

/// Run the launcher, stdout captured, stderr straight to the operator. A
/// non-zero exit keeps the launcher's status and adds no message of its own:
/// the launcher has already said what went wrong.
fn capture(mut cmd: Command, launcher: &Path) -> Result<String> {
    let out = util::ctx(
        cmd.stdin(Stdio::null()).stderr(Stdio::inherit()).output(),
        format!("running {}", launcher.display()),
    )?;
    match out.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&out.stdout).into_owned()),
        Some(code) => Err(Error { msg: String::new(), code }),
        None => fail(format!("{} was killed by a signal", launcher.display())),
    }
}

fn query(launcher: &Path, verb: &str) -> Result<String> {
    let mut cmd = Command::new(launcher);
    cmd.arg(verb);
    capture(cmd, launcher)
}

/// Returns the scope the launcher reports (`session` or `persist`).
fn add(launcher: &Path, persist: bool, name: &str) -> Result<String> {
    let out = capture(mutate_command(launcher, "add", persist, name), launcher)?;
    Ok(parse_list(&out)
        .pop()
        .map(|(_, s)| s)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| if persist { "persist" } else { "session" }.to_string()))
}

fn remove(launcher: &Path, persist: bool, name: &str) -> Result<()> {
    capture(mutate_command(launcher, "remove", persist, name), launcher).map(|_| ())
}

// ---- one-shot subcommands ----------------------------------------------

fn cmd_list(launcher: &Path, args: &[String]) -> Result<()> {
    let as_json = json_flag("list", args)?;
    let rows = parse_list(&query(launcher, "list")?);
    if as_json {
        let items: Vec<String> = rows
            .iter()
            .map(|(n, s)| json::Obj::new().str("name", n).str("source", s).finish())
            .collect();
        println!("{}", json::Obj::new().raw("domains", &format!("[{}]", items.join(","))).finish());
        return Ok(());
    }
    if rows.is_empty() {
        util::note("no domains allowed");
        return Ok(());
    }
    let w = rows.iter().map(|(n, _)| n.len()).max().unwrap_or(0);
    for (n, s) in &rows {
        println!("{n:<w$}  {s}");
    }
    Ok(())
}

fn cmd_blocked(launcher: &Path, args: &[String]) -> Result<()> {
    let as_json = json_flag("blocked", args)?;
    let rows = parse_blocked(&query(launcher, "blocked")?);
    if as_json {
        let items: Vec<String> = rows
            .iter()
            .map(|(c, n)| json::Obj::new().str("name", n).num("count", *c).finish())
            .collect();
        println!("{}", json::Obj::new().raw("blocked", &format!("[{}]", items.join(","))).finish());
        return Ok(());
    }
    if rows.is_empty() {
        util::note("nothing blocked so far");
        return Ok(());
    }
    let w = rows.iter().map(|(c, _)| c.to_string().len()).max().unwrap_or(0);
    for (c, n) in &rows {
        println!("{c:>w$}  {n}");
    }
    Ok(())
}

// ---- interactive menu --------------------------------------------------

/// One typed line, after an optional prompt. None at end of input, which
/// every level treats as leaving the whole menu: a pipe that ran out has
/// nothing more to say to any of them.
fn read_answer(prompt: &str) -> Result<Option<String>> {
    if std::io::stdout().is_terminal() {
        print!("{prompt}");
        let _ = std::io::stdout().flush();
    }
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line)? == 0 {
        return Ok(None);
    }
    Ok(Some(line.trim().to_string()))
}

/// What a submenu returns: carry on in the top menu, or leave entirely.
enum Next {
    Back,
    Exit,
}

/// Top level. Read like `request answer`: a short numbered list, a line of
/// input, and `q` (or an empty line) to leave. The launcher is checked on
/// every round because a session can end while this is open, and that is a
/// normal way for the menu to finish, not an error.
fn menu(launcher: &Path, layout: &Layout) -> Result<()> {
    let colour = brokerctl::colour();
    let (bold, dim, off) = if colour { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    loop {
        if !launcher.exists() {
            util::note("the session ended, nothing left to manage");
            return Ok(());
        }
        let pending = brokerctl::pending_of_kind(layout, proto::KIND_DOMAIN).len();
        // Counts are best-effort here, exactly like in `session list`.
        let allowed = query_quiet(launcher, "list").map(|o| parse_list(&o).len());
        let blocked = query_quiet(launcher, "blocked").map(|o| parse_blocked(&o).len());
        let n = |v: Option<usize>| v.map_or("?".to_string(), |n| n.to_string());
        println!();
        println!("{bold}network whitelist{off}");
        println!();
        println!("  {bold}1{off}  pending domain requests  {dim}{pending}{off}");
        println!("  {bold}2{off}  allowed domains          {dim}{}{off}", n(allowed));
        println!("  {bold}3{off}  blocked names            {dim}{}{off}", n(blocked));
        println!();
        println!("  {dim}type 1-3 to open one, q to quit{off}");
        let line = match read_answer("> ")? {
            Some(l) => l.to_ascii_lowercase(),
            None => return Ok(()),
        };
        let next = match line.as_str() {
            "" | "q" | "quit" => return Ok(()),
            "1" => menu_pending(launcher, layout, colour)?,
            "2" => menu_allowed(launcher, colour)?,
            "3" => menu_blocked(launcher, colour)?,
            other => {
                util::note(format!("not a choice: {other} (want 1-3, or q)"));
                Next::Back
            }
        };
        if let Next::Exit = next {
            return Ok(());
        }
    }
}

/// Launcher output for a count, with no stderr and a deadline, so a menu
/// header never stalls or fills with the launcher's diagnostics.
fn query_quiet(launcher: &Path, verb: &str) -> Option<String> {
    crate::session::launcher_output(launcher, &[verb], Duration::from_secs(5))
}

/// Pending domain requests. Approving and denying go through the same
/// broker calls as `request answer`; only the listing is filtered.
fn menu_pending(launcher: &Path, layout: &Layout, colour: bool) -> Result<Next> {
    let (bold, dim, off) = if colour { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    loop {
        if !launcher.exists() {
            return Ok(Next::Exit);
        }
        let rows = brokerctl::pending_of_kind(layout, proto::KIND_DOMAIN);
        if rows.is_empty() {
            util::note("no pending domain requests");
            return Ok(Next::Back);
        }
        let w = rows.iter().map(|r| r.attr.len()).max().unwrap_or(0);
        println!();
        for (i, r) in rows.iter().enumerate() {
            println!(
                "  {bold}{:>2}{off}  {bold}{:<w$}{off}  {dim}{}  {}{off}",
                i + 1,
                r.attr,
                util::human_duration(Duration::from_secs(r.age)),
                r.jail
            );
            println!(
                "      {dim}{}{off}",
                if r.reason.is_empty() { "(no reason given)" } else { &r.reason }
            );
        }
        println!();
        println!("  {dim}type a number to approve, the number and d to deny, r to refresh, q to go back{off}");
        let line = match read_answer("> ")? {
            Some(l) => l,
            None => return Ok(Next::Exit),
        };
        match brokerctl::parse_choice(&line, rows.len()) {
            Choice::Quit => return Ok(Next::Back),
            Choice::Refresh => continue,
            Choice::Approve(i) => {
                let mode = match brokerctl::ask_scope("allow", &rows[i].attr)? {
                    Some(m) => m,
                    None => continue,
                };
                if let Err(e) = brokerctl::approve(layout, &rows[i].id, &mode) {
                    util::note(e.msg);
                }
            }
            Choice::Deny(i) => {
                let reason = match read_answer("  reason for the agent (empty for none): ")? {
                    Some(r) => r,
                    None => return Ok(Next::Exit),
                };
                if let Err(e) = brokerctl::deny(layout, &rows[i].id, &reason) {
                    util::note(e.msg);
                }
            }
            Choice::Unknown => util::note(format!("not a choice: {line} (want 1-{}, or 1d to deny)", rows.len())),
        }
    }
}

/// What a typed line in the allowed list meant: a number removes that row,
/// `a` adds a new name.
#[derive(Debug, PartialEq)]
enum AllowedChoice {
    Add,
    Remove(usize),
    Refresh,
    Back,
    Unknown,
}

fn parse_allowed_choice(line: &str, rows: usize) -> AllowedChoice {
    match line.trim().to_ascii_lowercase().as_str() {
        "" | "q" | "quit" => AllowedChoice::Back,
        "r" | "refresh" => AllowedChoice::Refresh,
        "a" | "add" => AllowedChoice::Add,
        n => match n.parse::<usize>() {
            Ok(n) if n >= 1 && n <= rows => AllowedChoice::Remove(n - 1),
            _ => AllowedChoice::Unknown,
        },
    }
}

fn menu_allowed(launcher: &Path, colour: bool) -> Result<Next> {
    let (bold, dim, off) = if colour { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    loop {
        if !launcher.exists() {
            return Ok(Next::Exit);
        }
        let rows = match query(launcher, "list") {
            Ok(o) => parse_list(&o),
            // The launcher has said why on stderr; a session that went away
            // in between is caught by the check above on the next round.
            Err(_) => return Ok(Next::Back),
        };
        let w = rows.iter().map(|(n, _)| n.len()).max().unwrap_or(0);
        println!();
        if rows.is_empty() {
            println!("  {dim}no domains allowed{off}");
        }
        // The source tag is shown so a tools.nix default, which `--persist`
        // cannot remove, is recognizable before trying.
        for (i, (n, s)) in rows.iter().enumerate() {
            println!("  {bold}{:>2}{off}  {n:<w$}  {dim}{s}{off}", i + 1);
        }
        println!();
        println!("  {dim}type a number to remove it, a to add a domain, r to refresh, q to go back{off}");
        let line = match read_answer("> ")? {
            Some(l) => l,
            None => return Ok(Next::Exit),
        };
        match parse_allowed_choice(&line, rows.len()) {
            AllowedChoice::Back => return Ok(Next::Back),
            AllowedChoice::Refresh => continue,
            AllowedChoice::Add => {
                let name = match read_answer("  domain to allow: ")? {
                    Some(n) if n.is_empty() => continue,
                    Some(n) => n,
                    None => return Ok(Next::Exit),
                };
                let name = match proto::validate_domain(&name) {
                    Ok(n) => n,
                    Err(e) => {
                        util::note(e.msg);
                        continue;
                    }
                };
                promote(launcher, &name)?;
            }
            AllowedChoice::Remove(i) => {
                let name = &rows[i].0;
                let persist = match brokerctl::ask_scope("remove", name)? {
                    Some(m) => m == "persist",
                    None => continue,
                };
                if remove(launcher, persist, name).is_ok() {
                    util::note(format!("{name} removed"));
                }
            }
            AllowedChoice::Unknown => util::note(format!(
                "not a choice: {} (want 1-{}, a, r or q)",
                line.trim(),
                rows.len()
            )),
        }
    }
}

/// Ask session or persist, then add. Shared by the allowed list's `a` and
/// by promoting a blocked name.
fn promote(launcher: &Path, name: &str) -> Result<()> {
    let persist = match brokerctl::ask_scope("allow", name)? {
        Some(m) => m == "persist",
        None => return Ok(()),
    };
    // A failure was reported by the launcher on stderr; the menu carries on.
    if let Ok(scope) = add(launcher, persist, name) {
        util::note(format!("{name} allowed ({scope})"));
    }
    Ok(())
}

fn menu_blocked(launcher: &Path, colour: bool) -> Result<Next> {
    let (bold, dim, off) = if colour { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    loop {
        if !launcher.exists() {
            return Ok(Next::Exit);
        }
        let rows = match query(launcher, "blocked") {
            Ok(o) => parse_blocked(&o),
            Err(_) => return Ok(Next::Back),
        };
        if rows.is_empty() {
            util::note("nothing blocked so far");
            return Ok(Next::Back);
        }
        let w = rows.iter().map(|(c, _)| c.to_string().len()).max().unwrap_or(0);
        println!();
        for (i, (c, n)) in rows.iter().enumerate() {
            println!("  {bold}{:>2}{off}  {dim}{c:>w$}{off}  {n}", i + 1);
        }
        println!();
        println!("  {dim}type a number to allow that name, r to refresh, q to go back{off}");
        let line = match read_answer("> ")? {
            Some(l) => l,
            None => return Ok(Next::Exit),
        };
        // The same grammar as the allowed list minus `a`: a number is the
        // one action here, and a `d` suffix means nothing.
        match parse_allowed_choice(&line, rows.len()) {
            AllowedChoice::Back => return Ok(Next::Back),
            AllowedChoice::Refresh => continue,
            AllowedChoice::Remove(i) => {
                // The log is not validated input: a name the filter saw is
                // whatever was asked, so it is checked like any other.
                match proto::validate_domain(&rows[i].1) {
                    Ok(name) => promote(launcher, &name)?,
                    Err(e) => util::note(e.msg),
                }
            }
            AllowedChoice::Add | AllowedChoice::Unknown => util::note(format!(
                "not a choice: {} (want 1-{}, r or q)",
                line.trim(),
                rows.len()
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;

    fn argv(line: &str) -> Vec<String> {
        line.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn list_output_parses() {
        let rows = parse_list("api.anthropic.com\tdefault\nfoo.dev\tlive\nnot a row\n\n");
        assert_eq!(
            rows,
            [
                ("api.anthropic.com".to_string(), "default".to_string()),
                ("foo.dev".to_string(), "live".to_string())
            ]
        );
    }

    #[test]
    fn blocked_output_sorts_by_hits() {
        let rows = parse_blocked("2\tb.com\n7\tz.com\n2\ta.com\nx\tbad.com\n");
        assert_eq!(
            rows,
            [(7, "z.com".to_string()), (2, "a.com".to_string()), (2, "b.com".to_string())]
        );
    }

    #[test]
    fn mutations_keep_the_name_one_argument_after_the_separator() {
        let cmd = mutate_command(Path::new("/run/x/domain"), "remove", true, "-a.com");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(
            args,
            [OsStr::new("remove"), OsStr::new("--persist"), OsStr::new("--"), OsStr::new("-a.com")]
        );
        let cmd = mutate_command(Path::new("/run/x/domain"), "add", false, "a.com");
        let args: Vec<&OsStr> = cmd.get_args().collect();
        assert_eq!(args, [OsStr::new("add"), OsStr::new("--"), OsStr::new("a.com")]);
    }

    #[test]
    fn add_and_remove_arguments() {
        assert_eq!(persist_and_name("add", &argv("Foo.DEV")).unwrap(), (false, "foo.dev".into()));
        assert_eq!(
            persist_and_name("add", &argv("--persist foo.dev")).unwrap(),
            (true, "foo.dev".into())
        );
        assert_eq!(
            persist_and_name("remove", &argv("--persist -- foo.dev")).unwrap(),
            (true, "foo.dev".into())
        );
        for bad in ["", "a/b#c", "foo.dev bar.dev", "--force foo.dev", "1.2.3.4"] {
            let e = persist_and_name("add", &argv(bad)).unwrap_err();
            assert_eq!(e.code, util::EXIT_USAGE, "accepted {bad:?}");
        }
    }

    #[test]
    fn allowed_menu_choices() {
        assert_eq!(parse_allowed_choice("2", 3), AllowedChoice::Remove(1));
        assert_eq!(parse_allowed_choice(" A ", 3), AllowedChoice::Add);
        assert_eq!(parse_allowed_choice("", 3), AllowedChoice::Back);
        assert_eq!(parse_allowed_choice("r", 3), AllowedChoice::Refresh);
        assert_eq!(parse_allowed_choice("4", 3), AllowedChoice::Unknown);
        assert_eq!(parse_allowed_choice("0", 3), AllowedChoice::Unknown);
    }

    #[test]
    fn json_flag_is_the_only_option() {
        assert!(!json_flag("list", &[]).unwrap());
        assert!(json_flag("list", &argv("--json")).unwrap());
        assert!(json_flag("list", &argv("--yaml")).is_err());
    }
}
