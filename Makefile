SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

ROOT := $(abspath .)
TMP_DIR := $(ROOT)/tmp
MONOREPO_DIR := $(ROOT)/monorepo
REPOS_FILE := $(ROOT)/repos.txt
TEMPLATES_DIR := $(ROOT)/templates

# Aggregator pom.xml configuration
MONOREPO_GROUP_ID ?= com.netcracker.cloud
MONOREPO_ARTIFACT_ID ?= qubership-core-java-libs
MONOREPO_VERSION ?= 1.0.0-SNAPSHOT

.PHONY: all init clone merge aggregator parent bom module-bom root-bom bom-clean clean clean-aggregator clean-parent clean-root-bom clean-all check-init check-bom

all: clone merge aggregator parent bom

# Backward compatibility: init = clone + merge
init: clone merge

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
	  bare="$(TMP_DIR)/$${repo}.git"

	  echo "---- Cloning $$repo -> $$subdir"

	  rm -rf "$$bare"
	  git clone --bare --branch main --single-branch "$$url" "$$bare"

	  (
	    cd "$$bare"
	    git filter-repo \
	      --refs refs/heads/main \
	      --to-subdirectory-filter "$$subdir" \
	      --force
	  )
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

	rm -rf "$(MONOREPO_DIR)"
	git init "$(MONOREPO_DIR)"

	(
	  cd "$(MONOREPO_DIR)"
	  git commit --allow-empty -m "Initial monorepo commit"

	  echo "==> Merging rewritten histories"

	  while IFS='|' read -r url subdir || [[ -n "$$url" ]]; do
	    [[ -z "$$url" || "$$url" == \#* ]] && continue
	    repo="$$(basename "$$url" .git)"
	    bare="$(TMP_DIR)/$${repo}.git"

	    if [[ ! -d "$$bare" ]]; then
	      echo "[WARN] Skipping $$repo - not found in $(TMP_DIR)" >&2
	      continue
	    fi

	    git remote remove "$$subdir" 2>/dev/null || true
	    git remote add "$$subdir" "$$bare"
	    git fetch "$$subdir" main
	    git merge "$$subdir/main" \
	      --allow-unrelated-histories \
	      -m "chore(monorepo): merge $$repo into /$$subdir"
	  done < "$(REPOS_FILE)"
	)

	@echo ""
	@echo "DONE. Monorepo is ready at $(MONOREPO_DIR)"

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
	    -e "/@MODULES@/ {" -e "r $$modules_file" -e "d" -e "}" \
	    "$$template" > "$$root_pom"

	echo "[INFO] Created $$root_pom with modules from $(REPOS_FILE)"
	@echo ""
	@echo "[INFO] Aggregator pom.xml created successfully"

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

	  # Create parent pom.xml from template
	  sed -e "s|@MONOREPO_GROUP_ID@|$$GROUP_ID|g" \
	      -e "s|@MONOREPO_ARTIFACT_ID@|$$ARTIFACT_ID|g" \
	      -e "s|@MONOREPO_VERSION@|$$VERSION|g" \
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

	  # Check if BOM already exists (directory ending with "-bom" or named "bom")
	  has_bom=false
	  while IFS= read -r -d '' subdir; do
	    subdir_name="$$(basename "$$subdir")"
	    if [[ "$$subdir_name" == *"-bom" || "$$subdir_name" == "bom" || "$$subdir_name" == *"-bom-"* ]]; then
	      echo "[INFO]   Skipping $$module_name - BOM already exists ($$subdir_name)"
	      has_bom=true
	      break
	    fi
	  done < <(find "$$module_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

	  [[ "$$has_bom" == "true" ]] && continue

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

	  # Check if module has its own BOM (directory containing "-bom")
	  has_generated_bom=false
	  own_bom_dirs=()

	  while IFS= read -r -d '' subdir; do
	    subdir_name="$$(basename "$$subdir")"
	    # Check if directory ends with "-bom" or is named "bom"
	    if [[ "$$subdir_name" == *"-bom" || "$$subdir_name" == "bom" || "$$subdir_name" == *"-bom-"* ]]; then
	      if [[ "$$subdir_name" == "$${module_name}-bom-all" ]]; then
	        has_generated_bom=true
	      else
	        own_bom_dirs+=("$$subdir")
	      fi
	    fi
	  done < <(find "$$module_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

	  # Extract version for property
	  module_version="$$(get_version "$$root_pom")"
	  if [[ -z "$$module_version" ]]; then
	    echo "[WARN]   Skipping $$module_name - cannot determine version" >&2
	    continue
	  fi

	  # Add property for module version
	  echo "        <$${module_name}.version>$$(xml_escape "$$module_version")</$${module_name}.version>" >> "$$props_file"

	  if [[ "$${#own_bom_dirs[@]}" -gt 0 ]]; then
	    # Module already had its own BOM
	    if [[ "$${#own_bom_dirs[@]}" -eq 1 ]]; then
	      # Single BOM found - check if BOM directory has simple structure
	      module_bom_dir="$${own_bom_dirs[0]}"
	      module_bom_name="$$(basename "$$module_bom_dir")"

	      # Check if BOM directory contains only pom.xml (and optionally other files, but no subdirectories)
	      module_bom_pom="$$module_bom_dir/pom.xml"
	      if [[ -f "$$module_bom_pom" ]]; then
	        # Count subdirectories in BOM directory (should be 0)
	        bom_subdir_count=$$(find "$$module_bom_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)

	        if [[ $$bom_subdir_count -eq 0 ]]; then
	          # Simple BOM structure: no subdirectories (files like README are OK)
	          bom_groupId="$$(get_groupId "$$module_bom_pom")"
	          bom_artifactId="$$(xmlstarlet sel -N "$$NS" -t -v '/x:project/x:artifactId' "$$module_bom_pom" 2>/dev/null || true)"

	          if [[ -n "$$bom_groupId" && -n "$$bom_artifactId" ]]; then
	            echo "        <!-- Import existing BOM from $$module_name -->" >> "$$deps_file"
	            echo "        <dependency>" >> "$$deps_file"
	            echo "            <groupId>$$(xml_escape "$$bom_groupId")</groupId>" >> "$$deps_file"
	            echo "            <artifactId>$$(xml_escape "$$bom_artifactId")</artifactId>" >> "$$deps_file"
	            echo "            <version>\$${$${module_name}.version}</version>" >> "$$deps_file"
	            echo "            <type>pom</type>" >> "$$deps_file"
	            echo "            <scope>import</scope>" >> "$$deps_file"
	            echo "        </dependency>" >> "$$deps_file"
	          else
	            echo "        <!-- $$module_name has its own BOM ($$module_bom_name) - coordinates not found -->" >> "$$deps_file"
	          fi
	        else
	          # BOM directory has complex structure
	          echo "        <!-- $$module_name has its own BOM ($$module_bom_name) - complex BOM structure -->" >> "$$deps_file"
	        fi
	      else
	        echo "        <!-- $$module_name has its own BOM ($$module_bom_name) - pom.xml not found -->" >> "$$deps_file"
	      fi
	    else
	      # Multiple BOMs found - just add comment
	      echo "        <!-- $$module_name has multiple BOMs - not imported -->" >> "$$deps_file"
	    fi
	  elif [[ "$$has_generated_bom" == "true" ]]; then
	    # We generated BOM for this module - import it
	    module_groupId="$$(get_groupId "$$root_pom")"

	    if [[ -z "$$module_groupId" ]]; then
	      echo "[WARN]   Skipping $$module_name - cannot determine groupId" >&2
	      continue
	    fi

	    # Add dependency using property reference
	    echo "        <!-- Import generated BOM from $$module_name -->" >> "$$deps_file"
	    echo "        <dependency>" >> "$$deps_file"
	    echo "            <groupId>$$(xml_escape "$$module_groupId")</groupId>" >> "$$deps_file"
	    echo "            <artifactId>$$(xml_escape "$${module_name}-bom-all")</artifactId>" >> "$$deps_file"
	    echo "            <version>\$${$${module_name}.version}</version>" >> "$$deps_file"
	    echo "            <type>pom</type>" >> "$$deps_file"
	    echo "            <scope>import</scope>" >> "$$deps_file"
	    echo "        </dependency>" >> "$$deps_file"
	  fi

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

# =============================================================================
# CLEAN
# =============================================================================

clean: bom-clean
	@echo "[INFO] All BOMs removed"

clean-aggregator:
	@echo "==> Removing root aggregator pom.xml"
	rm -f "$(MONOREPO_DIR)/pom.xml"
	@echo "[INFO] Root pom.xml removed"

clean-parent:
	@echo "==> Removing parent pom.xml"
	rm -rf "$(MONOREPO_DIR)/parent"
	@echo "[INFO] Parent removed"

clean-root-bom:
	@echo "==> Removing root bom-internal"
	rm -rf "$(MONOREPO_DIR)/bom-internal"
	@echo "[INFO] Root bom-internal removed"

clean-all: clean clean-aggregator clean-parent clean-root-bom
	rm -rf "$(TMP_DIR)" "$(MONOREPO_DIR)"
