SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

ROOT := $(abspath .)
REPOS_FILE := $(ROOT)/repos.txt
TEMPLATES_DIR := $(ROOT)/templates
CONFIG_FILE := $(ROOT)/config.env

# =============================================================================
# Load configuration from config.env if it exists
# =============================================================================
-include $(CONFIG_FILE)

# =============================================================================
# Configuration with defaults
# =============================================================================

# Required properties (must be set in config.env)
MONOREPO_GROUP_ID ?=
MONOREPO_ARTIFACT_ID ?=
GITHUB_ORG ?=
GITHUB_REPO ?=

# Optional properties with defaults
MONOREPO_DIR_NAME ?= monorepo
MONOREPO_VERSION ?= 1.0.0-SNAPSHOT
JAVA_VERSION ?= 17
LOMBOK_VERSION ?= 1.18.42
BRANCHES ?= main

# Derived paths
TMP_DIR := $(ROOT)/tmp
MONOREPO_DIR := $(ROOT)/$(MONOREPO_DIR_NAME)

# Derived URLs (computed from GITHUB_ORG and GITHUB_REPO)
GITHUB_URL = https://github.com/$(GITHUB_ORG)/$(GITHUB_REPO)
GITHUB_SCM_URL = scm:git:$(GITHUB_URL).git
GITHUB_PACKAGES_URL = https://maven.pkg.github.com/$(GITHUB_ORG)/$(GITHUB_REPO)

.PHONY: all clone merge aggregator rewrite-scm add-lombok-processor add-licence add-gitignore add-workflows check-init check-config
.PHONY: parent bom module-bom root-bom bom-clean check-bom

all: check-config clone merge aggregator add-lombok-processor add-licence add-gitignore add-workflows

# =============================================================================
# CHECK-CONFIG: Validate required configuration
# =============================================================================

check-config:
	@missing=""
	@[[ -z "$(MONOREPO_GROUP_ID)" ]] && missing="$$missing MONOREPO_GROUP_ID"
	@[[ -z "$(MONOREPO_ARTIFACT_ID)" ]] && missing="$$missing MONOREPO_ARTIFACT_ID"
	@[[ -z "$(GITHUB_ORG)" ]] && missing="$$missing GITHUB_ORG"
	@[[ -z "$(GITHUB_REPO)" ]] && missing="$$missing GITHUB_REPO"
	@if [[ -n "$$missing" ]]; then
	  echo "[ERROR] Missing required configuration:$$missing"
	  echo ""
	  echo "Please copy config.env.template to config.env and fill in the required values:"
	  echo "  cp config.env.template config.env"
	  echo "  # Edit config.env with your values"
	  exit 1
	fi
	@echo "[OK] Configuration validated"

# BOM: Generate all BOMs (module-level and root)
bom: module-bom root-bom

# =============================================================================
# CLONE: Clone repos and apply filter-repo to move them to subdirectories
# =============================================================================

check-init:
	@command -v git >/dev/null 2>&1 || { echo "[ERROR] git is required"; exit 1; }
	@command -v git-filter-repo >/dev/null 2>&1 || { echo "[ERROR] git-filter-repo is required"; exit 1; }
	@[[ -f "$(REPOS_FILE)" ]] || { echo "[ERROR] $(REPOS_FILE) not found"; exit 1; }

