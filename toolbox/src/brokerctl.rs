//! `requests`, `approve` and `deny`: the operator's side of the brokers.
//!
//! None of this touches the profile directly. It finds the broker holding a
//! request and tells it what to do, because the broker is the only thing that
//! knows which jail client is still waiting on the answer.

use crate::broker::{self, BrokerHandle};
use crate::json::{self, Json};
use crate::paths::Layout;
use crate::proto;
use crate::util::{self, fail, Result};
use std::io::{IsTerminal, Write};
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
/// `domain NAME`.
fn describe(kind: &str, attr: &str) -> String {
    match kind {
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
    let handles = broker::discover(layout);
    let mut rows = Vec::new();
    for h in &handles {
        let reply = match broker::control_call(h, &json::Obj::new().str("op", "list").finish(), LIST_TIMEOUT) {
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
    let handles = broker::discover(layout);
    if handles.is_empty() {
        util::note("no jail broker is running");
        return Ok(());
    }

    let mut rows: Vec<(String, String, String, String, String)> = Vec::new();
    for h in &handles {
        let reply = match broker::control_call(h, &json::Obj::new().str("op", "list").finish(), LIST_TIMEOUT) {
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
    util::note("approve <id> to grant it (a mount: --mode ro|full|limited|none|overlay, default ro; a domain: --mode session|persist, default session), deny <id> to refuse");
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
    let handles = broker::discover(layout);
    if handles.is_empty() {
        return fail("no jail broker is running, so there is nothing to answer");
    }
    if let Some(h) = route(&handles, id) {
        return broker::control_call(h, &msg, ANSWER_TIMEOUT);
    }
    // Unroutable id: try them all rather than refusing on a formatting
    // detail, and report the real "no such request" from the brokers.
    let mut last = None;
    for h in &handles {
        match broker::control_call(h, &msg, ANSWER_TIMEOUT) {
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
pub fn approve(layout: &Layout, id: &str, mode: &str) -> Result<()> {
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
    let msg = json::Obj::new()
        .str("op", "approve")
        .str("id", id)
        .str("mode", mode)
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
        util::note(format!("{attr} mounted at {guest} ({})", reply.str_field("mode")));
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

/// The mode question for a mount approval. Empty answer means read-only;
/// `q` backs out without answering the request at all.
fn ask_mode(path: &str) -> Result<Option<String>> {
    loop {
        if std::io::stdout().is_terminal() {
            print!(
                "  mode for {path} [{}] (ro=read-only, full=real tree rw, limited/none=synced copy, overlay=cow; q=back): ",
                proto::DEFAULT_MOUNT_MODE
            );
            let _ = std::io::stdout().flush();
        }
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let ans = line.trim().to_ascii_lowercase();
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
        if std::io::stdout().is_terminal() {
            print!("  {verb} {name} for [s]ession / [p]ersist / [q] back: ");
            let _ = std::io::stdout().flush();
        }
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line)? == 0 {
            return Ok(None);
        }
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

/// What a typed line at the `answer` prompt meant.
#[derive(Debug, PartialEq)]
pub enum Choice {
    Approve(usize),
    Deny(usize),
    Refresh,
    Quit,
    Unknown,
}

/// `3` approves the third row, `3d` denies it, `r` re-reads the queue, an
/// empty line or `q` leaves. Indexes rather than request ids: an id is a
/// broker pid and a counter, fine for routing and hopeless to type.
pub fn parse_choice(line: &str, rows: usize) -> Choice {
    let line = line.trim().to_ascii_lowercase();
    match line.as_str() {
        "" | "q" | "quit" => return Choice::Quit,
        "r" | "refresh" => return Choice::Refresh,
        _ => {}
    }
    let (digits, deny) = match line.strip_suffix('d') {
        Some(d) => (d.trim_end(), true),
        None => (line.as_str(), false),
    };
    match digits.parse::<usize>() {
        Ok(n) if n >= 1 && n <= rows => {
            if deny {
                Choice::Deny(n - 1)
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
        if std::io::stdout().is_terminal() {
            print!("> ");
            let _ = std::io::stdout().flush();
        }
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line)? == 0 {
            return Ok(());
        }
        match parse_choice(&line, rows.len()) {
            Choice::Quit => return Ok(()),
            Choice::Refresh => continue,
            // A failed install is reported and the loop carries on: the queue
            // has changed either way, and the operator is probably about to
            // answer the next one.
            Choice::Approve(i) => {
                // A mount and a domain are the approvals with a second
                // question in them (mode, scope). Asked here, at the moment
                // of approving, rather than encoded into the row syntax: the
                // answer is a decision about this one request, and read-only
                // or session-only has to stay the answer of least effort.
                let asked = match rows[i].kind.as_str() {
                    proto::KIND_MOUNT => ask_mode(&rows[i].attr)?,
                    proto::KIND_DOMAIN => ask_scope("allow", &rows[i].attr)?,
                    _ => Some(String::new()),
                };
                let mode = match asked {
                    Some(m) => m,
                    None => continue,
                };
                if let Err(e) = approve(layout, &rows[i].id, &mode) {
                    util::note(e.msg);
                }
            }
            Choice::Deny(i) => {
                if let Err(e) = deny(layout, &rows[i].id, "") {
                    util::note(e.msg);
                }
            }
            Choice::Unknown => util::note(format!(
                "not a choice: {} (want 1-{}, or 1d to deny)",
                line.trim(),
                rows.len()
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn choices_parse() {
        assert_eq!(parse_choice("1", 3), Choice::Approve(0));
        assert_eq!(parse_choice("3", 3), Choice::Approve(2));
        assert_eq!(parse_choice("2d", 3), Choice::Deny(1));
        assert_eq!(parse_choice(" 2D \n", 3), Choice::Deny(1));
        assert_eq!(parse_choice("", 3), Choice::Quit);
        assert_eq!(parse_choice("q", 3), Choice::Quit);
        assert_eq!(parse_choice("r", 3), Choice::Refresh);
        // Out of range, zero and nonsense are all the same mistake.
        assert_eq!(parse_choice("0", 3), Choice::Unknown);
        assert_eq!(parse_choice("4", 3), Choice::Unknown);
        assert_eq!(parse_choice("4d", 3), Choice::Unknown);
        assert_eq!(parse_choice("yes", 3), Choice::Unknown);
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
