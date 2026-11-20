//! The `request` command group (`list`, `answer`, `approve`, `deny`): the
//! operator's side of the brokers, from its command line down to the control
//! socket client (`discover`, `control_call`).
//!
//! None of this touches the profile directly. It finds the broker holding a
//! request and tells it what to do, because the broker is the only thing that
//! knows which jail client is still waiting on the answer.

use crate::broker;
use crate::json::{self, Json};
use crate::paths::Layout;
use crate::proto;
use crate::toolbox::Toolbox;
use crate::util::{self, fail, usage_err, Result};
use crate::{unalias, wants_help, Global};
use std::fs;
use std::io::{BufReader, IsTerminal};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// Listing only reads an in-memory map, so a broker that cannot answer this
/// promptly is wedged. Short, because a terminal integration calls it
/// synchronously to build a picker and must not freeze the GUI on it.
const LIST_TIMEOUT: Option<Duration> = Some(Duration::from_secs(5));
/// Approving runs a nix build, which legitimately takes minutes.
const ANSWER_TIMEOUT: Option<Duration> = None;

/// One pending request, flattened across brokers for display.
pub struct Row {
    pub id: String,
    pub kind: String,
    pub attr: String,
    pub reason: String,
    pub age: u64,
    pub jail: String,
}

/// A row from a broker built before mounts existed carries no kind.
fn kind_of(r: &Json) -> String {
    match r.str_field("kind") {
        "" => proto::KIND_PACKAGE.to_string(),
        k => k.to_string(),
    }
}

/// How a request reads in a listing: the attribute, `mount PATH` or
/// `domain NAME`. A mount asked for by name says so, because approving it
/// takes a path from the operator.
fn describe(kind: &str, attr: &str) -> String {
    match kind {
        proto::KIND_MOUNT if proto::is_mount_name(attr) => format!("mount {attr} (no path given)"),
        proto::KIND_MOUNT => format!("mount {attr}"),
        proto::KIND_DOMAIN => format!("domain {attr}"),
        _ => attr.to_string(),
    }
}

/// The pending requests of one kind, oldest first, for a front end that only
/// deals with that kind (`llm-custody domain`). Same collection and order as
/// `answer`, so the two never disagree about what is waiting.
pub fn pending_of_kind(layout: &Layout, kind: &str) -> Vec<Row> {
    collect(layout, true).0.into_iter().filter(|r| r.kind == kind).collect()
}

fn collect(layout: &Layout, quiet: bool) -> (Vec<Row>, usize) {
    let handles = discover(layout);
    let mut rows = Vec::new();
    for h in &handles {
        let reply = match control_call(h, &json::Obj::new().str("op", "list").finish(), LIST_TIMEOUT) {
            Ok(r) => r,
            // One wedged broker should not hide the requests of the others.
            Err(e) => {
                if !quiet {
                    util::note(format!("broker {}: {}", h.id, e.msg));
                }
                continue;
            }
        };
        let label = {
            let l = reply.str_field("label");
            if l.is_empty() { h.label.clone() } else { l.to_string() }
        };
        for r in reply.get("requests").and_then(Json::as_arr).unwrap_or(&[]) {
            rows.push(Row {
                id: r.str_field("id").to_string(),
                kind: kind_of(r),
                attr: r.str_field("attr").to_string(),
                reason: r.str_field("reason").to_string(),
                age: r.get("age").and_then(Json::as_u64).unwrap_or(0),
                jail: label.clone(),
            });
        }
    }
    // Oldest first: the one that has been blocking an agent longest is the
    // one to answer first, and a stable order means a picker's entries do not
    // jump around between invocations.
    rows.sort_by(|a, b| b.age.cmp(&a.age).then_with(|| a.id.cmp(&b.id)));
    (rows, handles.len())
}

/// Machine-readable form, for a terminal integration that wants to build a
/// picker rather than make the operator read a table and retype an id out of
/// it. Printed even when empty, so a consumer can tell "nothing pending" from
/// "the command failed".
pub fn requests_json(layout: &Layout) -> Result<()> {
    let (rows, brokers) = collect(layout, true);
    let mut arr = String::from("[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            arr.push(',');
        }
        arr.push_str(
            &json::Obj::new()
                .str("id", &r.id)
                .str("kind", &r.kind)
                .str("attr", &r.attr)
                .str("reason", &r.reason)
                .num("age", r.age)
                .str("jail", &r.jail)
                .finish(),
        );
    }
    arr.push(']');
    println!(
        "{}",
        json::Obj::new().raw("requests", &arr).num("brokers", brokers as u64).finish()
    );
    Ok(())
}

