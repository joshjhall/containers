# Mojo Installation Deprecation Notice

## Issue

The Modular CLI has been deprecated and replaced with the Magic CLI. The current Mojo installation script no longer works because:

1. The `modular` CLI is deprecated
2. It requires authentication (`modular auth`) before installation
3. The tool will NOT fetch the latest releases of MAX or Mojo
4. Users should use the new Magic CLI instead

## Error Message

```text
/usr/bin/modular: error: please run `modular auth` before attempting to install or update a package
NOTE: The `modular` CLI tool is deprecated and has been replaced by the `magic` CLI tool.
This tool WILL NOT fetch the latest releases of MAX or Mojo.
See https://docs.modular.com/magic/ for details.
```

## Solution Required

The Mojo installation script needs to be updated to:

1. Use the new Magic CLI instead of Modular CLI
2. Handle authentication requirements (likely needs user credentials)
3. Follow the new installation process documented at <https://docs.modular.com/magic/>

## Temporary Workaround

Until the script is updated, Mojo cannot be installed in the container without:

1. User authentication credentials
2. Updating to use the Magic CLI
3. Following the new installation workflow

## Action Items

- [ ] Research the new Magic CLI installation process
- [ ] Update mojo.sh to use Magic CLI
- [ ] Document authentication requirements
- [ ] Consider if Mojo should remain as a container feature given auth requirements
