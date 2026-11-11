//! The live-session registry: which jails are running, where each one's
//! launchers are, and what each one has outstanding.
//!
//! The runner publishes every run under `$XDG_RUNTIME_DIR/llm-custody` as
//! `<pid>.state` (a `key=value` record describing the session), plus the
//! `<pid>.sync` / `<pid>.mount` launcher symlinks and a `current` /
//! `current.mount` pair naming the most recently started run.
//!
//! All of this stays host-side: `$RUNDIR` is never mounted into a sandbox,
//! which is what keeps a jailed agent from folding its own work out to the
//! host unreviewed or attaching another tree to itself.

use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::paths;
use crate::proto;
use crate::util::{self, fail, Error, Result, EXIT_ERROR};

/// A session's state record. First `=` splits, so values stay free-form and
/// only a newline - which none of the fields can hold - would need escaping.
pub struct Record {
    entries: Vec<(String, String)>,
}

impl Record {
    pub fn parse(text: &str) -> Record {
        let mut entries = Vec::new();
        for line in text.lines() {
            if let Some((k, v)) = line.split_once('=') {
                entries.push((k.to_string(), v.to_string()));
            }
        }
        Record { entries }
    }

    pub fn read(path: &Path) -> Option<Record> {
        fs::read_to_string(path).ok().map(|t| Record::parse(&t))
    }

    /// An absent key reads as empty, which is also what a record written by an
    /// older runner gives for a key added since - so asking for a key is
    /// always safe, and an unknown one is ignorable.
    pub fn get(&self, key: &str) -> &str {
        self.entries
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
    }

    /// Why a session has nothing to fold back, in the operator's own flag
    /// vocabulary. Derived from the record rather than hardcoded, so it stays
    /// true if another flag combination ever ends up binding trees directly.
    pub fn reason(&self) -> String {
        let git = match self.get("git") {
            "" => "?",
            g => g,
        };
        if self.get("overlay") == "1" {
            format!("--git {git} with --overlay-workspace")
        } else {
            format!("--git {git} without --overlay-workspace")
        }
    }
}

/// What `sync` found for the session it was pointed at.
pub enum SyncTarget {
    /// The session's mid-session sync launcher.
    Launcher(PathBuf),
    /// A live session that isolated nothing, so there is nothing to fold
    /// back. Not an error: the host tree already has what the agent wrote.
    Direct { pid: String, workspace: String, reason: String },
}

/// One live session, as `session list` reports it.
pub struct Session {
    pub pid: String,
    /// False for a session started by a runner from before the state record
    /// existed: a plausible mix after a rebuild, since sessions outlive the
    /// build they were started from.
    pub has_record: bool,
    pub tool: String,
    pub workspace: String,
    pub git: String,
    pub overlay: bool,
    /// Empty when the session isolated nothing; `reason` then says why.
    pub sync: String,
    pub reason: String,
    pub mount: String,
    pub dirty: u64,
    pub mounts: usize,
    pub pending: usize,
}

pub struct Registry {
    dir: PathBuf,
}

impl Registry {
    pub fn new(dir: PathBuf) -> Registry {
        Registry { dir }
    }

    /// The registry the runner writes to, same fallback chain and all.
    pub fn open() -> Registry {
        Registry::new(paths::runtime_dir())
    }

    /// `current`/`current.mount` unless a pid was named. A pid is a filename
    /// component here, so it is checked before it is ever joined on: a value
    /// carrying a `/` would otherwise point the lookup anywhere on the host.
    fn target(&self, pid: Option<&str>, current: &str, suffix: &str) -> Result<PathBuf> {
        match pid {
            None => Ok(self.dir.join(current)),
            Some(p) => {
                if !pid_ok(p) {
                    return util::usage_err(format!("not a pid: {p}"));
                }
                Ok(self.dir.join(format!("{p}{suffix}")))
            }
        }
    }

    pub fn resolve_mount(&self, pid: Option<&str>) -> Result<PathBuf> {
        let target = self.target(pid, "current.mount", ".mount")?;
        if target.exists() {
            return Ok(target);
        }
        no_such_session(&target)
    }

    pub fn resolve_sync(&self, pid: Option<&str>) -> Result<SyncTarget> {
        let target = self.target(pid, "current", ".sync")?;
        if target.exists() {
            return Ok(SyncTarget::Launcher(target));
        }
        // Before calling it a missing session: a live run that binds every
        // tree straight through registers a state record but no launcher.
        let state = match pid {
            Some(p) => {
                let s = self.dir.join(format!("{p}.state"));
                if s.exists() {
                    Some(s)
                } else {
                    None
                }
            }
            None => self.live_state_files().into_iter().next().map(|(_, p)| p),
        };
        if let Some(rec) = state.as_deref().and_then(Record::read) {
            if rec.get("sync").is_empty() {
                return Ok(SyncTarget::Direct {
                    pid: rec.get("pid").to_string(),
                    workspace: rec.get("workspace").to_string(),
                    reason: rec.reason(),
                });
            }
        }
        no_such_session(&target)
    }