pub fn requests(layout: &Layout) -> Result<()> {
    let handles = discover(layout);
    if handles.is_empty() {
        util::note("no jail broker is running");
        return Ok(());
    }

    let mut rows: Vec<(String, String, String, String, String)> = Vec::new();
    for h in &handles {
        let reply = match control_call(h, &json::Obj::new().str("op", "list").finish(), LIST_TIMEOUT) {
            Ok(r) => r,
            // One wedged broker should not hide the requests of the others.
            Err(e) => {
                util::note(format!("broker {}: {}", h.id, e.msg));
                continue;
            }
        };
        let label = {
            let l = reply.str_field("label");
            if l.is_empty() { h.label.clone() } else { l.to_string() }
        };
        let list = reply.get("requests").and_then(Json::as_arr).unwrap_or(&[]);
        for r in list {
            rows.push((
                r.str_field("id").to_string(),
                describe(&kind_of(r), r.str_field("attr")),
                util::human_duration(std::time::Duration::from_secs(
                    r.get("age").and_then(Json::as_u64).unwrap_or(0),
                )),
                label.clone(),
                r.str_field("reason").to_string(),
            ));
        }
    }

    if rows.is_empty() {
        util::note(format!(
            "no pending requests ({} broker(s) running)",
            handles.len()
        ));
        return Ok(());
    }

    // Columns sized to the content: a request id is a pid plus a counter, and
    // padding every one of them to a guessed width wastes the line that the
    // reason has to fit on.
    let w_id = rows.iter().map(|r| r.0.len()).max().unwrap_or(2).max(2);
    let w_attr = rows.iter().map(|r| r.1.len()).max().unwrap_or(7).max(7);
    let w_age = rows.iter().map(|r| r.2.len()).max().unwrap_or(3).max(3);
    let w_jail = rows.iter().map(|r| r.3.len()).max().unwrap_or(4).max(4);
    println!(
        "{:<w_id$}  {:<w_attr$}  {:<w_age$}  {:<w_jail$}  REASON",
        "ID", "REQUEST", "AGE", "JAIL"
    );
    for (id, attr, age, jail, reason) in &rows {
        println!("{id:<w_id$}  {attr:<w_attr$}  {age:<w_age$}  {jail:<w_jail$}  {reason}");
    }
    util::note("approve <id> to grant it (a mount: --mode ro|full|limited|none|overlay, default ro, --path PATH to mount another host path than the one asked for; a domain: --mode session|persist, default session), deny <id> [--reason TEXT] to refuse");
    Ok(())
}

/// A request id is `<broker-id>.<n>`, so the broker it belongs to is in the
/// id itself. Falls back to asking every broker, which covers an id copied
/// from somewhere that reformatted it.
fn route<'a>(handles: &'a [BrokerHandle], id: &str) -> Option<&'a BrokerHandle> {
    let want = id.split('.').next().unwrap_or(id);
    handles.iter().find(|h| h.id == want)
}

fn dispatch(layout: &Layout, id: &str, msg: String) -> Result<Json> {
    if id.is_empty() {
        return fail("need a request id - see the requests command");
    }
    let handles = discover(layout);
    if handles.is_empty() {
        return fail("no jail broker is running, so there is nothing to answer");
    }
    if let Some(h) = route(&handles, id) {
        return control_call(h, &msg, ANSWER_TIMEOUT);
    }
    // Unroutable id: try them all rather than refusing on a formatting
    // detail, and report the real "no such request" from the brokers.
    let mut last = None;
    for h in &handles {
        match control_call(h, &msg, ANSWER_TIMEOUT) {
            Ok(r) if r.str_field("status") == proto::STATUS_OK => return Ok(r),
            Ok(r) => last = Some(r.str_field("message").to_string()),
            Err(e) => last = Some(e.msg),
        }
    }
    fail(last.unwrap_or_else(|| format!("no pending request with id {id}")))
}

fn check(reply: &Json) -> Result<()> {
    match reply.str_field("status") {
        proto::STATUS_OK => Ok(()),
        _ => fail(reply.str_field("message").to_string()),
    }
}

