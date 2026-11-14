//! The toolbox itself: the nix profile a jail sees on its PATH, plus the lease
//! files that decide how long each package stays in it.
//!
//! Every operation that changes the profile or the leases runs under one lock
//! and is written so a nix command that fails leaves no lease behind it: a
//! package is leased only after it is known to be installed, and a lease is
//! deleted only after its element is known to be gone.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::path::PathBuf;
use std::time::Duration;

use crate::nix::{self, Nix};
use crate::paths::{self, Layout};
use crate::util::{self, fail, Result};

/// Held for the duration of a mutation; released when the file closes.
///
/// One toolbox is shared by every jail under the same `--state-dir`, so two
/// sessions can be provisioned at once. Nix locks the profile for its own
/// generation switch, but `current` is retargeted after that lock drops:
/// without this, two interleaved adds can leave `current` on the older
/// generation and the second package missing from every jail's PATH until the
/// next add. Prune takes it too - a wipe racing an add would be deleting
/// generations the other side is still creating.
///
/// flock is per open file description, so two threads of one broker contend
/// with each other here exactly as two separate CLI processes do.
pub struct Lock {
    _file: File,
}

pub struct Lease {
    pub path: PathBuf,
    pub name: String,
    pub mtime: u64,
}

pub struct AddOutcome {
    /// Flake refs this call actually installed.
    pub installed: Vec<String>,
    /// Elements that were already there and only had their lease pushed out.
    pub renewed: Vec<String>,
    /// Commands that appeared on the jail's PATH as a result.
    pub new_commands: Vec<String>,
    /// True when nothing could be leased because nix reported no names.
    pub unleased: bool,
}

pub struct PruneOutcome {
    pub removed: Vec<String>,
    /// Expired leases whose element was already gone; the lease file is all
    /// there was left to drop.
    pub orphaned: Vec<String>,
    pub generations_dropped: usize,
    pub dry_run: bool,
}

pub struct Toolbox {
    pub layout: Layout,
    nix: Nix,
}

impl Toolbox {
    pub fn new(layout: Layout) -> Toolbox {
        let nix = Nix::new(&layout.profile());
        Toolbox { layout, nix }
    }

    pub fn require_dir(&self) -> Result<()> {
        if self.layout.dir.is_dir() {
            Ok(())
        } else {
            fail(format!("no toolbox at {} yet", self.layout.dir.display()))
        }
    }

    pub fn lock(&self) -> Result<Lock> {
        util::mkdir_p(&self.layout.dir)?;
        let path = self.layout.lock_file();
        let file = util::ctx(File::create(&path), format!("opening {}", path.display()))?;
        util::ctx(file.lock(), format!("locking {}", path.display()))?;
        Ok(Lock { _file: file })
    }

    // ---- current symlink -------------------------------------------------

    /// Point `current` straight at the resolved store path of the profile.
    ///
    /// Must run after every generation change: it is what makes a new package
    /// visible to an already-running jail, whose bind resolves through this
    /// link. Written as an indirect GC root rather than a plain symlink
    /// because a profile outside /nix/var/nix/profiles is not automatically
    /// rooted, so a `nix-collect-garbage` between sessions could otherwise
    /// take the whole toolbox with it.
    pub fn refresh_current(&self) -> Result<()> {
        let profile = self.layout.profile();
        if profile.symlink_metadata().is_err() {
            // Nothing installed yet; nothing to point at.
            return Ok(());
        }
        let real = util::ctx(
            fs::canonicalize(&profile),
            format!("resolving {}", profile.display()),
        )?;
        if !paths::in_store(&real) {
            return fail(format!(
                "toolbox profile resolves to {}, outside /nix/store - a jail would not see it",
                real.display()
            ));
        }
        let current = self.layout.current();
        if nix::add_indirect_root(&current, &real).is_err() {
            // A toolbox that works until the next GC beats an install that
            // refused to finish.
            util::note("could not register a GC root, falling back to a plain symlink");
            util::symlink_atomic(&real, &current)?;
        }
        Ok(())
    }

