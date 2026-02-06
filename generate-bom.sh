#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Requirements check
# ----------------------------
need_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] '$1' is required but not installed" >&2
    exit 1
  }
}
need_bin bash
need_bin xmlstarlet
need_bin find
need_bin sort
need_bin awk
need_bin sed
need_bin mkdir
need_bin mktemp
need_bin tr
need_bin uniq
need_bin cut
need_bin head
need_bin wc
need_bin rm

# ----------------------------
# Paths
# ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$SCRIPT_DIR/bom-internal"
OUTFILE="$OUTDIR/pom.xml"

# Maven POM namespace
NS='x=http://maven.apache.org/POM/4.0.0'

# ----------------------------
# Helpers
# ----------------------------

xml_escape() {
  local s="${1:-}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

get_groupId() {
  local pom="$1"
  local group
  group="$(xmlstarlet sel -N "$NS" -t -v '/x:project/x:groupId' "$pom" 2>/dev/null || true)"
  if [[ -z "${group:-}" ]]; then
    group="$(xmlstarlet sel -N "$NS" -t -v '/x:project/x:parent/x:groupId' "$pom" 2>/dev/null || true)"
  fi
  printf '%s' "$group"
}

get_version() {
  local pom="$1"
  local version
  version="$(xmlstarlet sel -N "$NS" -t -v '/x:project/x:version' "$pom" 2>/dev/null || true)"
  if [[ -z "${version:-}" ]]; then
    version="$(xmlstarlet sel -N "$NS" -t -v '/x:project/x:parent/x:version' "$pom" 2>/dev/null || true)"
  fi
  printf '%s' "$version"
}

get_artifactId() {
  local pom="$1"
  xmlstarlet sel -N "$NS" -t -v '/x:project/x:artifactId' "$pom" 2>/dev/null || true
}

# Maven property name: безопасно использовать точки; сделаем детерминированно.
# Пример: repo.my-repo.version
make_repo_property_name() {
  local repo="$1"
  local s
  s="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
  # Всё не [a-z0-9] -> '.'
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  if [[ -z "$s" ]]; then
    s="repo"
  fi
  printf 'repo.%s.version' "$s"
}

print_dep() {
  local g="$1" a="$2" v="$3"
  cat <<EOL
            <dependency>
                <groupId>$g</groupId>
                <artifactId>$a</artifactId>
                <version>$v</version>
            </dependency>
EOL
}

cleanup_tmp() {
  local d="${1:-}"
  [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
}

# ----------------------------
# Main (2-pass)
# ----------------------------

mkdir -p "$OUTDIR"
TMPDIR="$(mktemp -d)"
trap 'cleanup_tmp "$TMPDIR"' EXIT

# Соберём список репозиториев (папок рядом со скриптом), отсортированный
mapfile -t REPO_DIRS < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort)

REPO_NAMES=()

# PASS 1: сканирование и сбор координат в tsv на репо
for repo_dir in "${REPO_DIRS[@]}"; do
  repo_name="$(basename "$repo_dir")"

  [[ "$repo_name" == "bom-internal" ]] && continue
  [[ "$repo_name" == ".git" ]] && continue
  [[ ! -f "${repo_dir}/pom.xml" ]] && continue

  echo "[INFO] Scanning repo: $repo_name"
  REPO_NAMES+=("$repo_name")

  repo_tsv="$TMPDIR/${repo_name}.tsv"
  : > "$repo_tsv"

  # deterministic order of pom.xml
  mapfile -d '' poms < <(find "$repo_dir" -name pom.xml -print0 | sort -z)

  declare -A seen=()

  for pom in "${poms[@]}"; do
    groupId="$(get_groupId "$pom")"
    artifactId="$(get_artifactId "$pom")"
    version="$(get_version "$pom")"

    if [[ -z "${artifactId:-}" ]]; then
      echo "[WARN] Skipping pom without artifactId: $pom" >&2
      continue
    fi
    if [[ -z "${groupId:-}" || -z "${version:-}" ]]; then
      echo "[WARN] Skipping pom with unresolved groupId/version: $pom" >&2
      continue
    fi

    key="${groupId}:${artifactId}"
    if [[ -n "${seen[$key]:-}" ]]; then
      continue
    fi
    seen["$key"]=1

    # raw (not escaped) in TSV; escape later for XML
    printf '%s\t%s\t%s\n' "$groupId" "$artifactId" "$version" >> "$repo_tsv"
  done

  unset seen
done

# Начинаем писать POM (фиксированный хедер)
cat > "$OUTFILE" <<'EOL'
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

# PASS 2a: properties (по одной на репо)
# Опорная версия репо = версия первой строки tsv (как правило, у всех одинаковая).
# Если внутри репо есть отличающиеся версии — WARN; свойство всё равно будет с базовой,
# а отличающиеся зависимости получат явную версию.
{
  echo "    <properties>"
  for repo_name in "${REPO_NAMES[@]}"; do
    repo_tsv="$TMPDIR/${repo_name}.tsv"
    [[ ! -s "$repo_tsv" ]] && continue

    prop_name="$(make_repo_property_name "$repo_name")"
    base_version="$(cut -f3 "$repo_tsv" | head -n 1)"

    # уникальные версии в репо
    versions_count="$(cut -f3 "$repo_tsv" | sort | uniq | wc -l | tr -d ' ')"
    if [[ "$versions_count" -gt 1 ]]; then
      echo "[WARN] Repo '$repo_name' contains multiple versions; using '$base_version' as base property '$prop_name' and overriding outliers explicitly." >&2
    fi

    printf '        <%s>%s</%s>\n' \
      "$(xml_escape "$prop_name")" \
      "$(xml_escape "$base_version")" \
      "$(xml_escape "$prop_name")"
  done
  echo "    </properties>"
  echo ""
} >> "$OUTFILE"

# PASS 2b: dependencyManagement
cat >> "$OUTFILE" <<'EOL'
    <dependencyManagement>
        <dependencies>
EOL

for repo_name in "${REPO_NAMES[@]}"; do
  repo_tsv="$TMPDIR/${repo_name}.tsv"
  [[ ! -s "$repo_tsv" ]] && continue

  prop_name="$(make_repo_property_name "$repo_name")"
  base_version="$(cut -f3 "$repo_tsv" | head -n 1)"

  printf '            <!-- %s -->\n' "$(xml_escape "$repo_name")" >> "$OUTFILE"

  # Для каждой зависимости: если версия = base_version -> ${prop}, иначе явная версия
  while IFS=$'\t' read -r groupId artifactId version; do
    eg="$(xml_escape "$groupId")"
    ea="$(xml_escape "$artifactId")"

    if [[ "$version" == "$base_version" ]]; then
      ev="\${$(xml_escape "$prop_name")}"
    else
      ev="$(xml_escape "$version")"
    fi

    print_dep "$eg" "$ea" "$ev" >> "$OUTFILE"
  done < "$repo_tsv"

  echo "" >> "$OUTFILE"
done

cat >> "$OUTFILE" <<'EOL'
        </dependencies>
    </dependencyManagement>

</project>
EOL

echo "[INFO] All done. Results saved to $OUTFILE"