/// `mode` only means something for a mount or a domain request; the broker
/// ignores it for a package and defaults it (read-only, session) when empty.
/// Which vocabulary applies depends on the request, which only the broker
/// knows, so this checks for either and the broker checks the right one.
///
/// `path` replaces the host path of a mount request (empty keeps the one the
/// agent asked for); the broker refuses it for any other kind.
pub fn approve(layout: &Layout, id: &str, mode: &str, path: &str) -> Result<()> {
    if !mode.is_empty()
        && proto::validate_mount_mode(mode).is_err()
        && proto::validate_domain_mode(mode).is_err()
    {
        return util::usage_err(format!(
            "mode must be one of {} for a mount, {} for a domain (got: {mode})",
            proto::MOUNT_MODES.join("|"),
            proto::DOMAIN_MODES.join("|")
        ));
    }
    if !path.is_empty() {
        proto::validate_mount_path(path)?;
    }
    let msg = json::Obj::new()
        .str("op", "approve")
        .str("id", id)
        .str("mode", mode)
        .str("path", path)
        .finish();
    let reply = dispatch(layout, id, msg)?;
    check(&reply)?;
    let attr = reply.str_field("attr");
    let commands = reply.str_field("commands");
    let guest = reply.str_field("guest");
    let scope = reply.str_field("scope");
    if !scope.is_empty() {
        util::note(format!("{attr} allowed for the jail ({scope})"));
    } else if !guest.is_empty() {
        let host = match reply.str_field("host") {
            "" => attr,
            h => h,
        };
        util::note(format!("{host} mounted at {guest} ({})", reply.str_field("mode")));
    } else if commands.is_empty() {
        util::note(format!(
            "{attr} installed (no new commands - already present, or it ships no bin/)"
        ));
    } else {
        util::note(format!("{attr} installed, now on the jail PATH: {commands}"));
    }
    let extra = reply.str_field("note");
    if !extra.is_empty() {
        util::note(extra);
    }
    Ok(())
}

pub fn deny(layout: &Layout, id: &str, reason: &str) -> Result<()> {
    proto::validate_reason(reason)?;
    let msg = json::Obj::new()
        .str("op", "deny")
        .str("id", id)
        .str("reason", reason)
        .finish();
    let reply = dispatch(layout, id, msg)?;
    check(&reply)?;
    util::note(format!("{} denied, nothing changed", reply.str_field("attr")));
    Ok(())
}

/// A leading `~` is the operator's home directory, as a shell would have made
/// it before this program saw the line.
fn expand_home(path: &str, home: Option<&str>) -> String {
    match (home, path.strip_prefix('~')) {
        (Some(home), Some(rest)) if rest.is_empty() || rest.starts_with('/') => {
            format!("{}{rest}", home.trim_end_matches('/'))
        }
        _ => path.to_string(),
    }
}

/// The path question for a mount approval: which host path to mount for this
/// request. The agent's path is a guess made from inside the jail, so it is
/// the default and an empty answer keeps it; a request that carries only a
/// name has no default and needs one typed. Returns the path to send as the
/// override (empty = keep the agent's), or `None` when the operator backed
/// out with `q`.
fn ask_path(ask: &str) -> Result<Option<String>> {
    let named = proto::is_mount_name(ask);
    let home = std::env::var("HOME").ok();
    loop {
        let prompt = if named {
            format!("  host path to mount for \"{ask}\" (q=back): ")
        } else {
            format!("  host path [{ask}] (enter keeps it, q=back): ")
        };
        let ans = match util::read_path_answer(&prompt)? {
            Some(l) => l,
            None => return Ok(None),
        };
        match ans.as_str() {
            "q" | "quit" => return Ok(None),
            "" if named => util::note("this request names no path, type the one to mount"),
            "" => return Ok(Some(String::new())),
            typed => {
                let path = expand_home(typed, home.as_deref());
                // Completion ends a directory with a slash, and the mount is
                // named after the last path component.
                let path = match path.trim_end_matches('/') {
                    "" => "/".to_string(),
                    p => p.to_string(),
                };
                match proto::validate_mount_path(&path) {
                    Ok(()) => return Ok(Some(path)),
                    Err(e) => util::note(e.msg),
                }
            }
        }
    }
}

