# Better-CI Development Roadmap

## Overview

This roadmap outlines the development plan for Better-CI, an innovative CI/CD system that compiles pipeline definitions into debuggable executables.

## Phase 1: Core Compiler (IN PROGRESS)

### Status: Core functionality complete, refinements ongoing

The core compiler reads pipeline definitions and generates Zig code that compiles into standalone executables with full parallel execution support.

**Completed:**
- ✅ Project structure and build system
- ✅ Pipeline data model (steps, actions, dependencies)
- ✅ JSON parser for pipeline definitions with comprehensive validation
- ✅ Code generator for build.zig and step implementations
- ✅ Support for basic action types (shell, compile, test, checkout, artifact)
- ✅ **Parallel step execution based on dependency graph**
  - Topological sorting to determine execution levels
  - Thread-safe parallel execution with isolated allocators
  - Proper error propagation from threads
- ✅ **Better error handling and validation**
  - Type-safe writer abstractions (std.io.AnyWriter)
  - Comprehensive field validation with helpful error messages
  - Memory leak prevention with proper errdefer usage
  - Duplicate step ID detection
  - Invalid character validation for step IDs
  - Empty pipeline detection
- ✅ Example pipelines (hello-world, parallel execution demo)

**Remaining Work:**
- [ ] Advanced action types (docker, cache, notifications)
- [ ] Pipeline variables and parameter substitution
- [ ] Conditional step execution
- [ ] Step retry mechanisms
- [ ] Comprehensive testing suite
- [ ] CLI improvements (verbose mode, dry-run, validation command)
- [ ] More example pipelines
- [ ] Performance optimizations

### Technical Details

**Architecture:**
```
Pipeline Definition (JSON)
    ↓
Parser (parser.zig) - validates and builds dependency graph
    ↓
Pipeline Model (pipeline.zig)
    ↓
Dependency Analysis (graph.zig) - computes execution levels
    ↓
Code Generator (codegen.zig) - generates parallel execution code
    ↓
Generated Files:
  - build.zig (orchestration)
  - src/main.zig (pipeline entry point with parallel execution)
  - src/step_*.zig (individual step implementations)
    ↓
 zig build
    ↓
Standalone Pipeline Executable (with parallelism built-in)
```

**Key Benefits Achieved:**
- Explicit, visible pipeline logic
- Standard debugging with gdb/lldb
- Type-safe step definitions
- Incremental compilation via Zig's build system
- **Automatic parallelization** - steps without dependencies run concurrently
- **Comprehensive validation** - catch errors before execution
- **Fast execution** - compiled code with minimal overhead

---

## Phase 2: Pluggable Modules
Provide building blocks that will compose the steps reading from existing pipelines.

### Technical details

Every step in the build is represented by a single `Action`, and this action should be pluggable with pre-built common scenarios like starting a container, running a process, etc...

Pipelines might describe parallel Steps that can be executed independently.
Provide out-of-the-box modules that can be used to compose the build steps.

## Phase 3: Product Website

### Goal
Create a marketing and documentation website that explains Better-CI to potential users and provides comprehensive guides.

### Key Pages

1. **Landing Page**
   - Hero section explaining the core problem and solution
   - Side-by-side comparison: YAML vs Better-CI
   - Key benefits: Speed, Debuggability, Explicitness
   - Call-to-action: Get Started, View Examples

2. **Documentation**
   - Getting Started guide
   - Pipeline definition reference
   - Action types catalog
   - Advanced features (dependencies, parallelism, conditions)
   - Debugging guide (how to debug generated pipelines)
   - Migration guide from other CI systems

3. **Examples Gallery**
   - Simple build pipeline
   - Full CI/CD with testing, linting, deployment
   - Monorepo workflows
   - Docker-based pipelines
   - Multi-platform builds

4. **Architecture Deep Dive**
   - How it works under the hood
   - Code generation process
   - Performance characteristics
   - Security considerations

5. **Blog**
   - Announcement posts
   - Technical deep dives
   - Case studies
   - Best practices

### Technical Implementation

**Technology Stack (Suggested):**
- **Framework**: Astro or SvelteKit (static site generation)
- **Styling**: Tailwind CSS
- **Hosting**: GitHub Pages, Netlify, or Vercel
- **Code Highlighting**: Shiki or Prism
- **Analytics**: Plausible or similar privacy-focused tool

