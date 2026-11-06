default:
    @just --list

# Format the Gleam sources and tests
fmt:
    gleam format src test

# Export the erlang-shipment, then run the tests that spawn it
test:
    gleam export erlang-shipment
    gleam test

# Structural purity check (I5, I6): import allowlist, no @external, no stray method names
check-imports:
    gleam run -m check_imports

# Format check, warning-free build, then the tests
check:
    gleam format --check src test
    gleam build --warnings-as-errors
    just check-imports
    just test

# The verification gate `doctrine check gate` runs
gate: check
