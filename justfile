default:
    @just --list

# Build this root's quotient forms and link them where quotient looks
# (.quotient/forms/<capability>). A rebuild that changes a form needs a fresh
# `quotient allow`.
quotient-forms:
    mkdir -p .quotient/forms
    nix build -o .quotient/result-read .#quotient-read
    nix build -o .quotient/result-write .#quotient-write
    ln -sfn "$(readlink -f .quotient/result-read)/bin/quotient-read" .quotient/forms/read
    ln -sfn "$(readlink -f .quotient/result-write)/bin/quotient-write" .quotient/forms/write
