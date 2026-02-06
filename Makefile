SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

ROOT := $(abspath .)
TMP_DIR := $(ROOT)/tmp
MONOREPO_DIR := $(ROOT)/monorepo
BOM_DIR := $(MONOREPO_DIR)/bom-internal
BOM_FILE := $(BOM_DIR)/pom.xml
REPOS_FILE := $(ROOT)/repos.txt

.PHONY: all init bom clean clean-all check-init check-bom

all: init bom

# =============================================================================
# INIT: Clone repos and create monorepo with preserved git history
# =============================================================================

check-init:
	@command -v git >/dev/null 2>&1 || { echo "[ERROR] git is required"; exit 1; }
	@command -v git-filter-repo >/dev/null 2>&1 || { echo "[ERROR] git-filter-repo is required"; exit 1; }
	@[[ -f "$(REPOS_FILE)" ]] || { echo "[ERROR] $(REPOS_FILE) not found"; exit 1; }

init: check-init
	@echo "==> Step 1: Clone repos and move to subdirectories"
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

	@echo "==> Step 2: Create monorepo"
	rm -rf "$(MONOREPO_DIR)"
	git init "$(MONOREPO_DIR)"

	(
	  cd "$(MONOREPO_DIR)"
	  git commit --allow-empty -m "Initial monorepo commit"

	  echo "==> Step 3: Merge rewritten histories"

	  while IFS='|' read -r url subdir || [[ -n "$$url" ]]; do
	    [[ -z "$$url" || "$$url" == \#* ]] && continue
	    repo="$$(basename "$$url" .git)"
	    bare="$(TMP_DIR)/$${repo}.git"

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
# BOM: Generate Bill of Materials from monorepo
# =============================================================================

check-bom:
	@command -v xmlstarlet >/dev/null 2>&1 || { echo "[ERROR] xmlstarlet is required"; exit 1; }

bom: check-bom
	@echo "==> Generating BOM"

	if [[ ! -d "$(MONOREPO_DIR)" ]]; then
	  echo "[ERROR] Monorepo not found at $(MONOREPO_DIR). Run 'make init' first."
	  exit 1
	fi

	mkdir -p "$(BOM_DIR)"
	TMPDIR="$$(mktemp -d)"
	trap 'rm -rf "$$TMPDIR"' EXIT

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

	make_repo_property_name() {
	  local repo="$$1"
	  local s
	  s="$$(printf '%s' "$$repo" | tr '[:upper:]' '[:lower:]')"
	  s="$$(printf '%s' "$$s" | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$$//; s/\.+/./g')"
	  [[ -z "$$s" ]] && s="repo"
	  printf 'repo.%s.version' "$$s"
	}

	print_dep() {
	  local g="$$1" a="$$2" v="$$3"
	  cat <<EOL
	            <dependency>
	                <groupId>$$g</groupId>
	                <artifactId>$$a</artifactId>
	                <version>$$v</version>
	            </dependency>
	EOL
	}

	# PASS 1: scan each repo dir, collect coords into TSV per repo
	REPO_NAMES=()
	while IFS= read -r -d '' repo_dir; do
	  repo_name="$$(basename "$$repo_dir")"
	  [[ "$$repo_name" == "bom-internal" ]] && continue
	  [[ "$$repo_name" == ".git" ]] && continue
	  [[ ! -f "$$repo_dir/pom.xml" ]] && continue

	  echo "[INFO] Scanning repo: $$repo_name"
	  REPO_NAMES+=("$$repo_name")

	  repo_tsv="$$TMPDIR/$${repo_name}.tsv"
	  : > "$$repo_tsv"

	  mapfile -d '' poms < <(find "$$repo_dir" -name pom.xml -print0 | sort -z)

	  declare -A seen=()
	  for pom in "$${poms[@]}"; do
	    groupId="$$(get_groupId "$$pom")"
	    artifactId="$$(get_artifactId "$$pom")"
	    version="$$(get_version "$$pom")"

	    if [[ -z "$${artifactId:-}" ]]; then
	      echo "[WARN] Skipping pom without artifactId: $$pom" >&2
	      continue
	    fi
	    if [[ -z "$${groupId:-}" || -z "$${version:-}" ]]; then
	      echo "[WARN] Skipping pom with unresolved groupId/version: $$pom" >&2
	      continue
	    fi

	    key="$${groupId}:$${artifactId}"
	    if [[ -n "$${seen[$$key]:-}" ]]; then
	      continue
	    fi
	    seen["$$key"]=1

	    printf '%s\t%s\t%s\n' "$$groupId" "$$artifactId" "$$version" >> "$$repo_tsv"
	  done
	  unset seen
	done < <(find "$(MONOREPO_DIR)" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

	# Write POM header
	cat > "$(BOM_FILE)" <<'EOL'
	<?xml version="1.0" encoding="UTF-8"?>
	<project xmlns="http://maven.apache.org/POM/4.0.0"
	         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
	         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">

	    <modelVersion>4.0.0</modelVersion>

	    <groupId>com.netcracker.cloud</groupId>
	    <artifactId>bom-internal</artifactId>
	    <version>77.7.7-SNAPSHOT</version>
	    <packaging>pom</packaging>
	    <name>Internal BOM</name>

	EOL

	# PASS 2a: properties
	{
	  echo "    <properties>"
	  for repo_name in "$${REPO_NAMES[@]}"; do
	    repo_tsv="$$TMPDIR/$${repo_name}.tsv"
	    [[ ! -s "$$repo_tsv" ]] && continue

	    prop_name="$$(make_repo_property_name "$$repo_name")"
	    base_version="$$(cut -f3 "$$repo_tsv" | head -n 1)"
	    versions_count="$$(cut -f3 "$$repo_tsv" | sort | uniq | wc -l | tr -d ' ')"

	    if [[ "$$versions_count" -gt 1 ]]; then
	      echo "[WARN] Repo '$$repo_name' contains multiple versions; using '$$base_version' as base property '$$prop_name'" >&2
	    fi

	    printf '        <%s>%s</%s>\n' \
	      "$$(xml_escape "$$prop_name")" \
	      "$$(xml_escape "$$base_version")" \
	      "$$(xml_escape "$$prop_name")"
	  done
	  echo "    </properties>"
	  echo ""
	} >> "$(BOM_FILE)"

	# PASS 2b: dependencyManagement
	cat >> "$(BOM_FILE)" <<'EOL'
	    <dependencyManagement>
	        <dependencies>
	EOL

	for repo_name in "$${REPO_NAMES[@]}"; do
	  repo_tsv="$$TMPDIR/$${repo_name}.tsv"
	  [[ ! -s "$$repo_tsv" ]] && continue

	  prop_name="$$(make_repo_property_name "$$repo_name")"
	  base_version="$$(cut -f3 "$$repo_tsv" | head -n 1)"

	  printf '            <!-- %s -->\n' "$$(xml_escape "$$repo_name")" >> "$(BOM_FILE)"

	  while IFS=$$'\t' read -r groupId artifactId version; do
	    eg="$$(xml_escape "$$groupId")"
	    ea="$$(xml_escape "$$artifactId")"

	    if [[ "$$version" == "$$base_version" ]]; then
	      ev="\$${$$(xml_escape "$$prop_name")}"
	    else
	      ev="$$(xml_escape "$$version")"
	    fi

	    print_dep "$$eg" "$$ea" "$$ev" >> "$(BOM_FILE)"
	  done < "$$repo_tsv"

	  echo "" >> "$(BOM_FILE)"
	done

	cat >> "$(BOM_FILE)" <<'EOL'
	        </dependencies>
	    </dependencyManagement>

	</project>
	EOL

	@echo "[INFO] BOM generated: $(BOM_FILE)"

# =============================================================================
# CLEAN
# =============================================================================

clean:
	rm -rf "$(BOM_DIR)"

clean-all: clean
	rm -rf "$(TMP_DIR)" "$(MONOREPO_DIR)"
