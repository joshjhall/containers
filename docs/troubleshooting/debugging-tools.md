# Debugging Tools

This section covers the built-in debugging tools, diagnostic commands, and how
to get help when troubleshooting container issues.

## Check build logs

```bash
# Inside container
check-build-logs.sh python-dev
check-build-logs.sh

# Or manually
cat /var/log/build-*.log
```

## Verify installed versions

```bash
# Inside container
check-installed-versions.sh

# Or manually check specific tools
python3 --version
node --version
rustc --version
go version
```

## Test feature installations

```bash
# Run unit tests
./tests/run_unit_tests.sh

# Test specific feature
./tests/test_feature.sh python-dev

# Check if feature script ran
grep "python-dev" /var/log/build-master-summary.log
```

## Inspect container layers

```bash
# View layer history
docker history myproject:dev

# Dive into layers
dive myproject:dev

# Export filesystem
docker export mycontainer > container.tar
```

## Debug build failures

```bash
# Build with debug output
docker build --progress=plain --no-cache .

# Stop at specific stage
docker build --target=<stage-name> .

# Run failed step manually
docker run -it --rm myproject:dev bash
# Then run the failing command
```

## Check resource usage

```bash
# Container stats
docker stats mycontainer

# Disk usage
docker system df

# Check limits
docker inspect mycontainer | grep -A 10 "Memory"
```

## Getting Help

If you can't resolve your issue:

1. **Check existing issues**: <https://github.com/joshjhall/containers/issues>
1. **Check documentation**: Browse other docs in `docs/` directory
1. **Enable verbose logging**: Set `set -x` in scripts for detailed output
1. **Run integration tests**: `./tests/run_integration_tests.sh` to verify your
   setup
1. **Check CI status**: View recent builds at
   <https://github.com/joshjhall/containers/actions>
1. **Create an issue**: Include:
   - OS and Docker version (`docker version`)
   - Debian version (if relevant): `cat /etc/debian_version`
   - Build command used
   - Full error output
   - Relevant logs from `/var/log/build-*.log`
   - Output from `./bin/check-versions.sh`

## Quick Diagnostic Commands

```bash
# Check system info
docker version
docker info
cat /etc/debian_version  # Inside container

# Check build system version
git -C containers log -1 --oneline

# Verify tool versions
./bin/check-versions.sh

# Run unit tests (no Docker required)
./tests/run_unit_tests.sh

# Run integration tests (requires Docker)
./tests/run_integration_tests.sh

# Check installed tools in running container
docker exec mycontainer /bin/check-installed-versions.sh
```