/// The mode question for a mount approval. Empty answer means read-only;
/// `q` backs out without answering the request at all.
fn ask_mode(path: &str) -> Result<Option<String>> {
    loop {
        let prompt = format!(
            "  mode for {path} [{}] (ro=read-only, full=real tree rw, limited/none=synced copy, overlay=cow; q=back): ",
            proto::DEFAULT_MOUNT_MODE
        );
        let ans = match util::read_answer(&prompt)? {
            Some(l) => l.to_ascii_lowercase(),
            None => return Ok(None),
        };
        match ans.as_str() {
            "" => return Ok(Some(proto::DEFAULT_MOUNT_MODE.to_string())),
            "q" | "quit" => return Ok(None),
            m => match proto::validate_mount_mode(m) {
                Ok(()) => return Ok(Some(m.to_string())),
                Err(e) => util::note(e.msg),
            },
        }
    }
}

/// The scope question for a domain change: `s` (or an empty line) for this
/// session only, `p` to also change the persisted domains file, `q` to back
/// out without doing anything. `verb` is what is being done (allow, remove).
/// Returns the broker's mode word.
pub fn ask_scope(verb: &str, name: &str) -> Result<Option<String>> {
    loop {
        let prompt = format!("  {verb} {name} for [s]ession / [p]ersist / [q] back: ");
        let line = match util::read_answer(&prompt)? {
            Some(l) => l,
            None => return Ok(None),
        };
        match parse_scope(&line) {
            Some(Some(m)) => return Ok(Some(m.to_string())),
            Some(None) => return Ok(None),
            None => util::note(format!("not a choice: {} (want s, p or q)", line.trim())),
        }
    }
}

/// `Some(Some(mode))` for an answer, `Some(None)` for backing out, `None`
/// for something that is neither.
fn parse_scope(line: &str) -> Option<Option<&'static str>> {
    match line.trim().to_ascii_lowercase().as_str() {
        "" | "s" | "session" => Some(Some("session")),
        "p" | "persist" => Some(Some("persist")),
        "q" | "quit" => Some(None),
        _ => None,
    }
}

/// Approve every row that was on screen when the operator answered, each
/// with the default of its kind: a mount read-only, a domain for this
/// session only. Those are the answers of least exposure, which is what an
/// answer given to several requests at once has to be; anything wider is
/// approved by its number, where the mode is asked.
///
/// The rows are the rendered ones on purpose, not a fresh read of the
/// queue: a request that arrived after the list was drawn has not been
/// seen, so it is not part of "all". One failure is reported and the rest
/// still get their answer.
pub fn approve_all(layout: &Layout, rows: &[Row]) {
    for r in rows {
        if let Err(e) = approve(layout, &r.id, "", "") {
            util::note(e.msg);
        }
    }
}

/// Deny every row that was on screen, for the same reason and with the same
/// one-failure-does-not-stop-the-rest handling as `approve_all`.
pub fn deny_all(layout: &Layout, rows: &[Row], reason: &str) {
    for r in rows {
        if let Err(e) = deny(layout, &r.id, reason) {
            util::note(e.msg);
        }
    }
}

/// What a typed line at the `answer` prompt meant.
#[derive(Debug, PartialEq)]
pub enum Choice {
    Approve(usize),
    /// The row, and the operator's reason for the agent (empty for none).
    Deny(usize, String),
    /// Every row on screen, in one answer.
    ApproveAll,
    /// With the reason every denied agent is given (empty for none).
    DenyAll(String),
    Refresh,
    Quit,
    Unknown,
}

/// `3` approves the third row, `3d` denies it, `r` re-reads the queue, an
/// empty line or `q` leaves. Indexes rather than request ids: an id is a
/// broker pid and a counter, fine for routing and hopeless to type.
///
/// A denial takes the rest of the line as the reason handed to the agent:
/// `3d already mounted, look in /workspace/igaptly`, or `d not today` for
/// every row. The refusal is the moment the operator knows why, and an agent
/// told why can pick another route where a bare "denied" only stops it.
pub fn parse_choice(line: &str, rows: usize) -> Choice {
    let line = line.trim();
    let (head, rest) = match line.split_once(char::is_whitespace) {
        Some((h, r)) => (h.to_ascii_lowercase(), r.trim()),
        None => (line.to_ascii_lowercase(), ""),
    };
    match head.as_str() {
        "" | "q" | "quit" if rest.is_empty() => return Choice::Quit,
        "r" | "refresh" if rest.is_empty() => return Choice::Refresh,
        "a" | "all" if rest.is_empty() => return Choice::ApproveAll,
        "d" | "deny" => return Choice::DenyAll(rest.to_string()),
        _ => {}
    }
    // `3d why` and `3 d why` are the same answer.
    let (digits, deny, reason) = match head.strip_suffix('d') {
        Some(d) => (d, true, rest),
        None => match rest.split_once(char::is_whitespace) {
            Some((d, why)) if d.eq_ignore_ascii_case("d") => (head.as_str(), true, why.trim()),
            None if rest.eq_ignore_ascii_case("d") => (head.as_str(), true, ""),
            _ if rest.is_empty() => (head.as_str(), false, ""),
            _ => return Choice::Unknown,
        },
    };
    match digits.parse::<usize>() {
        Ok(n) if n >= 1 && n <= rows => {
            if deny {
                Choice::Deny(n - 1, reason.to_string())
            } else {
                Choice::Approve(n - 1)
            }
        }
        _ => Choice::Unknown,
    }
}

