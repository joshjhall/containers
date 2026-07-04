//! Platform detection from the git `origin` remote.
//!
//! Mirrors the detection table `/next-issue` uses: `github.com`/`ghe.` → GitHub
//! (`gh`), `gitlab.com`/`gitlab.` → GitLab (`glab`). Pure URL parsing is split
//! from the `git` subprocess call so the classification is unit-testable.

use std::fmt;
use std::process::Command;

/// Which issue tracker a repo is hosted on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    /// GitHub.com or GitHub Enterprise (`gh` CLI).
    GitHub,
    /// GitLab.com or self-hosted GitLab (`glab` CLI).
    GitLab,
}

impl Platform {
    /// Parse a `--platform` flag value.
    #[must_use]
    pub fn from_flag(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "github" | "gh" => Some(Self::GitHub),
            "gitlab" | "glab" => Some(Self::GitLab),
            _ => None,
        }
    }
}

impl fmt::Display for Platform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::GitHub => write!(f, "github"),
            Self::GitLab => write!(f, "gitlab"),
        }
    }
}

/// Classify a remote URL string into a [`Platform`].
///
/// Handles SSH (`git@github.com:owner/repo.git`), HTTPS
/// (`https://gitlab.com/owner/repo.git`), GitHub Enterprise (`ghe.` host
/// prefix) and self-hosted GitLab (`gitlab.` host prefix). Returns `None` when
/// the host matches neither family.
#[must_use]
pub fn classify_remote(url: &str) -> Option<Platform> {
    let host = host_of(url).unwrap_or(url);
    let host = host.to_ascii_lowercase();
    if host == "github.com" || host.starts_with("ghe.") || host.contains(".ghe.") {
        return Some(Platform::GitHub);
    }
    if host == "gitlab.com" || host.starts_with("gitlab.") || host.contains(".gitlab.") {
        return Some(Platform::GitLab);
    }
    // Fall back to a substring match for hosts that embed the name elsewhere
    // (e.g. `github.example.com`), preferring the more specific check above.
    if host.contains("github") {
        return Some(Platform::GitHub);
    }
    if host.contains("gitlab") {
        return Some(Platform::GitLab);
    }
    None
}

/// Extract the host component from an SSH or HTTPS git remote URL.
fn host_of(url: &str) -> Option<&str> {
    // scp-like SSH: git@host:owner/repo.git
    if let Some(rest) = url.strip_prefix("git@") {
        return rest.split(':').next();
    }
    // ssh://git@host/owner/repo or https://host/owner/repo
    let after_scheme = url.split("://").nth(1).unwrap_or(url);
    // Strip optional `user@` then take up to the first `/` or `:`.
    let after_user = after_scheme.rsplit('@').next().unwrap_or(after_scheme);
    after_user.split(['/', ':']).next().filter(|h| !h.is_empty())
}

/// Read the `origin` remote URL via `git remote get-url origin`.
///
/// # Errors
///
/// Returns an error when `git` cannot be spawned or the command fails (e.g. not
/// a git repo, or no `origin` remote configured).
pub fn origin_remote_url() -> Result<String, Box<dyn std::error::Error>> {
    let output = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .map_err(|e| format!("failed to run git: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("git remote get-url origin failed: {}", stderr.trim()).into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_github_ssh_and_https() {
        assert_eq!(
            classify_remote("git@github.com:joshjhall/containers.git"),
            Some(Platform::GitHub)
        );
        assert_eq!(
            classify_remote("https://github.com/joshjhall/containers.git"),
            Some(Platform::GitHub)
        );
    }

    #[test]
    fn classifies_gitlab_ssh_and_https() {
        assert_eq!(classify_remote("git@gitlab.com:group/proj.git"), Some(Platform::GitLab));
        assert_eq!(classify_remote("https://gitlab.com/group/proj.git"), Some(Platform::GitLab));
    }

    #[test]
    fn classifies_enterprise_and_selfhosted() {
        assert_eq!(classify_remote("git@ghe.corp.example:team/repo.git"), Some(Platform::GitHub));
        assert_eq!(
            classify_remote("https://gitlab.internal.example.com/team/repo.git"),
            Some(Platform::GitLab)
        );
    }

    #[test]
    fn unknown_host_returns_none() {
        assert_eq!(classify_remote("git@bitbucket.org:team/repo.git"), None);
        assert_eq!(classify_remote("https://example.com/x/y.git"), None);
    }

    #[test]
    fn ssh_url_scheme_form() {
        assert_eq!(
            classify_remote("ssh://git@github.com/joshjhall/containers.git"),
            Some(Platform::GitHub)
        );
    }

    #[test]
    fn from_flag_parses_aliases() {
        assert_eq!(Platform::from_flag("github"), Some(Platform::GitHub));
        assert_eq!(Platform::from_flag("GitHub"), Some(Platform::GitHub));
        assert_eq!(Platform::from_flag("glab"), Some(Platform::GitLab));
        assert_eq!(Platform::from_flag("svn"), None);
    }

    #[test]
    fn display_round_trips() {
        assert_eq!(Platform::GitHub.to_string(), "github");
        assert_eq!(Platform::GitLab.to_string(), "gitlab");
    }
}