**Repository Structure:**
```
website/
├── src/
│   ├── pages/
│   │   ├── index.astro
│   │   ├── docs/
│   │   ├── examples/
│   │   └── blog/
│   ├── components/
│   ├── layouts/
│   └── styles/
├── public/
│   └── assets/
└── package.json
```

**Content Strategy:**
- Clear, concise writing
- Real-world examples
- Interactive code playgrounds
- Visual diagrams explaining concepts
- Video tutorials (optional)

**SEO & Marketing:**
- Optimize for keywords: "CI/CD", "debugging CI", "fast CI", "Zig CI"
- Open Graph tags for social sharing
- Submit to product directories (Product Hunt, Hacker News)
- Developer communities (Reddit r/programming, Lobsters, Zig forums)

---

## Phase 3: Platform Integrations

### Goal
Enable Better-CI pipelines to run on existing CI/CD platforms while maintaining all the benefits of compiled executables.

### Integration Architecture

Each integration is an adapter that:
1. Receives the compiled pipeline executable
2. Handles platform-specific concerns (auth, secrets, artifacts)
3. Executes the pipeline
4. Reports results back to the platform

**Common Integration Features:**
- Secret/credential injection
- Artifact upload/download
- Log streaming to platform UI
- Status reporting (success/failure/in-progress)
- Build metadata (commit SHA, author, timestamp)
- Cache management

### 3.1 GitHub Actions Integration

**Priority:** HIGH (most popular platform)

**Implementation Approach:**

1. **GitHub Action Definition** (`action.yml`):
```yaml
name: 'Better-CI'
description: 'Run Better-CI compiled pipelines in GitHub Actions'
inputs:
  pipeline-executable:
    description: 'Path to the compiled pipeline executable'
    required: true
  working-directory:
    description: 'Directory to run the pipeline in'
    required: false
    default: '.'
runs:
  using: 'composite'
  steps:
    - run: ${{ inputs.pipeline-executable }}
      shell: bash
      working-directory: ${{ inputs.working-directory }}
```

2. **Wrapper Script** (optional):
   - Inject GitHub Actions environment variables
   - Handle GITHUB_TOKEN for API access
   - Upload artifacts using Actions API
   - Set outputs and annotations

3. **Example Usage**:
```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Generate and compile the pipeline
      - name: Setup Better-CI
        run: |
          better-ci generate pipeline.json ./ci-build
          cd ci-build && zig build

      # Run the pipeline
      - name: Run Pipeline
        run: ./ci-build/zig-out/bin/my-pipeline
```

**Repository Structure:**
```
integrations/github-actions/
├── action.yml
├── README.md
├── examples/
│   └── basic-workflow.yml
└── scripts/
    └── wrapper.sh
```

### 3.2 BuildKite Integration

**Priority:** MEDIUM

**Implementation Approach:**

1. **BuildKite Plugin** (`plugin.yml`):
```yaml
name: Better-CI
description: Run Better-CI pipelines on BuildKite
author: better-ci
requirements: []
configuration:
  properties:
    pipeline-definition:
      type: string
    output-dir:
      type: string
  required:
    - pipeline-definition
```

2. **Hook Scripts**:
   - `hooks/command`: Generate and run pipeline
   - `hooks/pre-exit`: Cleanup
   - Environment variable mapping

3. **Example Usage**:
```yaml
# .buildkite/pipeline.yml
steps:
  - label: "Build & Test"
    plugins:
      - better-ci/better-ci#v1:
          pipeline-definition: pipeline.json
```

**Repository Structure:**
```
integrations/buildkite/
├── plugin.yml
├── hooks/
│   ├── command
│   └── pre-exit
├── README.md
└── tests/
```

### 3.3 TeamCity Integration

**Priority:** MEDIUM

**Implementation Approach:**

1. **Custom Runner**:
   - TeamCity build step that executes Better-CI pipelines
   - Parses Better-CI output for test results
   - Integrates with TeamCity artifact system

2. **Plugin Development** (optional):
   - TeamCity plugin for native integration
   - UI for configuring Better-CI pipelines
   - Build feature for automatic pipeline generation

**Repository Structure:**
```
integrations/teamcity/
├── runner/
│   ├── better-ci-runner.jar
│   └── teamcity-plugin.xml
├── docs/
└── examples/
```

### 3.4 GitLab CI Integration

**Priority:** MEDIUM-HIGH