/// Colour only for a terminal that wants it, decided once.
pub fn colour() -> bool {
    std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}

fn render(rows: &[Row], colour: bool) {
    let (bold, dim, off) = if colour { ("\x1b[1m", "\x1b[2m", "\x1b[0m") } else { ("", "", "") };
    // Sized to the content, so the age and jail columns line up without
    // padding every row out to a guessed width.
    let w_attr = rows.iter().map(|r| describe(&r.kind, &r.attr).len()).max().unwrap_or(0);
    let ages: Vec<String> =
        rows.iter().map(|r| util::human_duration(Duration::from_secs(r.age))).collect();
    let w_age = ages.iter().map(|a| a.len()).max().unwrap_or(0);

    println!();
    println!("{bold}{} pending request(s){off}", rows.len());
    println!();
    for (i, r) in rows.iter().enumerate() {
        // Number and package on one line, the agent's own justification
        // indented under it: a reason is usually a sentence, and squeezing it
        // into a table column is what made the plain `requests` output hard to
        // read in a narrow pane.
        println!(
            "  {bold}{:>2}{off}  {bold}{:<w_attr$}{off}  {dim}{:>w_age$}  {}{off}",
            i + 1,
            describe(&r.kind, &r.attr),
            ages[i],
            r.jail
        );
        println!(
            "      {dim}{}{off}",
            if r.reason.is_empty() { "(no reason given)" } else { &r.reason }
        );
    }
    println!();
    // Spelled out with the numbers actually on screen. `<n>` is placeholder
    // notation from a usage string; in a prompt it is one more thing to
    // decode before you can answer the question.
    let hint = if rows.len() == 1 {
        "type 1 to approve, 1d to deny, r to refresh, q to quit".to_string()
    } else {
        // The deny range mirrors the approve range rather than showing one
        // example, so it cannot read as if only that row could be denied.
        format!(
            "type 1-{n} to approve, 1d-{n}d to deny, r to refresh, q to quit",
            n = rows.len()
        )
    };
    println!("  {dim}{hint}{off}");
    println!(
        "  {dim}a approves all (mounts read-only, domains for this session), d denies all{off}"
    );
    println!("  {dim}text after a denial is the reason the agent gets: 1d not needed, use X{off}");
}

/// The interactive half of `requests`: show the queue in this pane and act on
/// it, rather than making the operator read one command's output and retype an
/// id into another.
///
/// Lives here rather than in a terminal integration because every terminal can
/// run a command in a pane, and only one of them has a picker widget. This
/// works the same over ssh, under tmux, and in a plain xterm.
pub fn answer(layout: &Layout) -> Result<()> {
    let colour = colour();
    loop {
        let (rows, brokers) = collect(layout, false);
        if rows.is_empty() {
            util::note(format!("no pending requests ({brokers} broker(s) running)"));
            return Ok(());
        }
        render(&rows, colour);

        // The prompt is for a human; the read is not conditional on one.
        // Reading either way means a pipe is answered in order and ends at
        // EOF, which is both what a script would want and what makes this
        // loop testable without a pty.
        let line = match util::read_answer("> ")? {
            Some(l) => l,
            None => return Ok(()),
        };
        match parse_choice(&line, rows.len()) {
            Choice::Quit => return Ok(()),
            Choice::Refresh => continue,
            // A failed install is reported and the loop carries on: the queue
            // has changed either way, and the operator is probably about to
            // answer the next one.
            Choice::Approve(i) => {
                // A mount and a domain are the approvals with further
                // questions in them (path and mode, scope). Asked here, at
                // the moment of approving, rather than encoded into the row
                // syntax: the answer is a decision about this one request,
                // and the agent's path, read-only and session-only have to
                // stay the answers of least effort.
                let mut path = String::new();
                let asked = match rows[i].kind.as_str() {
                    proto::KIND_MOUNT => match ask_path(&rows[i].attr)? {
                        Some(p) => {
                            path = p;
                            ask_mode(if path.is_empty() { &rows[i].attr } else { &path })?
                        }
                        None => None,
                    },
                    proto::KIND_DOMAIN => ask_scope("allow", &rows[i].attr)?,
                    _ => Some(String::new()),
                };
                let mode = match asked {
                    Some(m) => m,
                    None => continue,
                };
                if let Err(e) = approve(layout, &rows[i].id, &mode, &path) {
                    util::note(e.msg);
                }
            }
            Choice::Deny(i, reason) => {
                if let Err(e) = deny(layout, &rows[i].id, &reason) {
                    util::note(e.msg);
                }
            }
            Choice::ApproveAll => approve_all(layout, &rows),
            Choice::DenyAll(reason) => deny_all(layout, &rows, &reason),
            Choice::Unknown => util::note(format!(
                "not a choice: {} (want 1-{}, 1d [reason] to deny, a for all, d [reason] to deny all)",
                line.trim(),
                rows.len()
            )),
        }
    }
}

