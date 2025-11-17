# Stringr

> A faster, debuggable CI/CD system that compiles pipeline definitions into standalone executables.

## The Problem

Traditional CI/CD systems suffer from three major pain points:

1. **Complexity** - YAML configs with obscure environment variables and hidden magic
2. **Debugging Difficulty** - CI pipelines are nearly impossible to debug locally
3. **Performance** - Current CI systems are slow with significant overhead

## The Solution

Stringr uses **Zig** to compile your CI pipeline definitions into **debuggable, standalone executables**. Instead of YAML that runs in a black box, you get:

- ✅ **Compiled executables** you can run locally
- ✅ **Standard debugging** with gdb, lldb, or any debugger
- ✅ **Fast execution** with automatic parallelization
- ✅ **Explicit dependencies** - no hidden behavior
- ✅ **Type safety** - catch errors before execution

## Quick Example

**1. Define your pipeline** (`pipeline.json`):

```json
{
  "name": "my-ci-pipeline",
  "description": "Build and test",
  "steps": [
    {
      "id": "build",
      "name": "Build Project",
      "action": {
        "type": "shell",
        "command": "zig build"
      }
    },
    {
      "id": "test",
      "name": "Run Tests",
      "depends_on": ["build"],
      "action": {
        "type": "test",
        "test_file": "src/main.zig"
      }
    }
  ]
}
```

**2. Generate the pipeline executable**:

```bash
stringr generate --in pipeline.json
cd generated && zig build
```

**3. Run it**:

```bash
./zig-out/bin/my-ci-pipeline
```

That's it! You now have a standalone executable that runs your CI pipeline with automatic parallelization.

## Key Features

### 🚀 Automatic Parallelization

Steps without dependencies run in parallel automatically - no configuration needed.

### 🌍 Environment Variables

Load global environment variables from files:

```bash
stringr generate --in pipeline.json --env-file .env
```

Step-specific variables can override global ones:

```json
{
  "id": "deploy",
  "name": "Deploy to Production",
  "env": {
    "ENVIRONMENT": "production"
  },
  "action": { ... }
}
```

### 🧪 Local Debugging

Since pipelines are executables, you can debug them like any other program:

```bash
gdb ./zig-out/bin/my-pipeline
```

### 📊 Thread-Safe Logging

Each step writes to its own log file, preventing output corruption in parallel execution. Logs are automatically displayed after each step completes.

### ✅ Comprehensive Validation

- Catches errors before execution
- Detects circular dependencies
- Validates all required fields
- Clear, helpful error messages

## Installation

### Prerequisites

- Zig 0.15.2 or later

### Build from Source

```bash
git clone https://github.com/inge4pres/stringr.git
cd stringr/core
zig build
./zig-out/bin/stringr --help
```

## Supported Actions

- **shell** - Execute shell commands
- **compile** - Compile Zig executables
- **test** - Run Zig tests
- **checkout** - Clone git repositories
- **artifact** - Copy build artifacts
- **custom** - Extensible for future action types

See [CLAUDE.md](CLAUDE.md) for detailed action documentation.

## Documentation

- **[CLAUDE.md](CLAUDE.md)** - Comprehensive architecture and development guide
- **[ROADMAP.md](ROADMAP.md)** - Development roadmap and future plans
- **[core/examples/](core/examples/)** - Example pipeline definitions

## Project Status

**Current Phase**: Core Compiler (Active Development)

✅ **Completed Features:**
- JSON parser with validation
- Parallel execution based on dependency graphs
- File-based logging for thread safety
- Environment variable management
- Comprehensive error handling
- Example pipelines

🚧 **In Progress:**
- Additional action types
- Platform integrations (GitHub Actions, BuildKite, etc.)
- Product website and documentation

See [ROADMAP.md](ROADMAP.md) for detailed status and timeline.

## Examples

Check out the [examples directory](core/examples/) for:

- **hello-world.json** - Simple sequential pipeline
- **simple-pipeline.json** - Standard CI workflow
- **parallel-pipeline.json** - Parallel execution demo
- **env-test-pipeline.json** - Environment variables demo

Generate all examples:

```bash
cd core
zig build examples
```

## Contributing

Contributions are welcome! Areas where you can help:

- New action types
- Platform integrations
- Documentation improvements
- Example pipelines
- Bug reports and fixes

## Architecture

```
Pipeline Definition (JSON)
    ↓
Parser (validates and builds dependency graph)
    ↓
Pipeline Model
    ↓
Dependency Analysis (computes execution levels)
    ↓
Code Generator (generates parallel execution code)
    ↓
Generated Files:
  - build.zig
  - src/main.zig (with parallelism)
  - src/step_*.zig (individual steps)
    ↓
zig build
    ↓
Standalone Pipeline Executable
```

## Why Zig?

- **Fast compilation** - Quick iteration cycles
- **No hidden control flow** - Explicit error handling
- **Cross-compilation** - Build for any target
- **Minimal runtime** - Small, fast executables
- **Memory safety** - Without garbage collection overhead

## License

[TBD - To be determined]

## Links

- **Repository**: https://github.com/inge4pres/stringr
- **Issues**: https://github.com/inge4pres/stringr/issues

---

*Stringr: Because your CI/CD shouldn't be a black box.*