**Implementation Approach:**

1. **GitLab CI Template**:
```yaml
# .gitlab-ci.yml
include:
  - remote: 'https://better-ci.dev/integrations/gitlab/template.yml'

better-ci:
  extends: .better-ci-template
  variables:
    PIPELINE_DEF: pipeline.json
```

2. **Container Image**:
   - Docker image with Better-CI and Zig pre-installed
   - Optimized for GitLab CI runners

**Repository Structure:**
```
integrations/gitlab/
├── template.yml
├── Dockerfile
├── README.md
└── examples/
```

### 3.5 Jenkins Integration

**Priority:** LOW-MEDIUM

**Implementation Approach:**

1. **Jenkins Plugin**:
   - Pipeline step for Better-CI
   - Integration with Jenkins credentials
   - Artifact publishing

2. **Jenkinsfile Example**:
```groovy
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                betterCI pipelineDef: 'pipeline.json'
            }
        }
    }
}
```

**Repository Structure:**
```
integrations/jenkins/
├── src/
│   └── main/java/io/betterci/jenkins/
├── pom.xml
├── README.md
└── docs/
```

### 3.6 Generic Integration (Shell-based)

**Priority:** HIGH (works anywhere)

**Implementation:**

A universal shell wrapper that can run on any CI platform:

```bash
#!/bin/bash
# better-ci-wrapper.sh

set -e

PIPELINE_DEF=${1:-pipeline.json}
OUTPUT_DIR=${2:-generated-pipeline}

# Generate pipeline
better-ci generate "$PIPELINE_DEF" "$OUTPUT_DIR"

# Build pipeline executable
cd "$OUTPUT_DIR"
zig build

# Run pipeline
./zig-out/bin/*
```

Usage on any platform:
```bash
./better-ci-wrapper.sh pipeline.json
```

---

## Phase 4: Advanced Features (Future)

### 4.1 Distributed Execution
- Run steps across multiple machines
- Agent-based architecture
- Work queue management

### 4.2 Cloud-Native Features
- Kubernetes operator
- Container-based step execution
- Auto-scaling

### 4.3 Monitoring & Observability
- OpenTelemetry integration
- Metrics collection
- Performance profiling
- Build analytics

### 4.4 IDE Integration
- VS Code extension for pipeline authoring
- Syntax highlighting and validation
- Pipeline visualization
- Debugging support

### 4.5 Ecosystem
- Plugin system for custom actions
- Community-contributed action library
- Pipeline templates marketplace

---

## Success Metrics

### Phase 1 (Core)
- [x] Successfully generate and run example pipelines (2 working examples)
- [x] Performance: Generate pipeline in < 1 second
- [x] Performance: Compiled pipeline startup < 100ms
- [x] Parallel execution working correctly
- [x] Comprehensive error messages for invalid pipelines
- [ ] 10+ diverse example pipelines
- [ ] Zero security vulnerabilities in generated code (needs security audit)
- [ ] 80%+ test coverage (parser tests complete, need more integration tests)

### Phase 2 (Website)
- [ ] Documentation covers all features
- [ ] 5+ complete example pipelines
- [ ] Clear migration guide from at least 2 major CI platforms
- [ ] Analytics showing user engagement

### Phase 3 (Integrations)
- [ ] Working integration with GitHub Actions
- [ ] Working integration with at least 2 other platforms
- [ ] Example workflows for each integration
- [ ] Integration tests for each platform

---

## Timeline (Tentative)

- **Phase 1 (Core)**: 2-3 months
- **Phase 2 (Website)**: 1 month (can overlap with Phase 1)
- **Phase 3 (Integrations)**: 2-3 months (staggered releases)
- **Phase 4 (Advanced)**: Ongoing

---

## Contributing

Once the project is ready for contributions, we welcome:
- Bug reports and fixes
- New action types
- Integration with additional platforms
- Documentation improvements
- Example pipelines
- Performance optimizations

---

## Questions & Decisions Needed

1. **Pipeline Definition Format**: Stick with JSON or add YAML/TOML support?
2. **Versioning Strategy**: How to handle breaking changes in pipeline definitions?
3. **License**: MIT, Apache 2.0, or other?
4. **Name**: Is "Better-CI" the final name or placeholder?
5. **Hosting**: Where to host the compiler binary releases?
6. **Commercial Strategy**: Open source core + paid features, or fully open?