/// `llm-custody request --help`.
pub fn usage() {
    print!(
        "\
Usage: llm-custody [--dir PATH] [--pid PID] request <command> [ARG...]

What jailed agents have asked for and are blocked on. A package goes into the
toolbox profile, a mount attaches a host directory to the jail that asked, a
domain is added to that jail's network whitelist.

  list             pending requests from every running jail (alias: ls)
                   [--json] machine-readable, for a terminal integration
  answer           the same queue, interactively: pick a numbered row to
                   approve or deny it without typing a request id (a mount
                   then asks for its host path and mode, a domain for
                   session or persist)
                   `a` approves every listed row with the narrowest mode
                   (mount read-only, domain for this session), `d` denies
                   every listed row
                   text after a denial is the reason the agent is given:
                   `2d already mounted, see /workspace/x`, `d not today`
  approve ID       grant it and unblock the jail
                   [--mode ro|full|limited|none|overlay] how a mount is
                   attached (default ro), [--mode session|persist] how
                   long a domain stays allowed (default session); ignored
                   for a package
                   [--path PATH] the host path to mount for a mount
                   request, replacing the one the agent asked for; needed
                   when the agent gave only a name
  deny ID          refuse it [--reason TEXT], the text goes to the agent

--pid restricts all of this to one session's broker.
"
    );
}

pub fn cmd_request(g: &Global, args: &[String]) -> Result<()> {
    if wants_help(args) || args.is_empty() {
        usage();
        return Ok(());
    }
    let tb = g.toolbox()?;
    let (cmd, rest) = args.split_first().expect("checked above");
    match unalias("request", cmd) {
        "list" => cmd_requests(&tb, rest),
        "answer" => answer(&tb.layout),
        "approve" => cmd_approve(&tb, rest),
        "deny" => cmd_deny(&tb, rest),
        other => usage_err(format!("request: unknown command: {other} (try --help)")),
    }
}


fn cmd_requests(tb: &Toolbox, args: &[String]) -> Result<()> {
    match args.first().map(String::as_str) {
        None => requests(&tb.layout),
        Some("--json") => requests_json(&tb.layout),
        Some(a) => usage_err(format!("requests: unknown option: {a} (try --help)")),
    }
}