    /// Generations nix has accumulated here. Counted with symlink metadata,
    /// not by resolving: a generation whose store path a garbage collection
    /// already took is a dangling symlink, and that is exactly one of the
    /// links `wipe-history` exists to clean up.
    fn generation_count(&self) -> usize {
        let entries = match fs::read_dir(&self.layout.dir) {
            Ok(e) => e,
            Err(_) => return 0,
        };
        entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                let n = e.file_name();
                let n = n.to_string_lossy();
                n.starts_with(&format!("{}-", paths::PROFILE_LINK)) && n.ends_with("-link")
            })
            .count()
    }

    /// Command names currently on the jail's PATH through this toolbox. Used
    /// to report what an install actually made available: the operator asks
    /// for a package, the agent asked for a command, and the two rarely have
    /// the same name.
    fn bin_names(&self) -> BTreeSet<String> {
        let bin = self.layout.current().join("bin");
        match fs::read_dir(bin) {
            Ok(entries) => entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect(),
            Err(_) => BTreeSet::new(),
        }
    }

    // ---- leases ----------------------------------------------------------

    pub fn lease_path(&self, name: &str) -> Result<PathBuf> {
        if !paths::lease_name_ok(name) {
            return fail(format!("not usable as a profile element name: {name}"));
        }
        Ok(self.layout.leases().join(name))
    }

    /// Create the lease or push its timestamp to now, which is the whole of
    /// "renewed". Always a fresh atomic write rather than a timestamp update:
    /// one code path, and a half-written lease can never be observed.
    pub fn renew_lease(&self, name: &str) -> Result<()> {
        let path = self.lease_path(name)?;
        util::mkdir_p(&self.layout.leases())?;
        util::write_atomic(&path, format!("{name}\n").as_bytes())
    }

    pub fn drop_lease(&self, name: &str) -> Result<bool> {
        let path = self.lease_path(name)?;
        match fs::remove_file(&path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => fail(format!("removing {}: {e}", path.display())),
        }
    }

    pub fn has_lease(&self, name: &str) -> bool {
        match self.lease_path(name) {
            Ok(p) => p.is_file(),
            Err(_) => false,
        }
    }

    /// Every lease on disk, oldest first so the reports lead with whatever is
    /// closest to expiring.
    pub fn read_leases(&self) -> Result<Vec<Lease>> {
        let dir = self.layout.leases();
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return fail(format!("reading {}: {e}", dir.display())),
        };
        let mut out = Vec::new();
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            let file_name = entry.file_name().to_string_lossy().into_owned();
            // Leaves out the in-flight temp files of a concurrent writer,
            // which are dotted.
            if file_name.starts_with('.') || !path.is_file() {
                continue;
            }
            // The content is authoritative, not the file name: it is what gets
            // handed to `nix profile remove`. The name is the fallback for a
            // lease written by something else, or emptied by a filesystem that
            // lost the tail of a write.
            let name = fs::read_to_string(&path)
                .ok()
                .and_then(|s| s.lines().next().map(str::to_string))
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| file_name.clone());
            let mtime = util::mtime_secs(&path)?;
            out.push(Lease { path, name: name.trim().to_string(), mtime });
        }
        out.sort_by(|a, b| a.mtime.cmp(&b.mtime).then_with(|| a.name.cmp(&b.name)));
        Ok(out)
    }

    // ---- operations ------------------------------------------------------

    pub fn list(&self) -> Result<()> {
        self.require_dir()?;
        self.nix.list_passthrough()
    }

    /// Install what is missing and lease everything this call is answerable
    /// for. Re-adding something already installed is the ordinary way to renew
    /// its lease, so that case installs nothing: nix refuses a second element
    /// under an existing name anyway, and an operator answering the same
    /// request twice should not get an error for it.
    ///
    /// The caller holds the lock.
    pub fn add_locked(&self, attrs: &[String]) -> Result<AddOutcome> {
        util::mkdir_p(&self.layout.dir)?;
        let before_names: BTreeSet<String> = self.nix.names()?.into_iter().collect();
        let before_bins = self.bin_names();

        let mut to_install = Vec::new();
        let mut renewed = Vec::new();
        for attr in attrs {
            let r = self.layout.to_ref(attr);
            let name = paths::ref_name(&r);
            if before_names.contains(&name) {
                renewed.push(name);
            } else {
                to_install.push(r);
            }
        }

        if !to_install.is_empty() {
            util::note(format!("installing {}", to_install.join(" ")));
            // Nothing is leased before this returns: a failed install must not
            // leave a lease for a package that is not in the profile.
            self.nix.install(&to_install)?;
        }

        let after_names: Vec<String> = self.nix.names()?;
        let unleased = after_names.is_empty() && self.layout.profile().symlink_metadata().is_ok();

        // New elements come from a diff of nix's own names rather than from
        // ref_name, so a ref whose element nix named differently than the
        // guess still gets a lease.
        for name in &after_names {
            if !before_names.contains(name) {
                self.renew_lease(name)?;
            }
        }
        for name in &renewed {
            self.renew_lease(name)?;
        }

        self.refresh_current()?;

        let new_commands = self
            .bin_names()
            .into_iter()
            .filter(|b| !before_bins.contains(b))
            .collect();

        Ok(AddOutcome { installed: to_install, renewed, new_commands, unleased })
    }

    pub fn add(&self, attrs: &[String]) -> Result<AddOutcome> {
        let _lock = self.lock()?;
        self.add_locked(attrs)
    }

    /// Uninstall packages whatever their lease state, leased or permanent, and
    /// drop the lease of a name whose element is already gone (removed with a
    /// hand-run `nix profile remove`, say). Names are sorted against the
    /// profile first, so one unknown name is reported instead of failing the
    /// nix call for every other name given with it.
    pub fn remove(&self, names: &[String]) -> Result<Vec<(String, RemoveResult)>> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let installed: BTreeSet<String> = self.nix.names()?.into_iter().collect();
        let present: Vec<String> =
            names.iter().filter(|n| installed.contains(*n)).cloned().collect();
        if !present.is_empty() {
            self.nix.remove(&present)?;
            self.refresh_current()?;
        }
        let mut out = Vec::new();
        for n in names {
            let r = if installed.contains(n) {
                // Only after the removal succeeded: a lease outliving its
                // element is dead weight prune would have to special-case
                // forever, but a lease deleted for an element that is still
                // installed would silently make that package permanent.
                if paths::lease_name_ok(n) {
                    self.drop_lease(n)?;
                }
                RemoveResult::Removed
            } else if self.has_lease(n) {
                self.drop_lease(n)?;
                RemoveResult::LeaseOnly
            } else {
                RemoveResult::NotInstalled
            };
            out.push((n.clone(), r));
        }
        Ok(out)
    }

    /// Rebuild installed entries from the flake refs they were installed with.
    /// Wrapped rather than left to a hand-written `nix profile upgrade`
    /// because that command stops at the generation switch: `current` would
    /// stay on the old store path, so every running jail would keep the old
    /// PATH, and the generation just built would carry no GC root at all.
    ///
    /// Leases are not touched. An upgrade is maintenance, not an operator
    /// asking for a package, so it is not a renewal.
    pub fn upgrade(&self, names: &[String]) -> Result<bool> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let before = fs::canonicalize(self.layout.profile()).ok();
        if names.is_empty() {
            util::note("upgrading every installed package");
        } else {
            util::note(format!("upgrading {}", names.join(" ")));
        }
        self.nix.upgrade(names)?;
        self.refresh_current()?;
        let after = fs::canonicalize(self.layout.profile()).ok();
        // Compared by store path, not generation count: an upgrade that
        // resolves to what is already installed is the common case and should
        // not read like something happened.
        Ok(before != after)
    }

    /// Push a lease out without touching the profile. `add` does this too; the
    /// separate verb exists for renewing without naming a flake ref, and for
    /// putting a permanent (unleased) package back under a lease deliberately.
    pub fn renew(&self, names: &[String]) -> Result<Vec<(String, bool)>> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let installed: BTreeSet<String> = self.nix.names()?.into_iter().collect();
        let mut out = Vec::new();
        for n in names {
            if !installed.contains(n) {
                return fail(format!(
                    "{n} is not an installed element - check the list command"
                ));
            }
            let was_permanent = !self.has_lease(n);
            self.renew_lease(n)?;
            out.push((n.clone(), was_permanent));
        }
        Ok(out)
    }

    /// Permanence is the absence of a lease, so pinning is deleting the file -
    /// no second state to keep consistent with the first. The profile is
    /// untouched, which is why this needs no generation switch; the lock is
    /// still taken because prune walks the same directory.
    pub fn pin(&self, names: &[String]) -> Result<Vec<(String, PinResult)>> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let installed: BTreeSet<String> = self.nix.names()?.into_iter().collect();
        let mut out = Vec::new();
        for n in names {
            let r = if self.has_lease(n) {
                self.drop_lease(n)?;
                PinResult::Pinned
            } else if installed.contains(n) {
                PinResult::AlreadyPermanent
            } else {
                PinResult::NotInstalled
            };
            out.push((n.clone(), r));
        }
        Ok(out)
    }

    /// What prune would do, and when, without doing any of it. Reports against
    /// the whole profile rather than just the leases directory, because "this
    /// one has no lease and is therefore permanent" answers the question as
    /// often as a date does.
    pub fn lease_report(&self, period: Duration) -> Result<Vec<LeaseRow>> {
        self.require_dir()?;
        let now = util::now_secs();
        let names: BTreeSet<String> = self.nix.names()?.into_iter().collect();
        let mut leased = BTreeSet::new();
        let mut rows = Vec::new();
        for lease in self.read_leases()? {
            leased.insert(lease.name.clone());
            let age = now.saturating_sub(lease.mtime);
            rows.push(LeaseRow {
                name: lease.name.clone(),
                state: if !names.contains(&lease.name) {
                    LeaseState::Orphaned { age }
                } else if age >= period.as_secs() {
                    LeaseState::Expired { age }
                } else {
                    LeaseState::Live { age, left: period.as_secs() - age }
                },
            });
        }
        for name in names {
            if !leased.contains(&name) {
                rows.push(LeaseRow { name, state: LeaseState::Permanent });
            }
        }
        Ok(rows)
    }

    /// Remove the packages whose lease has gone unrenewed for `period`, drop
    /// their lease files, retarget `current` and wipe the generations that
    /// held them.
    ///
    /// Deliberately no garbage collection: this unpins, and leaves reclaiming
    /// the store to whatever runs `nix-collect-garbage` next, which is where
    /// the operator's policy for the rest of the store already lives.
    pub fn prune(&self, period: Duration, dry_run: bool) -> Result<PruneOutcome> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let now = util::now_secs();
        let cutoff = now.saturating_sub(period.as_secs());
        let names: BTreeSet<String> = self.nix.names()?.into_iter().collect();

        let mut remove = Vec::new();
        let mut orphaned = Vec::new();
        let mut stale_files = Vec::new();
        for lease in self.read_leases()? {
            if lease.mtime > cutoff {
                continue;
            }
            stale_files.push(lease.path.clone());
            if names.contains(&lease.name) {
                remove.push(lease.name);
            } else {
                orphaned.push(lease.name);
            }
        }

        if dry_run || stale_files.is_empty() {
            return Ok(PruneOutcome {
                removed: remove,
                orphaned,
                generations_dropped: 0,
                dry_run: true,
            });
        }

        if !remove.is_empty() {
            // Before any lease file is touched: if nix refuses, the leases
            // stay and the next prune tries again, rather than leaving
            // installed packages silently permanent.
            self.nix.remove(&remove)?;
        }
        for path in &stale_files {
            if let Err(e) = fs::remove_file(path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    return fail(format!("removing {}: {e}", path.display()));
                }
            }
        }
        // Ahead of wipe-history, so the GC root `current` carries already
        // points at the generation that survives rather than at one about to
        // lose its profile-N-link.
        self.refresh_current()?;
        let before = self.generation_count();
        self.nix.wipe_history(None, false)?;
        let after = self.generation_count();

        Ok(PruneOutcome {
            removed: remove,
            orphaned,
            generations_dropped: before.saturating_sub(after),
            dry_run: false,
        })
    }

    /// `gc`: drop the generations `add` and `upgrade` leave behind between
    /// prunes, without touching what is installed.
    pub fn gc(&self, older_than: Option<&str>, dry_run: bool) -> Result<usize> {
        self.require_dir()?;
        let _lock = self.lock()?;
        let before = self.generation_count();
        self.nix.wipe_history(older_than, dry_run)?;
        // The current generation keeps its number, so `current` still
        // resolves - refreshed anyway because the GC root it carries is the
        // one thing that must never point at something wipe-history dropped.
        self.refresh_current()?;
        let after = self.generation_count();
        Ok(before.saturating_sub(after))
    }
}

pub enum RemoveResult {
    Removed,
    /// No such element, only its lease was left to drop.
    LeaseOnly,
    NotInstalled,
}

pub enum PinResult {
    Pinned,
    AlreadyPermanent,
    NotInstalled,
}

pub struct LeaseRow {
    pub name: String,
    pub state: LeaseState,
}

pub enum LeaseState {
    Live { age: u64, left: u64 },
    Expired { age: u64 },
    /// A lease whose element someone already removed by hand.
    Orphaned { age: u64 },
    Permanent,
}