    /// State records of the sessions whose runner is still around, oldest pid
    /// first. A dead one is left on disk: the runner's own exit trap owns that
    /// cleanup, and a reader guessing at it would race a session that is
    /// merely between two writes.
    fn live_state_files(&self) -> Vec<(u32, PathBuf)> {
        let mut out = Vec::new();
        let entries = match fs::read_dir(&self.dir) {
            Ok(e) => e,
            Err(_) => return out,
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let pid = match name.strip_suffix(".state").and_then(|p| p.parse::<u32>().ok()) {
                Some(p) => p,
                None => continue,
            };
            if !util::pid_alive(pid) {
                continue;
            }
            out.push((pid, entry.path()));
        }
        out.sort_by_key(|(pid, _)| *pid);
        out
    }

    /// Live sessions that registered a `.sync` launcher but no state record.
    fn legacy_sync_links(&self) -> Vec<(u32, PathBuf)> {
        let mut out = Vec::new();
        let entries = match fs::read_dir(&self.dir) {
            Ok(e) => e,
            Err(_) => return out,
        };
        for entry in entries.filter_map(|e| e.ok()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let pid = match name.strip_suffix(".sync").and_then(|p| p.parse::<u32>().ok()) {
                Some(p) => p,
                None => continue,
            };
            if self.dir.join(format!("{pid}.state")).exists() || !util::pid_alive(pid) {
                continue;
            }
            let path = fs::canonicalize(entry.path()).unwrap_or_else(|_| entry.path());
            out.push((pid, path));
        }
        out.sort_by_key(|(pid, _)| *pid);
        out
    }

    pub fn sessions(&self) -> Vec<Session> {
        let mut out = Vec::new();
        for (pid, path) in self.live_state_files() {
            let rec = match Record::read(&path) {
                Some(r) => r,
                None => continue,
            };
            let sync = rec.get("sync").to_string();
            let mount = rec.get("mount").to_string();
            // Both launchers live in the session's $RUNDIR, which is also
            // where the dirty counter and the mount records are, so one of
            // them is enough to find the rest.
            let rundir = rundir_of(&sync).or_else(|| rundir_of(&mount));
            let broker = match rec.get("broker") {
                // A record from a runner that did not publish the broker dir,
                // or a session whose broker failed to start. The registry
                // layout is the fallback: broker ids are the runner's pid.
                "" => self.dir.join("brokers").join(pid.to_string()),
                b => PathBuf::from(b),
            };
            out.push(Session {
                pid: pid.to_string(),
                has_record: true,
                tool: rec.get("tool").to_string(),
                workspace: rec.get("workspace").to_string(),
                git: rec.get("git").to_string(),
                overlay: rec.get("overlay") == "1",
                reason: rec.reason(),
                sync,
                mount,
                dirty: rundir.as_deref().map(dirty_count).unwrap_or(0),
                mounts: rundir.as_deref().map(mount_count).unwrap_or(0),
                pending: pending_count(&broker),
            });
        }
        for (pid, path) in self.legacy_sync_links() {
            out.push(Session {
                pid: pid.to_string(),
                has_record: false,
                tool: String::new(),
                workspace: String::new(),
                git: String::new(),
                overlay: false,
                sync: path.display().to_string(),
                reason: String::new(),
                mount: String::new(),
                dirty: 0,
                mounts: 0,
                pending: 0,
            });
        }
        out.sort_by(|a, b| a.pid.cmp(&b.pid));
        out
    }

    pub fn list(&self) -> Result<()> {
        let sessions = self.sessions();
        if sessions.is_empty() {
            // A registry directory with no entries and a dead `current`
            // symlink mean the same thing to the operator - no running jail -
            // so both report it the same way instead of an ENOENT.
            util::note("no live llm-custody sessions");
            return Ok(());
        }
        for s in &sessions {
            if !s.has_record {
                println!("pid {}  (no state record)", s.pid);
                println!("    sync   {}", s.sync);
                continue;
            }
            println!("pid {}  {}  {}", s.pid, s.tool, s.workspace);
            let dirty = match s.dirty {
                0 => "clean".to_string(),
                n => format!("{n} unsynced path(s)"),
            };
            println!(
                "    git {}, {}, {}, {} mount(s), {} request(s) pending",
                if s.git.is_empty() { "?" } else { &s.git },
                if s.overlay { "overlay" } else { "no overlay" },
                dirty,
                s.mounts,
                s.pending
            );
            if s.sync.is_empty() {
                println!("    sync   nothing to sync - {}", s.reason);
            } else {
                println!("    sync   {}", s.sync);
            }
            if !s.mount.is_empty() {
                println!("    mount  {}", s.mount);
            }
        }
        Ok(())
    }
}

