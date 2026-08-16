# Board build drivers

Each supported target will expose one executable driver:

```text
boards/<target>/build.sh --toolchain vendor|oss --profile <profile> --output <directory>
```

The top-level `make synth` command validates the target/profile matrix, checks the
selected toolchain, creates an isolated output directory, and calls that driver.
The `console138k` driver implements the first reproducible bring-up project. It
builds the release smoke-test image with the vendor toolchain for the
GW5AST-LV138PG484AC1/I0, device version C. Other targets, profiles, and the
open-source flow remain unimplemented and fail closed.

A driver must:

- select and document the exact FPGA device, package, speed grade, and silicon
  revision;
- accept only the toolchains and profiles that have an implemented flow;
- read source and checked-in constraints from the repository;
- write generated files only beneath the provided absolute output directory;
- require an empty target-specific output directory before invoking a tool;
- invoke tools non-interactively and propagate a nonzero exit status;
- reject tool error records even when the tool exits zero;
- require reports and the bitstream to have been created by the current run;
- fail when a timing constraint required by the selected profile is violated;
- retain synthesis, placement, timing, and utilization reports in the output; and
- never silently substitute another board, device revision, or build profile.

Target names currently reserved by the project are `nano20k`, `console60k`, and
`console138k`. Their planned roles and profiles are recorded in the
[hardware targets](../README.md#hardware-targets) section.
