# Stringr Examples

This directory contains example pipeline definitions and their generated executables.

## Directory Structure

```
examples/
├── README.md                      # This file
├── *.json                         # Pipeline definition files
└── _generated/                    # Auto-generated pipeline executables (gitignored)
    ├── hello-world/
    ├── simple-pipeline/
    └── parallel-pipeline/
```

## Building Examples

To generate all example pipelines:

```bash
zig build examples
```

This will:
1. Build the `stringr` compiler
2. Generate pipeline executables for all `.json` definitions
3. Place them in `examples/_generated/`

## Running Examples

After generating, you can build and run any example:

```bash
# Build an example
cd examples/_generated/parallel-pipeline
zig build

# Run the pipeline
./zig-out/bin/parallel-test-pipeline
```

## Example Definitions

### hello-world.json
A minimal pipeline demonstrating basic step execution.

### simple-pipeline.json
A sequential CI pipeline with checkout, build, test, and artifact steps.

### parallel-pipeline.json
Demonstrates parallel execution with multiple steps running concurrently.

## Adding New Examples

1. Create a new `.json` file in this directory
2. Run `zig build examples` to generate it

## Notes

- Generated files in `_generated/` are not committed to git
- Each generated pipeline is a standalone executable
- You can debug generated pipelines with standard tools (gdb, lldb)
