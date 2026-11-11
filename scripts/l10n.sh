#!/bin/zsh
# Traductions de l'interface (catalogue de chaînes, comme dans Xcode).
#
#   scripts/l10n.sh sync            extrait les textes du code dans Resources/Localizable.xcstrings
#   scripts/l10n.sh check           échoue s'il manque une traduction ou s'il reste des clés périmées
#   scripts/l10n.sh prune           retire du catalogue les clés qui ne sont plus dans le code
#   scripts/l10n.sh compile <dir>   produit <dir>/<langue>.lproj (Localizable et InfoPlist) pour le bundle
#
# Le français est la langue source : les clés sont les textes français du code.
# Les langues traduites sont dans L10N_LANGUAGES (ci-dessous). xcstringstool vient de Xcode.
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"
L10N_LANGUAGES=(en nl de es)
CATALOG="$ROOT/Resources/Localizable.xcstrings"
INFOPLIST="$ROOT/Resources/InfoPlist.xcstrings"
XCSTRINGS="/Applications/Xcode.app/Contents/Developer/usr/bin/xcstringstool"

case "$1" in
  sync)
    [[ -x "$XCSTRINGS" ]] || { echo "xcstringstool introuvable : Xcode est nécessaire pour extraire les textes" >&2; exit 1; }
    OUT="$ROOT/.build/l10n"
    rm -rf "$OUT" && mkdir -p "$OUT"
    swift build "${SWIFT_FLAGS[@]}" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
    [[ -f "$CATALOG" ]] || echo '{"sourceLanguage":"fr","strings":{},"version":"1.0"}' > "$CATALOG"
    # Seulement nos fichiers : pas ceux des dépendances (ZIPFoundation).
    python3 - "$OUT" "$CATALOG" "$XCSTRINGS" <<'PY'
import glob, os, subprocess, sys
out, catalog, tool = sys.argv[1:4]
ours = {os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob("Sources/Foluna/**/*.swift", recursive=True)
               + glob.glob("Sources/FolunaCore/**/*.swift", recursive=True)}
files = [f for f in glob.glob(os.path.join(out, "*.stringsdata")) if os.path.splitext(os.path.basename(f))[0] in ours]
args = [tool, "sync", catalog]
for f in files: args += ["--stringsdata", f]
subprocess.run(args, check=True)
PY
    echo "✅ catalogue synchronisé : $(python3 -c "import json;print(len(json.load(open('$CATALOG'))['strings']))") clés"
    ;;
  check)
    python3 - "$CATALOG" "$INFOPLIST" "${L10N_LANGUAGES[@]}" <<'PY'
import json, sys
catalogs, langs = sys.argv[1:3], sys.argv[3:]
def done(loc):
    if "stringUnit" in loc:
        return loc["stringUnit"].get("state") == "translated" and loc["stringUnit"].get("value", "") != ""
    if "variations" in loc:
        return all(done(v) for kind in loc["variations"].values() for v in kind.values())
    return False
problems = []
for path in catalogs:
    try:
        strings = json.load(open(path))["strings"]
    except FileNotFoundError:
        problems.append(f"{path} : absent"); continue
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False or key.strip() == "":
            continue
        if entry.get("extractionState") == "stale":
            problems.append(f"périmée (scripts/l10n.sh prune) : {key!r}"); continue
        missing = [l for l in langs if not done(entry.get("localizations", {}).get(l, {}))]
        if missing:
            problems.append(f"{'/'.join(missing)} manquant : {key!r}")
for p in problems[:40]: print("✗", p)
if problems:
    print(f"{len(problems)} problème(s) de traduction"); sys.exit(1)
print("✅ traductions complètes :", ", ".join(langs))
PY
    ;;
  prune)
    python3 - "$CATALOG" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
stale = [k for k, v in d["strings"].items() if v.get("extractionState") == "stale"]
for k in stale: del d["strings"][k]
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(path, "a").write("\n")
print(f"{len(stale)} clé(s) retirée(s)")
PY
    ;;
  compile)
    DEST="$2"
    [[ -n "$DEST" ]] || { echo "usage : scripts/l10n.sh compile <dossier Resources>" >&2; exit 1; }
    if [[ ! -x "$XCSTRINGS" ]]; then
      echo "⚠️  xcstringstool introuvable (Xcode absent ?) : l'app reste en français" >&2
      exit 0
    fi
    for c in "$CATALOG" "$INFOPLIST"; do
      [[ -f "$c" ]] && "$XCSTRINGS" compile "$c" --output-directory "$DEST" >/dev/null
    done
    echo "🌐 langues : fr ${L10N_LANGUAGES[*]}"
    ;;
  languages)
    echo "fr ${L10N_LANGUAGES[*]}"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