/// A pid names a registry file; anything that is not a plain number is either
/// a typo or an attempt to walk out of the registry directory.
pub fn pid_ok(pid: &str) -> bool {
    !pid.is_empty() && pid.chars().all(|c| c.is_ascii_digit())
}

fn no_such_session<T>(target: &Path) -> Result<T> {
    fail(format!(
        "no such llm-custody session: {}\n       llm-custody session list shows the live ones",
        target.display()
    ))
}

/// The launcher sits directly in the session's $RUNDIR.
fn rundir_of(launcher: &str) -> Option<PathBuf> {
    if launcher.is_empty() {
        return None;
    }
    Path::new(launcher).parent().map(Path::to_path_buf)
}

/// Paths the agent wrote and nobody has folded back yet, as the runner's
/// watcher last counted them.
fn dirty_count(rundir: &Path) -> u64 {
    fs::read_to_string(rundir.join("dirty"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

/// One directory per attached tree, each holding the `record` the mount
/// controller wrote. A directory without one is a mount being set up or one
/// whose setup failed, and counting it would overstate what the jail sees.
fn mount_count(rundir: &Path) -> usize {
    let entries = match fs::read_dir(rundir.join("mounts")) {
        Ok(e) => e,
        Err(_) => return 0,
    };
    entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("record").is_file())
        .count()
}

/// Read rather than asked over the control socket: listing sessions must not
/// block on a wedged broker, and this file is exactly what the broker keeps
/// up to date for a second terminal to read at any time.
fn pending_count(broker: &Path) -> usize {
    fs::read_to_string(broker.join(proto::PENDING_FILE))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

/// Hand the session's own launcher the rest of the command line.
///
/// `--pause` has to happen after the launcher is done and an exec never comes
/// back, so with it the launcher runs as a child instead and the caller's own
/// exit path holds the pane open.
pub fn run_launcher(exe: &Path, args: &[String], pause: bool) -> Result<()> {
    if !pause {
        return util::exec_argv(exe, args);
    }
    let status = util::ctx(
        Command::new(exe).args(args).status(),
        format!("running {}", exe.display()),
    )?;
    match status.code() {
        Some(0) => Ok(()),
        // The launcher has already said what went wrong in its own voice;
        // repeating it here would only add a second prefix.
        Some(code) => Err(Error { msg: String::new(), code }),
        None => fail(format!("{} was killed by a signal", exe.display())),
    }
}

/// With nothing else on the line this is a keybinding's way in: ask for the
/// one thing it cannot know, the path, and attach it the safe way.
pub fn prompt_for_mount() -> Result<Vec<String>> {
    use std::io::{BufRead, Write};
    if !std::io::stdin().is_terminal() {
        return util::usage_err("mount needs a command (see: llm-custody mount --help)");
    }
    eprint!("host path to mount read-only (add --mode for anything else): ");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let path = line.trim();
    if path.is_empty() {
        return Err(Error { msg: String::new(), code: EXIT_ERROR });
    }
    // `--` so a path starting with a dash is still a path.
    Ok(vec!["add".to_string(), "--".to_string(), path.to_string()])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "llm-custody-session-{}-{}-{tag}",
            std::process::id(),
            util::now_secs()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    /// Our own pid is the one process guaranteed to be alive while the test
    /// runs, so every fixture session is registered under it.
    fn me() -> u32 {
        std::process::id()
    }

    #[test]
    fn record_splits_on_the_first_equals_only() {
        let rec = Record::parse(
            "state=sync\ntool=pi\nworkspace=/home/user/dev\ngit=limited\noverlay=0\nsync=/run/x/sync\nenv=K=V\njunk\n",
        );
        assert_eq!(rec.get("tool"), "pi");
        assert_eq!(rec.get("workspace"), "/home/user/dev");
        assert_eq!(rec.get("env"), "K=V");
        // A key no runner writes yet reads as empty rather than failing.
        assert_eq!(rec.get("manifest"), "");
    }

    #[test]
    fn reason_names_the_flags_that_bound_the_tree_directly() {
        assert_eq!(
            Record::parse("git=full\noverlay=0\n").reason(),
            "--git full without --overlay-workspace"
        );
        assert_eq!(
            Record::parse("git=full\noverlay=1\n").reason(),
            "--git full with --overlay-workspace"
        );
        assert_eq!(Record::parse("").reason(), "--git ? without --overlay-workspace");
    }

    #[test]
    fn pid_resolution_picks_the_named_session() {
        let dir = scratch("resolve");
        let rundir = dir.join("run");
        fs::create_dir_all(&rundir).unwrap();
        fs::write(rundir.join("sync"), "#!/bin/sh\n").unwrap();
        fs::write(rundir.join("mount"), "#!/bin/sh\n").unwrap();
        symlink(rundir.join("sync"), dir.join(format!("{}.sync", me()))).unwrap();
        symlink(rundir.join("mount"), dir.join(format!("{}.mount", me()))).unwrap();
        symlink(rundir.join("sync"), dir.join("current")).unwrap();
        symlink(rundir.join("mount"), dir.join("current.mount")).unwrap();

        let reg = Registry::new(dir.clone());
        let pid = me().to_string();
        assert!(matches!(reg.resolve_sync(Some(&pid)), Ok(SyncTarget::Launcher(_))));
        assert_eq!(reg.resolve_mount(Some(&pid)).unwrap(), dir.join(format!("{}.mount", me())));
        assert_eq!(reg.resolve_mount(None).unwrap(), dir.join("current.mount"));
        // A pid with nothing registered is an error, not the current session.
        assert!(reg.resolve_mount(Some("999999999")).is_err());
        // Never joined onto the registry path.
        assert_eq!(reg.resolve_mount(Some("../etc")).unwrap_err().code, util::EXIT_USAGE);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_session_with_no_launcher_explains_itself_instead_of_failing() {
        let dir = scratch("direct");
        fs::write(
            dir.join(format!("{}.state", me())),
            format!("state=direct\ntool=pi\npid={}\nworkspace=/w\ngit=full\noverlay=0\nsync=\n", me()),
        )
        .unwrap();
        let reg = Registry::new(dir.clone());
        match reg.resolve_sync(None).expect("direct session") {
            SyncTarget::Direct { pid, workspace, reason } => {
                assert_eq!(pid, me().to_string());
                assert_eq!(workspace, "/w");
                assert_eq!(reason, "--git full without --overlay-workspace");
            }
            SyncTarget::Launcher(p) => panic!("unexpected launcher {}", p.display()),
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_session_reports_its_dirty_mount_and_request_counts() {
        let dir = scratch("counts");
        let rundir = dir.join("run");
        fs::create_dir_all(rundir.join("mounts/foo")).unwrap();
        fs::create_dir_all(rundir.join("mounts/bar")).unwrap();
        // No record: a mount still being set up is not one the jail sees.
        fs::create_dir_all(rundir.join("mounts/half")).unwrap();
        fs::write(rundir.join("mounts/foo/record"), "name=foo\nmode=ro\n").unwrap();
        fs::write(rundir.join("mounts/bar/record"), "name=bar\nmode=full\n").unwrap();
        fs::write(rundir.join("dirty"), "3\n").unwrap();
        fs::write(rundir.join("sync"), "#!/bin/sh\n").unwrap();
        let broker = dir.join("brokers").join(me().to_string());
        fs::create_dir_all(&broker).unwrap();
        fs::write(broker.join(proto::PENDING_FILE), "2\n").unwrap();
        fs::write(
            dir.join(format!("{}.state", me())),
            format!(
                "state=sync\ntool=pi\npid={}\nworkspace=/w\ngit=limited\noverlay=1\nsync={}\nmount={}\n",
                me(),
                rundir.join("sync").display(),
                rundir.join("mount").display()
            ),
        )
        .unwrap();

        let sessions = Registry::new(dir.clone()).sessions();
        assert_eq!(sessions.len(), 1);
        let s = &sessions[0];
        assert_eq!(s.tool, "pi");
        assert_eq!(s.git, "limited");
        assert!(s.overlay);
        assert_eq!(s.dirty, 3);
        assert_eq!(s.mounts, 2);
        assert_eq!(s.pending, 2);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dead_pid_is_not_a_live_session() {
        let dir = scratch("dead");
        // Pid 1 exists; a pid this high cannot be running on any host that
        // still has a 32-bit pid_t.
        fs::write(dir.join("4294967000.state"), "state=sync\ntool=pi\npid=4294967000\n").unwrap();
        assert!(Registry::new(dir.clone()).sessions().is_empty());
        let _ = fs::remove_dir_all(&dir);
    }
}
