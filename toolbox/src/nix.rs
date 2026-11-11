//! Every call out to nix.
//!
//! Two rules hold for all of it. First, arguments go out as an argv array -
//! there is no shell anywhere in this file, so a package name, a reason string
//! or anything else that reached this process from a jailed agent cannot be
//! word-split, globbed or substituted into a command. Second, output is read
//! from `--json` wherever nix offers it, instead of being scraped out of
//! human-readable text whose layout changes between releases.

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::json::{self, Json};
use crate::util::{fail, Result};

pub struct Nix {
    profile: std::path::PathBuf,
}

/// Spelled out rather than relying on the host's nix.conf: a host with neither
/// feature enabled would otherwise fail with nix's own error about an
/// experimental feature, which reads like a bug in this tool.
fn nix_command() -> Command {
    let mut c = Command::new("nix");
    c.arg("--extra-experimental-features").arg("nix-command flakes");
    c
}

/// `nix` itself is deliberately not a build input of this package: the host's
/// own nix (possibly Lix) is the one that owns /nix/var/nix and matches the
/// running daemon, so it has to come off PATH rather than the store path a
/// build-time reference would pin.
fn missing_nix(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::NotFound
}

fn run(mut cmd: Command, what: &str) -> Result<()> {
    // Inherited, not captured: a `nix profile install` can spend minutes
    // building and its progress is the only thing telling the operator the
    // terminal has not hung.
    cmd.stdin(Stdio::null()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    let status = match cmd.status() {
        Ok(s) => s,
        Err(e) if missing_nix(&e) => {
            return fail("no nix on PATH - this is the host-side half of the toolbox")
        }
        Err(e) => return fail(format!("running nix: {e}")),
    };
    if !status.success() {
        return match status.code() {
            Some(c) => fail(format!("nix {what} failed (exit {c})")),
            None => fail(format!("nix {what} was killed by a signal")),
        };
    }
    Ok(())
}

fn capture(mut cmd: Command, what: &str) -> Result<String> {
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::inherit());
    let out = match cmd.output() {
        Ok(o) => o,
        Err(e) if missing_nix(&e) => {
            return fail("no nix on PATH - this is the host-side half of the toolbox")
        }
        Err(e) => return fail(format!("running nix: {e}")),
    };
    if !out.status.success() {
        return fail(format!("nix {what} failed (exit {})", out.status.code().unwrap_or(-1)));
    }
    match String::from_utf8(out.stdout) {
        Ok(s) => Ok(s),
        Err(_) => fail(format!("nix {what} produced output that is not UTF-8")),
    }
}

impl Nix {
    pub fn new(profile: &Path) -> Nix {
        Nix { profile: profile.to_path_buf() }
    }

    fn profile_cmd(&self, sub: &str) -> Command {
        let mut c = nix_command();
        c.arg("profile").arg(sub).arg("--profile").arg(&self.profile);
        c
    }

    /// The installed element names, or an empty list when no profile exists
    /// yet. Names are what `nix profile remove`/`upgrade` address an entry by
    /// and what a lease file records, and they are the only field of the
    /// manifest anything here needs.
    ///
    /// Nix reports `elements` as an object keyed by element name from the
    /// manifest version that introduced names; older versions emit an array of
    /// unnamed entries, and no name means `remove`/`upgrade` cannot address an
    /// entry either, so that case is an error rather than a silent empty list
    /// (which would make every package look permanent and never be pruned).
    pub fn names(&self) -> Result<Vec<String>> {
        if !self.profile.symlink_metadata().is_ok() {
            return Ok(Vec::new());
        }
        let mut c = self.profile_cmd("list");
        c.arg("--json");
        let out = capture(c, "profile list")?;
        let v = match json::parse(&out) {
            Ok(v) => v,
            Err(e) => return fail(format!("could not parse `nix profile list --json`: {e}")),
        };
        let elements = match v.get("elements") {
            Some(e) => e,
            None => return fail("`nix profile list --json` has no `elements` field"),
        };
        match elements {
            Json::Obj(entries) => Ok(entries.iter().map(|(name, _)| name.clone()).collect()),
            Json::Arr(_) => fail(
                "this nix reports profile elements without names, which is too old for \
                 name-addressed install/remove - upgrade nix, or manage this profile by hand",
            ),
            _ => fail("`nix profile list --json` has an `elements` field of an unexpected shape"),
        }
    }

    /// `list` is a passthrough: nix's own rendering is what the operator
    /// expects to see, and there is nothing this could add by reformatting it.
    pub fn list_passthrough(&self) -> Result<()> {
        run(self.profile_cmd("list"), "profile list")
    }

    pub fn install(&self, refs: &[String]) -> Result<()> {
        let mut c = self.profile_cmd("install");
        c.args(refs.iter().map(OsStr::new));
        run(c, "profile install")
    }

    pub fn remove(&self, names: &[String]) -> Result<()> {
        let mut c = self.profile_cmd("remove");
        c.args(names.iter().map(OsStr::new));
        run(c, "profile remove")
    }

    /// Empty `names` upgrades everything. Nix records the flake ref each entry
    /// was installed from, so this re-resolves those refs and builds a new
    /// generation from the result.
    pub fn upgrade(&self, names: &[String]) -> Result<()> {
        let mut c = self.profile_cmd("upgrade");
        if names.is_empty() {
            c.arg("--all");
        } else {
            c.args(names.iter().map(OsStr::new));
        }
        run(c, "profile upgrade")
    }

    pub fn wipe_history(&self, older_than: Option<&str>, dry_run: bool) -> Result<()> {
        let mut c = self.profile_cmd("wipe-history");
        if let Some(p) = older_than {
            c.arg("--older-than").arg(p);
        }
        if dry_run {
            c.arg("--dry-run");
        }
        run(c, "profile wipe-history")
    }
}

/// Register `link` as an indirect GC root pointing at `target`.
///
/// A profile outside /nix/var/nix/profiles is not automatically a GC root, so
/// without this a `nix-collect-garbage` between sessions could take the whole
/// toolbox with it. Returns the error rather than dying: a toolbox that works
/// until the next GC beats an install that refused to finish, and the caller
/// falls back to a plain symlink.
pub fn add_indirect_root(link: &Path, target: &Path) -> Result<()> {
    let mut c = Command::new("nix-store");
    c.arg("--indirect")
        .arg("--add-root")
        .arg(link)
        .arg("--realise")
        .arg(target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    match c.status() {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => fail(format!("nix-store --add-root failed (exit {})", s.code().unwrap_or(-1))),
        Err(e) => fail(format!("running nix-store: {e}")),
    }
}
