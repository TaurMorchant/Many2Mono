# Many2Mono

Tool for merging multiple Maven repositories into a single monorepo while preserving git history.

## What it does

- Clones multiple git repositories
- Moves each repository into its own subdirectory
- Merges all histories into a single monorepo
- Generates a root `pom.xml` aggregator
- Configures SCM, distribution management, and other Maven settings
- Copies license files and GitHub workflows

## Requirements

- **bash** (run in WSL or Linux)
- **git**
- **git-filter-repo** (`pip install git-filter-repo`)
- **xmlstarlet** (`apt install xmlstarlet`) - only for experimental BOM features

## Quick Start

### 1. Configure

Copy the template and fill in your values:

```bash
cp config.env.template config.env
```

Edit `config.env`:

```bash
# Required
MONOREPO_GROUP_ID=com.mycompany.platform
MONOREPO_ARTIFACT_ID=my-platform
GITHUB_ORG=MyCompany
GITHUB_REPO=my-platform-monorepo

# Optional (defaults shown)
#MONOREPO_VERSION=1.0.0-SNAPSHOT
#JAVA_VERSION=17
#LOMBOK_VERSION=1.18.42
```

### 2. Define repositories

Edit `repos.txt` with one repository per line:

```
https://github.com/org/repo-one|module-one
https://github.com/org/repo-two|module-two
# comments are ignored
```

Format: `URL|subdirectory`

### 3. Run

```bash
# On Windows, run in WSL:
dos2unix Makefile repos.txt config.env

# Build the monorepo
make all
```

The monorepo will be created in `./monorepo/`.

## Available Commands

| Command | Description |
|---------|-------------|
| `make all` | Full pipeline: clone, merge, configure |
| `make clone` | Clone repositories to `tmp/` |
| `make merge` | Merge cloned repos into monorepo |
| `make aggregator` | Generate root `pom.xml` |
| `make add-licence` | Copy license files, remove from modules |
| `make add-gitignore` | Create `.gitignore` in monorepo |
| `make add-workflows` | Copy `.github/` directory |

## Output Structure

```
monorepo/
├── pom.xml              # Root aggregator
├── .gitignore
├── .github/             # GitHub Actions, CODEOWNERS
├── LICENSE
├── CONTRIBUTING.md
├── CODE-OF-CONDUCT.md
├── SECURITY.md
├── module-one/          # First repository
│   └── pom.xml
└── module-two/          # Second repository
    └── pom.xml
```

## Documentation

See [CLAUDE.md](CLAUDE.md) for detailed documentation.
