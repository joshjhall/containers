# Pinned GPG keyrings

ASCII-armored public keyrings referenced by tier-1 `verification.gpg_keyring`
entries (see `docs/verification.md`). A signature must verify against a key in
the named file. Because these files are committed and change only through code
review, a compromised publisher origin cannot substitute its own key — unlike
`gpg_key_url`, which fetches the key from the publisher at install time.

Consumers resolve `gpg_keyring` relative to the catalog root, so the paths in
version files are `keyrings/<file>.asc` (subdirectories are allowed, but the
files here are flat).

## Files

| File         | Signs                                                   | Source                                                                                                         | sha256                                                             |
| ------------ | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `nodejs.asc` | `https://nodejs.org/dist/v{version}/SHASUMS256.txt.sig` | [nodejs/release-keys](https://github.com/nodejs/release-keys) @ `481637f8` (2026-09-01), fetched 2026-10-25; 29 keys, active and historical releasers | `d231adee960ea70d90cf6233f6606d44264743ae92498eacf26349bdb72cc4f9` |
| `golang.asc` | `https://dl.google.com/go/go{version}.linux-{arch}.tar.gz.asc` | Google Linux package signing key (`https://dl.google.com/linux/linux_signing_key.pub`, primary `EB4C 1BFD 4F04 2F6D DDCC EC91 7721 F63B D38B 4796`), byte-identical to the live key on 2026-10-27, as pinned by containers `lib/gpg-keys/golang/keys/google-linux-signing-key.asc` | `54dea5f6c2a26091578cf52a999cebc6b64df478d37ad4dce96376b711e3b27c` |

Both files are mirrored from the containers repository's pinned keys
(`lib/gpg-keys/`), so the catalog and the build scripts trust the same keys.

At the time of adding (2026-10-27), every cataloged node version's
`SHASUMS256.txt.sig` verified against `nodejs.asc`, and go 1.22.0 through
1.27.3 tarball signatures verified against `golang.asc` (both arches).

## Regenerating

Node's keys ship upstream as a GPG keybox, not an armored file. Export from a
**scratch copy**. Never point `GNUPGHOME` at a tracked directory, because gpg
rewrites `trustdb.gpg` and the keybox in place:

```bash
scratch=$(mktemp -d) && cp -r /path/to/containers/lib/gpg-keys/nodejs/keyring/. "$scratch" && chmod 700 "$scratch"
GNUPGHOME=$scratch gpg --batch --export --armor > keyrings/nodejs.asc
rm -rf "$scratch"
```

`golang.asc` is a byte copy of the containers repository's
`lib/gpg-keys/golang/keys/google-linux-signing-key.asc`.

Update the sha256 column and the provenance in the table above in the same
change.

## Checking a signature by hand

```bash
home=$(mktemp -d) && chmod 700 "$home"
GNUPGHOME=$home gpg --batch --import keyrings/nodejs.asc
GNUPGHOME=$home gpg --batch --verify SHASUMS256.txt.sig SHASUMS256.txt
rm -rf "$home"
```