clone: check-init
	@echo "==> Cloning repos and moving to subdirectories"
	mkdir -p "$(TMP_DIR)"

	while IFS='|' read -r url subdir || [[ -n "$$url" ]]; do
	  [[ -z "$$url" || "$$url" == \#* ]] && continue
	  repo="$$(basename "$$url" .git)"

	  for branch in $(BRANCHES); do
	    # Replace slashes in branch name for filesystem compatibility
	    branch_safe="$$(echo "$$branch" | tr '/' '-')"
	    bare="$(TMP_DIR)/$${repo}-$${branch_safe}.git"

	    echo "---- Cloning $$repo ($$branch) -> $$subdir"

	    rm -rf "$$bare"

	    # Check if branch exists in remote repo
	    if ! git ls-remote --heads "$$url" "$$branch" | grep -q "$$branch"; then
	      echo "[ERROR] Branch $$branch not found in $$repo" >&2
	      echo "Please ensure all repositories have the required branches: $(BRANCHES)" >&2
	      exit 1
	    fi

	    git clone --bare --branch "$$branch" --single-branch "$$url" "$$bare"

	    (
	      cd "$$bare"
	      git filter-repo \
	        --refs "refs/heads/$$branch" \
	        --to-subdirectory-filter "$$subdir" \
	        --force
	    )
	  done
	done < "$(REPOS_FILE)"

	@echo ""
	@echo "DONE. Repos cloned and prepared in $(TMP_DIR)"

# =============================================================================
# MERGE: Create monorepo from already cloned repos
# =============================================================================

merge: check-init
	@echo "==> Creating monorepo from cloned repos"

	if [[ ! -d "$(TMP_DIR)" || -z "$$(ls -A $(TMP_DIR) 2>/dev/null)" ]]; then
	  echo "[ERROR] No cloned repos found in $(TMP_DIR). Run 'make clone' first."
	  exit 1
	fi

	# Process each branch
	first_branch=true
	for branch in $(BRANCHES); do
	  echo ""
	  echo "==> Processing branch: $$branch"

	  if [ "$$first_branch" = true ]; then
	    # For first branch (usually main), create fresh monorepo
	    rm -rf "$(MONOREPO_DIR)"
	    git init -b "$$branch" "$(MONOREPO_DIR)"
	    first_branch=false
	  else
	    # For subsequent branches, create orphan branch
	    (
	      cd "$(MONOREPO_DIR)"
	      git checkout --orphan "$$branch"
	      git rm -rf . 2>/dev/null || true
	    )
	  fi

	  (
	    cd "$(MONOREPO_DIR)"
	    git commit --allow-empty -m "Initial monorepo commit ($$branch)"

	    echo "==> Merging rewritten histories for $$branch"

	    while IFS='|' read -r url subdir || [[ -n "$$url" ]]; do
	      [[ -z "$$url" || "$$url" == \#* ]] && continue
	      repo="$$(basename "$$url" .git)"
	      branch_safe="$$(echo "$$branch" | tr '/' '-')"
	      bare="$(TMP_DIR)/$${repo}-$${branch_safe}.git"

	      if [[ ! -d "$$bare" ]]; then
	        echo "[WARN] Skipping $$repo ($$branch) - not found in $(TMP_DIR)" >&2
	        continue
	      fi

	      remote_name="$${subdir}-$${branch_safe}"
	      git remote remove "$$remote_name" 2>/dev/null || true
	      git remote add "$$remote_name" "$$bare"
	      git fetch "$$remote_name" "$$branch"
	      git merge "$${remote_name}/$$branch" \
	        --allow-unrelated-histories \
	        -m "chore(monorepo): merge $$repo ($$branch) into /$$subdir"
	    done < "$(REPOS_FILE)"
	  )
	done

	@echo ""
	@echo "DONE. Monorepo is ready at $(MONOREPO_DIR)"
	@echo "Branches created: $(BRANCHES)"

# =============================================================================
# AGGREGATOR: Create root aggregator pom.xml
# =============================================================================

aggregator:
	@echo "==> Creating root aggregator pom.xml"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR). Run 'make merge' first."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/aggregator-pom.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	root_pom="$(MONOREPO_DIR)/pom.xml"

	# Check if pom.xml already exists
	if [[ -f "$$root_pom" ]]; then
	  echo "[WARN] $$root_pom already exists, skipping creation"
	  exit 0
	fi

	xml_escape() {
	  local s="$${1:-}"
	  s="$${s//&/&amp;}"
	  s="$${s//</&lt;}"
	  s="$${s//>/&gt;}"
	  s="$${s//\"/&quot;}"
	  s="$${s//\'/&apos;}"
	  printf '%s' "$$s"
	}

	# Escape Makefile variables for XML
	GROUP_ID="$$(xml_escape "$(MONOREPO_GROUP_ID)")"
	ARTIFACT_ID="$$(xml_escape "$(MONOREPO_ARTIFACT_ID)")"
	VERSION="$$(xml_escape "$(MONOREPO_VERSION)")"
	GH_URL="$$(xml_escape "$(GITHUB_URL)")"
	GH_SCM_URL="$$(xml_escape "$(GITHUB_SCM_URL)")"
	GH_PACKAGES_URL="$$(xml_escape "$(GITHUB_PACKAGES_URL)")"

	# Build modules section
	TMPDIR="$$(mktemp -d)"
	trap 'rm -rf "$$TMPDIR"' EXIT
	modules_file="$$TMPDIR/modules.txt"

	while IFS='|' read -r url subdir || [[ -n "$$url" ]]; do
	  [[ -z "$$url" || "$$url" == \#* ]] && continue
	  echo "        <module>$$(xml_escape "$$subdir")</module>" >> "$$modules_file"
	done < "$(REPOS_FILE)"

	# Replace placeholders using sed
	# For @MODULES@ we use 'r' command to read file content
	sed -e "s|@MONOREPO_GROUP_ID@|$$GROUP_ID|g" \
	    -e "s|@MONOREPO_ARTIFACT_ID@|$$ARTIFACT_ID|g" \
	    -e "s|@MONOREPO_VERSION@|$$VERSION|g" \
	    -e "s|@GITHUB_URL@|$$GH_URL|g" \
	    -e "s|@GITHUB_SCM_URL@|$$GH_SCM_URL|g" \
	    -e "s|@GITHUB_PACKAGES_URL@|$$GH_PACKAGES_URL|g" \
	    -e "/@MODULES@/ {" -e "r $$modules_file" -e "d" -e "}" \
	    "$$template" > "$$root_pom"

	echo "[INFO] Created $$root_pom with modules from $(REPOS_FILE)"
	@echo ""
	@echo "[INFO] Aggregator pom.xml created successfully"

# =============================================================================
# REWRITE-SCM: Replace SCM sections in all pom.xml files
# =============================================================================

rewrite-scm:
	@echo "==> Rewriting SCM sections in all pom.xml files"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/scm.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	# Read SCM template content and replace placeholders
	scm_content="$$(cat "$$template")"
	scm_content="$${scm_content//@GITHUB_SCM_URL@/$(GITHUB_SCM_URL)}"
	scm_content="$${scm_content//@GITHUB_URL@/$(GITHUB_URL)}"

	# Process all pom.xml files
	while IFS= read -r -d '' pom_file; do
	  # Check if pom.xml contains <scm> section
	  if grep -q '<scm>' "$$pom_file"; then
	    echo "[INFO] Rewriting SCM in $$pom_file"

	    # Create temp file
	    TMPDIR="$$(mktemp -d)"
	    trap 'rm -rf "$$TMPDIR"' EXIT
	    tmp_file="$$TMPDIR/pom.xml"

	    # Use awk to replace SCM section (handles multiline)
	    awk -v scm="$$scm_content" '
	      /<scm>/ { in_scm=1; print scm; next }
	      /<\/scm>/ { in_scm=0; next }
	      !in_scm { print }
	    ' "$$pom_file" > "$$tmp_file"

	    mv "$$tmp_file" "$$pom_file"
	  fi
	done < <(find "$(MONOREPO_DIR)" -name "pom.xml" -print0)

	@echo ""
	@echo "[INFO] SCM rewrite completed"

# =============================================================================
# ADD-LOMBOK-PROCESSOR: Add lombok to maven-compiler-plugin annotationProcessorPaths
# =============================================================================

add-lombok-processor:
	@echo "==> Adding lombok to maven-compiler-plugin annotationProcessorPaths"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/lombok-annotation-processor.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	lombok_path="$$(cat "$$template")"
	lombok_path="$${lombok_path//@LOMBOK_VERSION@/$(LOMBOK_VERSION)}"

	# Process all pom.xml files
	while IFS= read -r -d '' pom_file; do
	  # Check if pom.xml contains maven-compiler-plugin
	  if ! grep -q 'maven-compiler-plugin' "$$pom_file"; then
	    continue
	  fi

	  # Skip if lombok already configured
	  if grep -q 'org.projectlombok' "$$pom_file" && grep -q 'annotationProcessorPaths' "$$pom_file"; then
	    echo "[INFO] Lombok already configured in $$pom_file"
	    continue
	  fi

	  echo "[INFO] Processing $$pom_file"

	  TMPDIR="$$(mktemp -d)"
	  trap 'rm -rf "$$TMPDIR"' EXIT
	  tmp_file="$$TMPDIR/pom.xml"

	  # Use awk to handle all cases:
	  # 1. annotationProcessorPaths exists - add lombok path inside it
	  # 2. configuration exists but no annotationProcessorPaths - add annotationProcessorPaths
	  # 3. plugin exists but no configuration - add configuration with annotationProcessorPaths
	  awk -v lombok="$$lombok_path" '
	    BEGIN {
	      in_compiler_plugin = 0
	      in_configuration = 0
	      in_annotation_paths = 0
	      has_configuration = 0
	      has_annotation_paths = 0
	      plugin_indent = ""
	      config_indent = ""
	      paths_indent = ""
	    }

	    # Detect maven-compiler-plugin
	    /maven-compiler-plugin/ {
	      in_compiler_plugin = 1
	      # Get indentation of plugin line
	      match($$0, /^[[:space:]]*/)
	      plugin_indent = substr($$0, RSTART, RLENGTH)
	    }

	    # Track configuration inside compiler plugin
	    in_compiler_plugin && /<configuration>/ {
	      in_configuration = 1
	      has_configuration = 1
	      match($$0, /^[[:space:]]*/)
	      config_indent = substr($$0, RSTART, RLENGTH)
	    }

	    # Track annotationProcessorPaths
	    in_compiler_plugin && in_configuration && /<annotationProcessorPaths>/ {
	      in_annotation_paths = 1
	      has_annotation_paths = 1
	      match($$0, /^[[:space:]]*/)
	      paths_indent = substr($$0, RSTART, RLENGTH)
	    }

	    # Add lombok before closing annotationProcessorPaths
	    in_compiler_plugin && in_annotation_paths && /<\/annotationProcessorPaths>/ {
	      print lombok
	      in_annotation_paths = 0
	    }

	    # Add annotationProcessorPaths before closing configuration (if not present)
	    in_compiler_plugin && in_configuration && !has_annotation_paths && /<\/configuration>/ {
	      indent = config_indent "    "
	      print indent "<annotationProcessorPaths>"
	      print lombok
	      print indent "</annotationProcessorPaths>"
	      has_annotation_paths = 1
	    }

	    # Add configuration before closing plugin (if not present)
	    in_compiler_plugin && !has_configuration && /<\/plugin>/ {
	      indent = plugin_indent "    "
	      print indent "<configuration>"
	      print indent "    <annotationProcessorPaths>"
	      print lombok
	      print indent "    </annotationProcessorPaths>"
	      print indent "</configuration>"
	      has_configuration = 1
	      has_annotation_paths = 1
	    }

	    # Print current line
	    { print }

	    # Reset when leaving configuration
	    in_compiler_plugin && /<\/configuration>/ {
	      in_configuration = 0
	    }

	    # Reset when leaving plugin
	    in_compiler_plugin && /<\/plugin>/ {
	      in_compiler_plugin = 0
	      has_configuration = 0
	      has_annotation_paths = 0
	    }
	  ' "$$pom_file" > "$$tmp_file"

	  mv "$$tmp_file" "$$pom_file"
	  echo "[INFO]   Added lombok annotationProcessorPath"

	done < <(find "$(MONOREPO_DIR)" -name "pom.xml" -print0)

	@echo ""
	@echo "[INFO] Lombok processor configuration completed"

# =============================================================================
# ADD-LICENCE: Copy license and community files to monorepo root, remove from modules
# =============================================================================

add-licence:
	@echo "==> Copying license and community files to monorepo root"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	licence_dir="$(TEMPLATES_DIR)/licence"
	if [[ ! -d "$$licence_dir" ]]; then
	  echo "[ERROR] Licence templates directory not found: $$licence_dir"
	  exit 1
	fi

	# Files to copy to root and remove from modules
	doc_files=("CODE-OF-CONDUCT.md" "CONTRIBUTING.md" "LICENSE" "SECURITY.md")

	# Copy files from templates/licence to monorepo root
	for doc_file in "$${doc_files[@]}"; do
	  src="$$licence_dir/$$doc_file"
	  dst="$(MONOREPO_DIR)/$$doc_file"
	  if [[ -f "$$src" ]]; then
	    cp "$$src" "$$dst"
	    echo "[INFO] Copied $$doc_file to monorepo root"
	  else
	    echo "[WARN] Template not found: $$src"
	  fi
	done

	# Remove these files from first-level modules
	@echo "==> Removing duplicate files from modules"

	while IFS= read -r -d '' module_dir; do
	  module_name="$$(basename "$$module_dir")"

	  # Skip special directories
	  [[ "$$module_name" == ".git" ]] && continue
	  [[ "$$module_name" == "parent" ]] && continue
	  [[ "$$module_name" == "bom-internal" ]] && continue

	  for doc_file in "$${doc_files[@]}"; do
	    file_path="$$module_dir/$$doc_file"
	    if [[ -f "$$file_path" ]]; then
	      rm "$$file_path"
	      echo "[INFO]   Removed $$doc_file from $$module_name"
	    fi
	  done
	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0)

	@echo ""
	@echo "[INFO] License and community files copied successfully"

# =============================================================================
# ADD-GITIGNORE: Create .gitignore in monorepo root from template
# =============================================================================

add-gitignore:
	@echo "==> Creating .gitignore in monorepo root"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/gitignore"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	dst="$(MONOREPO_DIR)/.gitignore"
	cp "$$template" "$$dst"
	echo "[INFO] Created $$dst from template"

	@echo ""
	@echo "[INFO] .gitignore created successfully"

# =============================================================================
# ADD-WORKFLOWS: Copy .github directory to monorepo root
# =============================================================================

add-workflows:
	@echo "==> Copying .github directory to monorepo root"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	github_template="$(TEMPLATES_DIR)/.github"
	if [[ ! -d "$$github_template" ]]; then
	  echo "[ERROR] .github template directory not found: $$github_template"
	  exit 1
	fi

	dst="$(MONOREPO_DIR)/.github"

	# Remove existing .github if present
	if [[ -d "$$dst" ]]; then
	  echo "[INFO] Removing existing $$dst"
	  rm -rf "$$dst"
	fi

	# Copy entire .github directory
	cp -r "$$github_template" "$$dst"
	echo "[INFO] Copied .github directory to monorepo root"

	@echo ""
	@echo "[INFO] .github directory copied successfully"


# ============================ EXPERIMENTAL ===================================

# =============================================================================
# PARENT: Create parent pom.xml
# =============================================================================

parent:
	@echo "==> Creating parent pom.xml"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR). Run 'make merge' first."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/parent-pom.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	parent_dir="$(MONOREPO_DIR)/parent"
	parent_pom="$$parent_dir/pom.xml"

	# Check if parent already exists
	if [[ -f "$$parent_pom" ]]; then
	  echo "[WARN] $$parent_pom already exists, skipping creation"
	else
	  mkdir -p "$$parent_dir"

	  xml_escape() {
	    local s="$${1:-}"
	    s="$${s//&/&amp;}"
	    s="$${s//</&lt;}"
	    s="$${s//>/&gt;}"
	    s="$${s//\"/&quot;}"
	    s="$${s//\'/&apos;}"
	    printf '%s' "$$s"
	  }

	  # Escape Makefile variables for XML
	  GROUP_ID="$$(xml_escape "$(MONOREPO_GROUP_ID)")"
	  ARTIFACT_ID="$$(xml_escape "$(MONOREPO_ARTIFACT_ID)")"
	  VERSION="$$(xml_escape "$(MONOREPO_VERSION)")"
	  GH_ORG="$$(xml_escape "$(GITHUB_ORG)")"
	  GH_URL="$$(xml_escape "$(GITHUB_URL)")"
	  GH_SCM_URL="$$(xml_escape "$(GITHUB_SCM_URL)")"
	  GH_PACKAGES_URL="$$(xml_escape "$(GITHUB_PACKAGES_URL)")"
	  JAVA_VER="$$(xml_escape "$(JAVA_VERSION)")"

	  # Create parent pom.xml from template
	  sed -e "s|@MONOREPO_GROUP_ID@|$$GROUP_ID|g" \
	      -e "s|@MONOREPO_ARTIFACT_ID@|$$ARTIFACT_ID|g" \
	      -e "s|@MONOREPO_VERSION@|$$VERSION|g" \
	      -e "s|@GITHUB_ORG@|$$GH_ORG|g" \
	      -e "s|@GITHUB_URL@|$$GH_URL|g" \
	      -e "s|@GITHUB_SCM_URL@|$$GH_SCM_URL|g" \
	      -e "s|@GITHUB_PACKAGES_URL@|$$GH_PACKAGES_URL|g" \
	      -e "s|@JAVA_VERSION@|$$JAVA_VER|g" \
	      "$$template" > "$$parent_pom"

	  # Format the generated pom.xml
	  xmlstarlet fo --indent-spaces 4 "$$parent_pom" > "$$parent_pom.tmp" && mv "$$parent_pom.tmp" "$$parent_pom"
	  echo "[INFO] Created $$parent_pom"
	fi

	# Add parent to root aggregator pom.xml if it exists
	root_pom="$(MONOREPO_DIR)/pom.xml"
	if [[ -f "$$root_pom" ]]; then
	  NS='x=http://maven.apache.org/POM/4.0.0'
	  if xmlstarlet sel -N "$$NS" -t -v '/x:project/x:modules' "$$root_pom" &>/dev/null; then
	    # modules section exists, check if parent already added
	    if ! xmlstarlet sel -N "$$NS" -t -v "/x:project/x:modules/x:module[text()='parent']" "$$root_pom" 2>/dev/null | grep -q .; then
	      # Detect indentation from existing <module> or use default 8 spaces
	      indent="$$(grep -m1 '<module>' "$$root_pom" | sed 's/<module>.*//' || printf '        ')"
	      # Insert parent as first module
	      sed -i "s|<modules>|&\n$${indent}<module>parent</module>|" "$$root_pom"
	      echo "[INFO]   Added parent to modules in $$root_pom"
	    else
	      echo "[INFO]   Module parent already in $$root_pom"
	    fi
	  fi
	fi

	# Add <parent> section to each module's root pom.xml
	@echo "==> Adding parent reference to module pom.xml files"

	NS='x=http://maven.apache.org/POM/4.0.0'

	while IFS= read -r -d '' module_dir; do
	  module_name="$$(basename "$$module_dir")"

	  # Skip special directories
	  [[ "$$module_name" == ".git" ]] && continue
	  [[ "$$module_name" == "parent" ]] && continue
	  [[ "$$module_name" == "bom-internal" ]] && continue

	  module_pom="$$module_dir/pom.xml"
	  [[ ! -f "$$module_pom" ]] && continue

	  # Check if parent section already exists
	  if xmlstarlet sel -N "$$NS" -t -v '/x:project/x:parent' "$$module_pom" &>/dev/null; then
	    echo "[INFO]   Module $$module_name already has parent"
	  else
	    echo "[INFO]   Adding parent to $$module_name"

	    # Detect indentation from existing first-level tags or use default 4 spaces
	    indent="$$(grep -m1 -E '    <(modelVersion|groupId|artifactId)>' "$$module_pom" | sed 's/<.*//' || printf '    ')"

	    # Create parent section with proper indentation
	    TMPDIR="$$(mktemp -d)"
	    trap 'rm -rf "$$TMPDIR"' EXIT
	    parent_section="$$TMPDIR/parent.txt"

	    echo "" > "$$parent_section"
	    echo "$${indent}<parent>" >> "$$parent_section"
	    echo "$${indent}    <groupId>$(MONOREPO_GROUP_ID)</groupId>" >> "$$parent_section"
	    echo "$${indent}    <artifactId>$(MONOREPO_ARTIFACT_ID)-parent</artifactId>" >> "$$parent_section"
	    echo "$${indent}    <version>$(MONOREPO_VERSION)</version>" >> "$$parent_section"
	    echo "$${indent}    <relativePath>../parent</relativePath>" >> "$$parent_section"
	    echo "$${indent}</parent>" >> "$$parent_section"

	    # Insert parent section after <modelVersion> line, preserving all formatting
	    sed -i "/<modelVersion>/r $$parent_section" "$$module_pom"
	  fi

	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

	@echo ""
	@echo "[INFO] Parent pom.xml created and configured successfully"

# =============================================================================
# MODULE-BOM: Generate Bill of Materials in each module
# =============================================================================

check-bom:
	@command -v xmlstarlet >/dev/null 2>&1 || { echo "[ERROR] xmlstarlet is required"; exit 1; }

module-bom: check-bom
	@echo "==> Generating BOM for each module"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR). Run 'make merge' first."
	  exit 1
	fi

	NS='x=http://maven.apache.org/POM/4.0.0'

	xml_escape() {
	  local s="$${1:-}"
	  s="$${s//&/&amp;}"
	  s="$${s//</&lt;}"
	  s="$${s//>/&gt;}"
	  s="$${s//\"/&quot;}"
	  s="$${s//\'/&apos;}"
	  printf '%s' "$$s"
	}

	get_groupId() {
	  local pom="$$1"
	  local group
	  group="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:groupId' "$$pom" 2>/dev/null || true)"
	  if [[ -z "$${group:-}" ]]; then
	    group="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:parent/x:groupId' "$$pom" 2>/dev/null || true)"
	  fi
	  printf '%s' "$$group"
	}

	get_version() {
	  local pom="$$1"
	  local version
	  version="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:version' "$$pom" 2>/dev/null || true)"
	  if [[ -z "$${version:-}" ]]; then
	    version="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:parent/x:version' "$$pom" 2>/dev/null || true)"
	  fi
	  printf '%s' "$$version"
	}

	get_artifactId() {
	  local pom="$$1"
	  xmlstarlet sel -N "$$NS" -t -v '/x:project/x:artifactId' "$$pom" 2>/dev/null || true
	}

	template="$(TEMPLATES_DIR)/module-bom-pom.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	# Process each module (first-level directory)
	while IFS= read -r -d '' module_dir; do
	  module_name="$$(basename "$$module_dir")"

	  # Skip special directories
	  [[ "$$module_name" == ".git" ]] && continue

	  # Check if root pom.xml exists
	  root_pom="$$module_dir/pom.xml"
	  [[ ! -f "$$root_pom" ]] && continue

	  echo "[INFO] Processing module: $$module_name"

	  # Extract groupId and version from root pom
	  root_groupId="$$(get_groupId "$$root_pom")"
	  root_version="$$(get_version "$$root_pom")"

	  if [[ -z "$$root_groupId" || -z "$$root_version" ]]; then
	    echo "[WARN]   Skipping $$module_name - cannot determine groupId/version" >&2
	    continue
	  fi

	  echo "[INFO]   GroupId: $$root_groupId, Version: $$root_version"

	  # Collect all artifacts from this module
	  TMPDIR="$$(mktemp -d)"
	  trap 'rm -rf "$$TMPDIR"' EXIT

	  artifacts_file="$$TMPDIR/artifacts.tsv"
	  : > "$$artifacts_file"

	  mapfile -d '' poms < <(find "$$module_dir" -name pom.xml -print0 | sort -z)

	  declare -A seen=()
	  for pom in "$${poms[@]}"; do
	    groupId="$$(get_groupId "$$pom")"
	    artifactId="$$(get_artifactId "$$pom")"

	    if [[ -z "$$artifactId" ]]; then
	      continue
	    fi
	    if [[ -z "$$groupId" ]]; then
	      continue
	    fi

	    key="$${groupId}:$${artifactId}"
	    if [[ -n "$${seen[$$key]:-}" ]]; then
	      continue
	    fi
	    seen["$$key"]=1

	    printf '%s\t%s\n' "$$groupId" "$$artifactId" >> "$$artifacts_file"
	  done
	  unset seen

	  if [[ ! -s "$$artifacts_file" ]]; then
	    echo "[WARN]   No artifacts found in $$module_name" >&2
	    continue
	  fi

	  # Escape Makefile variables for XML
	  GROUP_ID="$$(xml_escape "$$root_groupId")"
	  ARTIFACT_ID="$$(xml_escape "$$module_name")"
	  VERSION="$$(xml_escape "$$root_version")"

	  # Build dependencies section
	  deps_file="$$TMPDIR/dependencies.txt"
	  : > "$$deps_file"

	  while IFS=$$'\t' read -r groupId artifactId; do
	    echo "            <dependency>" >> "$$deps_file"
	    echo "                <groupId>$$(xml_escape "$$groupId")</groupId>" >> "$$deps_file"
	    echo "                <artifactId>$$(xml_escape "$$artifactId")</artifactId>" >> "$$deps_file"
	    echo "                <version>\$${project.version}</version>" >> "$$deps_file"
	    echo "            </dependency>" >> "$$deps_file"
	  done < "$$artifacts_file"

	  # Create BOM directory
	  bom_dir="$$module_dir/$${module_name}-bom-all"
	  mkdir -p "$$bom_dir"

	  # Generate BOM pom.xml from template
	  bom_pom="$$bom_dir/pom.xml"
	  sed -e "s|@MODULE_GROUP_ID@|$$GROUP_ID|g" \
	      -e "s|@MODULE_ARTIFACT_ID@|$$ARTIFACT_ID|g" \
	      -e "s|@MODULE_VERSION@|$$VERSION|g" \
	      -e "/@DEPENDENCIES@/ {" -e "r $$deps_file" -e "d" -e "}" \
	      "$$template" > "$$bom_pom"

	  # Format the generated pom.xml
	  xmlstarlet fo --indent-spaces 4 "$$bom_pom" > "$$bom_pom.tmp" && mv "$$bom_pom.tmp" "$$bom_pom"
	  echo "[INFO]   Created $$bom_pom"

	  # Add bom to root pom.xml modules section
	  if xmlstarlet sel -N "$$NS" -t -v '/x:project/x:modules' "$$root_pom" &>/dev/null; then
	    # modules section exists, check if bom already added
	    if ! xmlstarlet sel -N "$$NS" -t -v "/x:project/x:modules/x:module[text()='$${module_name}-bom-all']" "$$root_pom" 2>/dev/null | grep -q .; then
	      # Detect indentation from existing <module> or use default 8 spaces
	      indent="$$(grep -m1 '<module>' "$$root_pom" | sed 's/<module>.*//' || printf '        ')"
	      # Insert new module before </modules> tag, preserving all formatting
	      sed -i "s|</modules>|$${indent}<module>$${module_name}-bom-all</module>\n&|" "$$root_pom"
	      echo "[INFO]   Added $${module_name}-bom-all to modules in $$root_pom"
	    else
	      echo "[INFO]   Module $${module_name}-bom-all already in $$root_pom"
	    fi
	  else
	    # modules section doesn't exist, create it
	    # Detect indentation from existing first-level tags or use default 4 spaces
	    indent="$$(grep -m1 -E '<(groupId|artifactId|version|packaging)>' "$$root_pom" | sed 's/<.*//' || printf '    ')"
	    # Insert modules section before </project> tag, preserving all formatting
	    sed -i "s|</project>|$${indent}<modules>\n$${indent}    <module>$${module_name}-bom-all</module>\n$${indent}</modules>\n&|" "$$root_pom"
	    echo "[INFO]   Created modules section and added $${module_name}-bom-all to $$root_pom"
	  fi

	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

	@echo ""
	@echo "[INFO] Module BOM generation completed"

# =============================================================================
# BOM-CLEAN: Remove generated module BOMs and their references
# =============================================================================

bom-clean: check-bom
	@echo "==> Removing generated module BOMs"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR)."
	  exit 1
	fi

	NS='x=http://maven.apache.org/POM/4.0.0'

	# Remove generated module BOMs (matching pattern: module-name/module-name-bom-all/)
	while IFS= read -r -d '' module_dir; do
	  module_name="$$(basename "$$module_dir")"
	  [[ "$$module_name" == ".git" || "$$module_name" == "bom-internal" || "$$module_name" == "parent" ]] && continue

	  bom_dir="$$module_dir/$${module_name}-bom-all"
	  module_pom="$$module_dir/pom.xml"

	  if [[ -d "$$bom_dir" ]]; then
	    rm -rf "$$bom_dir"
	    echo "[INFO]   Removed $$bom_dir"

	    # Remove bom-all from module's pom.xml <modules> section
	    if [[ -f "$$module_pom" ]]; then
	      if xmlstarlet sel -N "$$NS" -t -v "/x:project/x:modules/x:module[text()='$${module_name}-bom-all']" "$$module_pom" 2>/dev/null | grep -q .; then
	        # Remove the module entry using sed (preserves formatting)
	        sed -i "/<module>$${module_name}-bom-all<\/module>/d" "$$module_pom"
	        echo "[INFO]   Removed $${module_name}-bom-all from modules in $$module_pom"
	      fi
	    fi
	  fi
	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

	# Remove root bom-internal
	if [[ -d "$(MONOREPO_DIR)/bom-internal" ]]; then
	  rm -rf "$(MONOREPO_DIR)/bom-internal"
	  echo "[INFO]   Removed $(MONOREPO_DIR)/bom-internal"

	  # Remove bom-internal from root pom.xml
	  root_pom="$(MONOREPO_DIR)/pom.xml"
	  if [[ -f "$$root_pom" ]]; then
	    if xmlstarlet sel -N "$$NS" -t -v "/x:project/x:modules/x:module[text()='bom-internal']" "$$root_pom" 2>/dev/null | grep -q .; then
	      sed -i "/<module>bom-internal<\/module>/d" "$$root_pom"
	      echo "[INFO]   Removed bom-internal from modules in $$root_pom"
	    fi
	  fi
	fi

	@echo ""
	@echo "[INFO] BOM cleanup completed"

# =============================================================================
# ROOT-BOM: Create root bom-internal that imports all module BOMs
# =============================================================================

root-bom: check-bom
	@echo "==> Creating root bom-internal"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR). Run 'make merge' first."
	  exit 1
	fi

	template="$(TEMPLATES_DIR)/root-bom-internal-pom.xml"
	if [[ ! -f "$$template" ]]; then
	  echo "[ERROR] Template not found: $$template"
	  exit 1
	fi

	bom_dir="$(MONOREPO_DIR)/bom-internal"
	bom_pom="$$bom_dir/pom.xml"

	# Check if bom-internal already exists
	if [[ -f "$$bom_pom" ]]; then
	  echo "[WARN] $$bom_pom already exists, skipping creation"
	  exit 0
	fi

	mkdir -p "$$bom_dir"

	NS='x=http://maven.apache.org/POM/4.0.0'

	xml_escape() {
	  local s="$${1:-}"
	  s="$${s//&/&amp;}"
	  s="$${s//</&lt;}"
	  s="$${s//>/&gt;}"
	  s="$${s//\"/&quot;}"
	  s="$${s//\'/&apos;}"
	  printf '%s' "$$s"
	}

	get_groupId() {
	  local pom="$$1"
	  local group
	  group="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:groupId' "$$pom" 2>/dev/null || true)"
	  if [[ -z "$${group:-}" ]]; then
	    group="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:parent/x:groupId' "$$pom" 2>/dev/null || true)"
	  fi
	  printf '%s' "$$group"
	}

	get_version() {
	  local pom="$$1"
	  local version
	  version="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:version' "$$pom" 2>/dev/null || true)"
	  if [[ -z "$${version:-}" ]]; then
	    version="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:parent/x:version' "$$pom" 2>/dev/null || true)"
	  fi
	  printf '%s' "$$version"
	}

	# Escape Makefile variables for XML
	GROUP_ID="$$(xml_escape "$(MONOREPO_GROUP_ID)")"
	ARTIFACT_ID="$$(xml_escape "$(MONOREPO_ARTIFACT_ID)")"
	VERSION="$$(xml_escape "$(MONOREPO_VERSION)")"

	# Build dependencies and properties sections
	TMPDIR="$$(mktemp -d)"
	trap 'rm -rf "$$TMPDIR"' EXIT
	deps_file="$$TMPDIR/dependencies.txt"
	props_file="$$TMPDIR/properties.txt"

	# Process each module (first-level directory)
	while IFS= read -r -d '' module_dir; do
	  module_name="$$(basename "$$module_dir")"

	  # Skip special directories
	  [[ "$$module_name" == ".git" ]] && continue
	  [[ "$$module_name" == "bom-internal" ]] && continue

	  # Check if root pom.xml exists
	  root_pom="$$module_dir/pom.xml"
	  [[ ! -f "$$root_pom" ]] && continue

	  echo "[INFO] Processing module: $$module_name"

	  # Extract version and groupId
	  module_version="$$(get_version "$$root_pom")"
	  module_groupId="$$(get_groupId "$$root_pom")"

	  if [[ -z "$$module_version" ]]; then
	    echo "[WARN]   Skipping $$module_name - cannot determine version" >&2
	    continue
	  fi

	  if [[ -z "$$module_groupId" ]]; then
	    echo "[WARN]   Skipping $$module_name - cannot determine groupId" >&2
	    continue
	  fi

	  # Add property for module version
	  echo "        <$${module_name}.version>$$(xml_escape "$$module_version")</$${module_name}.version>" >> "$$props_file"

	  # Import bom-all for this module
	  echo "        <dependency>" >> "$$deps_file"
	  echo "            <groupId>$$(xml_escape "$$module_groupId")</groupId>" >> "$$deps_file"
	  echo "            <artifactId>$$(xml_escape "$${module_name}-bom-all")</artifactId>" >> "$$deps_file"
	  echo "            <version>\$${$${module_name}.version}</version>" >> "$$deps_file"
	  echo "            <type>pom</type>" >> "$$deps_file"
	  echo "            <scope>import</scope>" >> "$$deps_file"
	  echo "        </dependency>" >> "$$deps_file"

	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

	# Replace placeholders using sed
	sed -e "s|@MONOREPO_GROUP_ID@|$$GROUP_ID|g" \
	    -e "s|@MONOREPO_ARTIFACT_ID@|$$ARTIFACT_ID|g" \
	    -e "s|@MONOREPO_VERSION@|$$VERSION|g" \
	    -e "/@PROPERTIES@/ {" -e "r $$props_file" -e "d" -e "}" \
	    -e "/@DEPENDENCIES@/ {" -e "r $$deps_file" -e "d" -e "}" \
	    "$$template" > "$$bom_pom"

	# Format the generated pom.xml
	xmlstarlet fo --indent-spaces 4 "$$bom_pom" > "$$bom_pom.tmp" && mv "$$bom_pom.tmp" "$$bom_pom"

	echo "[INFO] Created $$bom_pom"

	# Add bom-internal to root aggregator pom.xml if it exists
	root_pom="$(MONOREPO_DIR)/pom.xml"
	if [[ -f "$$root_pom" ]]; then
	  if xmlstarlet sel -N "$$NS" -t -v '/x:project/x:modules' "$$root_pom" &>/dev/null; then
	    # modules section exists, check if bom-internal already added
	    if ! xmlstarlet sel -N "$$NS" -t -v "/x:project/x:modules/x:module[text()='bom-internal']" "$$root_pom" 2>/dev/null | grep -q .; then
	      # Detect indentation from existing <module> or use default 8 spaces
	      indent="$$(grep -m1 '<module>' "$$root_pom" | sed 's/<module>.*//' || printf '        ')"
	      # Insert new module before </modules> tag, preserving all formatting
	      sed -i "s|</modules>|$${indent}<module>bom-internal</module>\n&|" "$$root_pom"
	      echo "[INFO]   Added bom-internal to modules in $$root_pom"
	    else
	      echo "[INFO]   Module bom-internal already in $$root_pom"
	    fi
	  fi
	fi

	@echo ""
	@echo "[INFO] Root bom-internal created successfully"