fn cmd_approve(tb: &Toolbox, args: &[String]) -> Result<()> {
    let mut id = None;
    let mut mode = String::new();
    let mut path = String::new();
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
            "--path" => {
                i += 1;
                match args.get(i) {
                    Some(v) => path = v.clone(),
                    None => return usage_err("--path needs a host path"),
                }
            }
            a if a.starts_with('-') => return usage_err(format!("approve: unknown option: {a}")),
            a => id = Some(a.to_string()),
        }
        i += 1;
    }
    match id {
        Some(id) => approve(&tb.layout, &id, &mode, &path),
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
        Some(id) => deny(&tb.layout, &id, &reason),
        None => usage_err("deny needs a request id - see the requests command"),
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
        // Scoped to one session by `--pid`: the others are left exactly as
        // they are, stale registrations included, because an unscoped command
        // is the one that owns that cleanup.
        if matches!(&layout.broker_filter, Some(want) if *want != id) {
            continue;
        }
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
            broker::cleanup(&dir);
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

    #[test]
    fn choices_parse() {
        assert_eq!(parse_choice("1", 3), Choice::Approve(0));
        assert_eq!(parse_choice("3", 3), Choice::Approve(2));
        assert_eq!(parse_choice("2d", 3), Choice::Deny(1, String::new()));
        assert_eq!(parse_choice(" 2D \n", 3), Choice::Deny(1, String::new()));
        assert_eq!(parse_choice("2 d", 3), Choice::Deny(1, String::new()));
        assert_eq!(parse_choice("", 3), Choice::Quit);
        assert_eq!(parse_choice("q", 3), Choice::Quit);
        assert_eq!(parse_choice("r", 3), Choice::Refresh);
        assert_eq!(parse_choice("a", 3), Choice::ApproveAll);
        assert_eq!(parse_choice(" A ", 3), Choice::ApproveAll);
        assert_eq!(parse_choice("all", 3), Choice::ApproveAll);
        assert_eq!(parse_choice("d", 3), Choice::DenyAll(String::new()));
        assert_eq!(parse_choice("D", 3), Choice::DenyAll(String::new()));
        // Out of range, zero and nonsense are all the same mistake.
        assert_eq!(parse_choice("0", 3), Choice::Unknown);
        assert_eq!(parse_choice("4", 3), Choice::Unknown);
        assert_eq!(parse_choice("4d", 3), Choice::Unknown);
        assert_eq!(parse_choice("yes", 3), Choice::Unknown);
    }

    #[test]
    fn a_denial_carries_its_reason() {
        // The reason keeps its own case and inner spacing; only the choice
        // in front of it is case-insensitive.
        assert_eq!(
            parse_choice("1d you don't need that, check igaptly", 3),
            Choice::Deny(0, "you don't need that, check igaptly".to_string())
        );
        assert_eq!(
            parse_choice(" 2D  Use  /workspace/x \n", 3),
            Choice::Deny(1, "Use  /workspace/x".to_string())
        );
        assert_eq!(parse_choice("2 d not now", 3), Choice::Deny(1, "not now".to_string()));
        assert_eq!(parse_choice("d not today", 3), Choice::DenyAll("not today".to_string()));
        assert_eq!(parse_choice("deny not today", 3), Choice::DenyAll("not today".to_string()));
        // Out of range stays a mistake, reason or not.
        assert_eq!(parse_choice("4d nope", 3), Choice::Unknown);
        // Trailing text on anything but a denial is not silently dropped.
        assert_eq!(parse_choice("1 please", 3), Choice::Unknown);
        assert_eq!(parse_choice("a please", 3), Choice::Unknown);
        assert_eq!(parse_choice("q now", 3), Choice::Unknown);
    }

    #[test]
    fn home_expands_only_as_a_leading_component() {
        assert_eq!(expand_home("~/src/x", Some("/home/op")), "/home/op/src/x");
        assert_eq!(expand_home("~", Some("/home/op")), "/home/op");
        assert_eq!(expand_home("~", Some("/home/op/")), "/home/op");
        assert_eq!(expand_home("~other/x", Some("/home/op")), "~other/x");
        assert_eq!(expand_home("/srv/~/x", Some("/home/op")), "/srv/~/x");
        assert_eq!(expand_home("~/x", None), "~/x");
    }

    #[test]
    fn a_named_mount_reads_as_needing_a_path() {
        assert_eq!(describe(proto::KIND_MOUNT, "/srv/x"), "mount /srv/x");
        assert_eq!(describe(proto::KIND_MOUNT, "igbackup"), "mount igbackup (no path given)");
        assert_eq!(describe(proto::KIND_PACKAGE, "igbackup"), "igbackup");
    }

    #[test]
    fn scope_answers_parse() {
        // Session is the answer of least effort, like read-only for a mount.
        assert_eq!(parse_scope("\n"), Some(Some("session")));
        assert_eq!(parse_scope("s"), Some(Some("session")));
        assert_eq!(parse_scope(" P \n"), Some(Some("persist")));
        assert_eq!(parse_scope("q"), Some(None));
        assert_eq!(parse_scope("yes"), None);
        // Every answer is a mode the broker accepts.
        for line in ["s", "p"] {
            assert!(proto::validate_domain_mode(parse_scope(line).unwrap().unwrap()).is_ok());
        }
    }
}
