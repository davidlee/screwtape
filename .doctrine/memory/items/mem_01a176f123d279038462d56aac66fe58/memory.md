To prove an FFI module only calls an allowlist (SL-001 PHASE-03 check-imports, DEC-020), read the compiled module's imports: `beam_lib:chunks(Path, [imports])` → `[{Mod, Fun, Arity}]`.

- A text scan for `mod:fun(` is evaded by `'file':'read_file'(X)`, `fun file:read_file/1`, `apply(file, read_file, [X])`; all three appear in the import table (literal-atom apply folds to a direct import).
- Every module imports `erlang:get_module_info/1,2` (compiler-generated) — allow those.
- Residual: a call through a runtime-variable module (`M:F(A)`) compiles to the `apply` opcode with no import entry. Accept with review, or also check the atom table.
- `gleam run -m <test module>` compiles the project first, so `build/dev/erlang/<app>/ebin/<mod>.beam` exists when its `main` runs; it works for modules under `test/`.
