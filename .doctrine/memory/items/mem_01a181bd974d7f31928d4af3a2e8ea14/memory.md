Observed 2026-10-28 (SL-004 research, finding A), systemd user manager on the dev host.

`printf 'a\nb\n' | systemd-run --user --pipe --quiet --wait -p LoadCredential=jev:<file> sh -c 'cat; echo $CREDENTIALS_DIRECTORY'`
- streams stdin to the unit and its stdout back;
- sets `CREDENTIALS_DIRECTORY=/run/user/<uid>/credentials/run-….service` with `jev` inside;
- returns the unit's exit code (3 → 3).

Use: give a pipe verb DEC-001/DEC-016 custody (`LoadCredentialEncrypted=`) with no code change to the credential reader (DEC-038). Add `--collect` so a failed transient unit is removed. Only `LoadCredential=` (plaintext) was exercised; `LoadCredentialEncrypted=` takes the same path in the screwtape unit.
