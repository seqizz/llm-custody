//! `launch`: find a tool's runner script and become it.
//!
//! The runners stay what they are - one `writeShellApplication` per tool,
//! each with its own flag parser. Nothing is interpreted here: everything
//! after the tool name is handed over untouched, as an argv array.
//!
//! The umbrella package sets `LLMCUSTODY_RUNNER_DIR` to a directory holding
//! one symlink per tool (`pi -> .../bin/llm-custody-pi`), which is what makes
//! the override in the operator's system flake visible to `launch`: the
//! symlink follows whichever runner that package was built with. With the
//! variable unset (`cargo run` during development) the PATH is the fallback.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::paths;
use crate::util::{self, fail, usage_err, Result};

/// Set by the umbrella wrapper; one symlink per tool.
pub const RUNNER_DIR_ENV: &str = "LLMCUSTODY_RUNNER_DIR";
/// What a runner is called on the PATH when the variable is not set.
const RUNNER_PREFIX: &str = "llm-custody-";

fn runner_dir() -> Option<PathBuf> {
    match env::var_os(RUNNER_DIR_ENV) {
        Some(v) if !v.is_empty() => Some(PathBuf::from(v)),
        _ => None,
    }
}

/// Tool names, from the runner dir when there is one and from the PATH
/// otherwise. Sorted and deduplicated, because a PATH scan sees the same name
/// once per directory that has it and only the first one would ever run.
fn available(dir: Option<&Path>) -> Vec<String> {
    let mut out: Vec<String> = match dir {
        Some(d) => fs::read_dir(d)
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default(),
        None => {
            let mut names = Vec::new();
            for d in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
                let entries = match fs::read_dir(&d) {
                    Ok(e) => e,
                    Err(_) => continue,
                };
                for entry in entries.filter_map(|e| e.ok()) {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if let Some(tool) = name.strip_prefix(RUNNER_PREFIX) {
                        if !tool.is_empty() {
                            names.push(tool.to_string());
                        }
                    }
                }
            }
            names
        }
    };
    out.sort();
    out.dedup();
    out
}

fn resolve(dir: Option<&Path>, tool: &str) -> Result<PathBuf> {
    // A tool name becomes a path component under the runner dir, so it has to
    // pass the same "usable as one component" test a profile element does.
    if !paths::lease_name_ok(tool) {
        return usage_err(format!("not usable as a tool name: {tool}"));
    }
    let found = match dir {
        Some(d) => {
            let p = d.join(tool);
            // symlink_metadata, so a symlink whose target has been garbage
            // collected is still reported as the tool it is: the exec failure
            // names the missing store path, where "no such tool" would send
            // the operator looking for the wrong problem.
            fs::symlink_metadata(&p).is_ok().then_some(p)
        }
        None => which(&format!("{RUNNER_PREFIX}{tool}")),
    };
    match found {
        Some(p) => Ok(p),
        None => {
            let have = available(dir);
            let have = if have.is_empty() { "(none)".to_string() } else { have.join(" ") };
            fail(format!("no such tool: {tool} (have: {have})"))
        }
    }
}

/// First executable of that name on the PATH, the way execvp would find it.
fn which(name: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    for dir in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
        let p = dir.join(name);
        if let Ok(md) = fs::metadata(&p) {
            if md.is_file() && md.permissions().mode() & 0o111 != 0 {
                return Some(p);
            }
        }
    }
    None
}

pub fn usage() {
    print!(
        "\
Usage: llm-custody launch [TOOL] [RUNNER OPTIONS] [-- TOOL ARGS...]

Start TOOL in a sandbox. Everything after the name goes to that tool's
runner untouched, so `llm-custody launch pi --git full -- -p hello` is the
same command line `llm-custody-pi` took.

  (no tool)   list the tools this build can launch
  --help      this text; `llm-custody launch TOOL --help` is the runner's own

Runners are looked up in ${dir} when that is set, and as
{prefix}TOOL on the PATH otherwise.
",
        dir = RUNNER_DIR_ENV,
        prefix = RUNNER_PREFIX,
    );
}

pub fn run(args: &[String]) -> Result<()> {
    let dir = runner_dir();
    let (tool, rest) = match args.split_first() {
        // Listing rather than a usage error: the question "what can I start
        // here" is the one a bare `launch` is asking.
        None => {
            list(dir.as_deref());
            return Ok(());
        }
        Some((t, r)) => (t.as_str(), r),
    };
    if tool == "-h" || tool == "--help" {
        usage();
        println!();
        list(dir.as_deref());
        return Ok(());
    }
    if tool.starts_with('-') {
        return usage_err(format!("launch takes a tool name first, not {tool}"));
    }
    let exe = resolve(dir.as_deref(), tool)?;
    util::exec_argv(&exe, rest)
}

fn list(dir: Option<&Path>) {
    let tools = available(dir);
    if tools.is_empty() {
        util::note("no runners found - is this the umbrella package?");
        return;
    }
    for t in tools {
        println!("{t}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "llm-custody-launch-{}-{tag}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn the_runner_dir_decides_which_tools_exist() {
        let dir = scratch("runners");
        // Symlinks, as the umbrella builds them; the target does not have to
        // resolve for the lookup to name the right path.
        std::os::unix::fs::symlink("/nix/store/fake/bin/llm-custody-pi", dir.join("pi")).unwrap();
        fs::write(dir.join("claude"), "#!/bin/sh\n").unwrap();

        assert_eq!(available(Some(&dir)), vec!["claude".to_string(), "pi".to_string()]);
        assert_eq!(resolve(Some(&dir), "claude").unwrap(), dir.join("claude"));
        // A link whose target is gone is still this build's pi.
        assert_eq!(resolve(Some(&dir), "pi").unwrap(), dir.join("pi"));

        let err = resolve(Some(&dir), "nosuch").unwrap_err();
        assert_eq!(err.code, util::EXIT_ERROR);
        assert!(err.msg.contains("no such tool: nosuch"), "{}", err.msg);
        assert!(err.msg.contains("claude pi"), "the message lists what is there: {}", err.msg);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_tool_name_can_never_be_a_path() {
        let dir = scratch("names");
        for bad in ["../pi", "a/b", "", ".", "..", "pi pi"] {
            let err = resolve(Some(&dir), bad).unwrap_err();
            assert_eq!(err.code, util::EXIT_USAGE, "accepted {bad:?}");
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
