# Quick Start: Updating WAF Lambda Packages

This guide covers the primary operational task: updating the WAF Lambda packages from upstream.

---

## 1. Check for New Upstream Versions

Before updating, check what versions are available:

**Upstream Changelog:** https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md

| Current Default | Latest Available |
|-----------------|------------------|
| `v4.0.3` | Check changelog |

---

## 2. Trigger the Build Workflow

### Via GitHub UI

1. Go to **Actions** tab in the repository
2. Select **Build WAF Lambda Packages** from the left sidebar
3. Click **Run workflow** dropdown (right side)
4. Fill in the inputs:

| Input | Description | Example |
|-------|-------------|---------|
| **upstream_ref** | Upstream version tag to build | `v4.1.2` |
| **version_bump** | Module version bump type | `patch` |

5. Click **Run workflow**

### Via GitHub CLI

```bash
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.1.2 \
  -f version_bump=patch
```

---

## 3. Review the Generated PR

The workflow creates a PR with:
- Updated `lambda/log_parser.zip`
- Updated `lambda/reputation_lists_parser.zip`
- Build information and test results

**Review checklist:**
- [ ] Zip file sizes are reasonable (~1-2MB each)
- [ ] No security vulnerabilities flagged
- [ ] Build tests passed

---

## 4. Merge and Tag Release

After PR approval:

```bash
# Merge the PR (via GitHub UI or CLI)
gh pr merge <pr-number>

# Pull latest changes
git checkout master && git pull

# Create release tag (if version bump was requested)
git tag -a "v3.2.0" -m "Release v3.2.0"
git push origin "v3.2.0"
```

---

## 5. Verify the Update

Check the workflow run succeeded:
```bash
gh run list --workflow="Build WAF Lambda Packages" --limit 5
```

---

## Troubleshooting

### Build Fails with "Poetry export failed"

The upstream version may use Poetry without a lock file. This should be fixed in the current build script, but if it occurs:

1. Check the workflow logs for the exact error
2. Ensure `scripts/build-lambda.sh` includes `poetry lock` before `poetry export`

### Build Fails with Missing Dependencies

The upstream structure may have changed. Check:
1. Does `upstream/source/log_parser/` exist?
2. Does `upstream/source/lib/` exist?

### Need to Rollback

```bash
# Revert to previous upstream version
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.0.3 \
  -f version_bump=none
```

---

## Version Bump Guide

| Scenario | Bump Type |
|----------|-----------|
| Security patches from upstream | `patch` |
| New features from upstream | `minor` |
| Breaking changes / Python upgrade | `major` |
| Testing only, no release | `none` |

---

## Additional Resources

- [README.md](../README.md) - Full module documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture diagrams
- [TESTING.md](TESTING.md) - Local testing guide
