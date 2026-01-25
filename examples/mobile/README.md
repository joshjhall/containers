# Mobile Development Container Examples

This directory contains Docker Compose examples for Android and Kotlin mobile development.

## Architecture Requirements

### The Problem

Android SDK platform-tools (`adb`, `fastboot`) and the Android Emulator are distributed as **x86_64 binaries only**. They do not have native arm64 versions. This means:

- On **Apple Silicon Macs** (M1/M2/M3/M4): Native arm64 containers cannot run adb or emulator
- On **AWS Graviton** or other arm64 servers: Same limitation applies
- On **x86_64 hosts** (Intel Macs, most cloud VMs): Everything works natively

### Error Messages on arm64

If you try to run Android tools in an arm64 container, you'll see errors like:

```text
rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2
```

Or adb/emulator commands will exit with code 133.

### The Solution

**Run x86_64 containers via emulation.** Modern arm64 hosts support this:

- **Apple Silicon**: Rosetta 2 provides excellent x86_64 emulation
- **Linux arm64**: QEMU user-mode emulation (install `qemu-user-static`)
- **Docker Desktop**: Automatically handles emulation

## Quick Start

```bash
# Build and start the Android development container
# (automatically uses x86_64 via emulation on arm64 hosts)
docker compose -f docker-compose.android-dev.yml up -d

# Enter the container
docker compose -f docker-compose.android-dev.yml exec android-dev bash

# Verify everything works
adb version              # Should show "Android Debug Bridge version X.Y.Z"
kotlinc -version         # Should show "Kotlin compiler version 2.3.0"
sdkmanager --list_installed  # Shows installed SDK packages
```

## What Works Where

| Tool                      | arm64 Native | x86_64 Native | x86_64 via Emulation |
| ------------------------- | ------------ | ------------- | -------------------- |
| Kotlin compiler (kotlinc) | Yes          | Yes           | Yes                  |
| Gradle builds             | Yes          | Yes           | Yes                  |
| sdkmanager                | Yes          | Yes           | Yes                  |
| aapt, aapt2, apksigner    | Yes          | Yes           | Yes                  |
| NDK (ndk-build, cmake)    | Yes          | Yes           | Yes                  |
| **adb**                   | No           | Yes           | Yes                  |
| **fastboot**              | No           | Yes           | Yes                  |
| **Android Emulator**      | No           | Yes           | Yes                  |

## Performance Considerations

Running x86_64 containers via emulation on arm64 hosts has some performance impact:

| Operation          | Native | Emulated     | Notes                     |
| ------------------ | ------ | ------------ | ------------------------- |
| Container build    | ~5 min | ~12 min      | One-time cost, cached     |
| Kotlin compilation | Fast   | ~1.5x slower | Still very usable         |
| Gradle builds      | Fast   | ~1.5x slower | Cache helps significantly |
| adb commands       | N/A    | Fast         | Low overhead commands     |
| Emulator           | N/A    | Usable       | Slower than native KVM    |

**Recommendation**: For the best experience on arm64 hosts, use the emulated x86_64 container. The performance is acceptable for development, and all tools work correctly.

## Alternative: Remote Development

If emulation performance is insufficient, run the container on a remote x86_64 host:

```bash
# On remote x86_64 server
docker run -d --name android-dev \
  -v android-cache:/cache \
  -p 5037:5037 \
  myproject:android-dev sleep infinity

# Connect via VS Code Remote - Containers extension
# Or forward ADB port:
ssh -L 5037:localhost:5037 user@remote-host
```

## Files in This Directory

- `docker-compose.android-dev.yml` - Full Android + Kotlin development setup
