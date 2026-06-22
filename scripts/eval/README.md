# Eval/Research Tooling (NOT in runtime)

The following Python modules are research/eval/training tooling that was
CUT from the Hermes rewrite runtime per 07-rewrite-execution-spec.md.

They live in the original Python source (../hermes-agent/) and are NOT
ported to the Elixir/Rust rewrite. If needed, relocate to a separate
repo or scripts/eval/ directory.

## Excluded modules
- `batch_runner.py` — batch agent evaluation runner
- `mini_swe_runner.py` — SWE-bench mini runner
- `trajectory_compressor.py` — trajectory compression for training data
- `toolset_distributions.py` — tool distribution analysis
- `datagen-config-examples/` — data generation config examples

## Rationale
These are eval/training tools, not runtime dependencies. They are not
referenced by the core loop, gateway, or CLI. Keeping them out of the
runtime reduces binary size and attack surface.

See DECISIONS.md #research-tooling for the original audit decision.
