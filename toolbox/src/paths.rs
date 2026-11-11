//! Where everything lives.
//!
//! Every path here is deliberately the same one the shell implementation used,
//! including the fallback order, so an existing toolbox keeps working without
//! being moved or re-created.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::util::{self, Result};

/// Directory name under the toolbox dir holding one file per leased package.
pub const LEASES_DIR: &str = "leases";
/// Pointer symlink straight to the resolved /nix/store profile. Deliberately
/// not `profile/bin`: nix writes `profile -> profile-N-link` and whether that
/// hop is relative or absolute is nix's business, while an absolute one names
/// a host path the sandbox does not have. The store is bound wholesale, so a
/// link to a store path resolves identically on both sides of the bind.
pub const CURRENT_LINK: &str = "current";
/// The nix profile itself, i.e. what `nix profile install --profile` targets.
pub const PROFILE_LINK: &str = "profile";
/// Default lease lifetime. Past this with no `add`/`renew`, `prune` drops the
/// package.
pub const DEFAULT_LEASE_DAYS: u64 = 30;

pub struct Layout {
    pub dir: PathBuf,
    /// `$XDG_RUNTIME_DIR/llm-custody`, shared with the jail runner: it
    /// registers `<pid>.toolbox` and `current.toolbox` there, and the brokers
    /// live under it too.
    pub runtime: PathBuf,
    /// Flake a bare attribute resolves against.
    pub flake: String,
    pub lease_period: Duration,
    /// When set, only this broker is visible. `--pid` scopes an answer to one
    /// session while several jails are running; broker ids are the runner's
    /// pid (the runner starts `serve --broker-id "$$"`), so the flag and the
    /// id are the same string.
    pub broker_filter: Option<String>,
}

fn env_path(key: &str) -> Option<PathBuf> {
    match env::var_os(key) {
        Some(v) if !v.is_empty() => Some(PathBuf::from(v)),
        _ => None,
    }
}

/// `$XDG_RUNTIME_DIR/llm-custody`, falling back the same way the runner does
/// so both sides agree on hosts without XDG_RUNTIME_DIR.
pub fn runtime_dir() -> PathBuf {
    let base = env_path("XDG_RUNTIME_DIR")
        .or_else(|| env_path("TMPDIR"))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("llm-custody")
}

fn default_toolbox_dir() -> PathBuf {
    if let Some(p) = env_path("LLMCUSTODY_TOOLBOX_DIR") {
        return p;
    }
    let config = env_path("XDG_CONFIG_HOME")
        .or_else(|| env_path("HOME").map(|h| h.join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"));
    config.join("llm-custody").join("toolbox")
}

impl Layout {
    /// `--dir` wins; otherwise the toolbox of the most recently started
    /// session, because with `--state-dir` in play that is not necessarily the
    /// default one and an operator answering a request should not have to
    /// remember which. Falls back to the configured default when no session is
    /// running.
    pub fn resolve(explicit: Option<PathBuf>) -> Result<Layout> {
        let runtime = runtime_dir();
        let dir = match explicit {
            Some(d) => d,
            None => {
                let link = runtime.join("current.toolbox");
                match fs::canonicalize(&link) {
                    Ok(p) => p,
                    Err(_) => default_toolbox_dir(),
                }
            }
        };
        let flake = env::var("LLMCUSTODY_TOOLBOX_FLAKE")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "nixpkgs".to_string());
        let lease_period = match env::var("LLMCUSTODY_TOOLBOX_LEASE_DAYS") {
            Ok(v) if !v.is_empty() => util::parse_duration(&v, 'd')?,
            _ => Duration::from_secs(DEFAULT_LEASE_DAYS * 86400),
        };
        Ok(Layout { dir, runtime, flake, lease_period, broker_filter: None })
    }

    /// Restrict every broker lookup to one session. Separate from `resolve`
    /// because a toolbox dir and a session are independent choices: `--dir`
    /// says which profile, `--pid` says which jail.
    pub fn with_broker_filter(mut self, pid: Option<String>) -> Layout {
        self.broker_filter = pid;
        self
    }

    pub fn profile(&self) -> PathBuf {
        self.dir.join(PROFILE_LINK)
    }

    pub fn current(&self) -> PathBuf {
        self.dir.join(CURRENT_LINK)
    }

    pub fn leases(&self) -> PathBuf {
        self.dir.join(LEASES_DIR)
    }

    pub fn lock_file(&self) -> PathBuf {
        self.dir.join(".lock")
    }

    pub fn brokers(&self) -> PathBuf {
        self.runtime.join("brokers")
    }

    pub fn broker(&self, id: &str) -> PathBuf {
        self.brokers().join(id)
    }

    /// A bare name resolves against the configured flake; anything already
    /// carrying a flake reference (`#`, a scheme, a path) is handed to nix
    /// verbatim. Host-side only - the broker never lets a jailed client reach
    /// this with anything but a bare attribute.
    pub fn to_ref(&self, attr: &str) -> String {
        let looks_like_ref = attr.contains('#')
            || attr.contains(':')
            || attr.starts_with('/')
            || attr == "."
            || attr.starts_with("./");
        if looks_like_ref {
            attr.to_string()
        } else {
            format!("{}#{}", self.flake, attr)
        }
    }
}

/// The name nix gives a profile element: the last dot-separated component of
/// the flake fragment (`nixpkgs#python3Packages.black` -> `black`), or the last
/// path component for a ref with no fragment. Mirrors nix's own
/// getNameFromURL, and is how an already-installed package is recognised - nix
/// refuses a second element under an existing name, so a repeat request has to
/// renew instead of reinstall.
pub fn ref_name(r: &str) -> String {
    let base = match r.rsplit_once('#') {
        Some((_, frag)) => {
            // `pkg^out1,out2` selects outputs and is not part of the name.
            let frag = frag.split('^').next().unwrap_or(frag);
            frag.rsplit('.').next().unwrap_or(frag)
        }
        None => r.trim_end_matches('/').rsplit('/').next().unwrap_or(r),
    };
    base.to_string()
}

/// A profile element name is also a path component under `leases/`, so it has
/// to be rejected before it is ever joined onto a path. Nix element names are
/// attribute components and never contain any of this, which makes a name that
/// does a sign of a mangled manifest rather than a case to support.
pub fn lease_name_ok(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.starts_with('.')
        && !name.contains('/')
        && !name.contains('\0')
        && !name.chars().any(|c| c.is_control() || c.is_whitespace())
}

/// True when `p` resolves to something under /nix/store, which is the only
/// form a sandbox can follow: the store is bound wholesale, anything else is a
/// host path the jail has no mount for.
pub fn in_store(p: &Path) -> bool {
    p.starts_with("/nix/store")
}
