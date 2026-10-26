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

# Format the Gleam sources and tests
fmt:
    gleam format src test

# Export the erlang-shipment, then run the tests that spawn it
test:
    gleam export erlang-shipment
    gleam test

# Format check, warning-free build, then the tests
check:
    gleam format --check src test
    gleam build --warnings-as-errors
    just test

# The verification gate `doctrine check gate` runs
gate: check
