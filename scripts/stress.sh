#!/bin/zsh
# Test de résistance : le vrai LibraryStore sur de grosses bibliothèques inventées, sans fenêtre.
#   scripts/stress.sh                       # paliers 1000 10000 50000 100000
#   scripts/stress.sh 1000 10000            # paliers choisis
# Livres générés une fois dans /tmp/foluna-stress-data/<n> (gardés), dossier de test vidé à chaque passage,
# rapports dans /tmp/foluna-stress (rapport-<n>.md, rapport-<n>.json, synthese.md).
# Compilé en release : les mesures en debug trompent.
set -e
source "${0:A:h}/env.sh"
cd "$ROOT"

SIZES=(${@:-1000 10000 50000 100000})
OUT=/tmp/foluna-stress
DATA=/tmp/foluna-stress-data
mkdir -p "$OUT" "$DATA"

# Environ 45 Ko par livre généré (EPUB, un sur trois avec couverture), plus les couvertures du store.
need=0
for n in $SIZES; do [[ -f "$DATA/$n/.complet" ]] || need=$(( need + n * 60 / 1024 )); done
free=$(( $(df -k /tmp | awk 'NR==2 {print $4}') / 1024 ))
if (( need > free )); then
  echo "Place insuffisante dans /tmp : environ $need Mo nécessaires, $free Mo libres." >&2
  exit 1
fi

swift build -c release "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)/Foluna"

rc=0
for n in $SIZES; do
  echo "== $n livres"
  FOLUNA_STORE="$OUT/store-$n" FOLUNA_STRESS_DATA="$DATA/$n" FOLUNA_STRESS_REPORT="$OUT" \
    "$BIN" --stress "$n" 2>&1 | tee "$OUT/journal-$n.txt" || rc=1
done

# Synthèse : une ligne par étape, une colonne par palier, pour voir comment chaque étape grandit.
python3 -I - "$OUT" $SIZES <<'EOF'
import json, sys, os
out, sizes = sys.argv[1], sys.argv[2:]
reports = {}
for n in sizes:
    p = os.path.join(out, f"rapport-{n}.json")
    if os.path.exists(p):
        reports[n] = json.load(open(p))
names = []
for r in reports.values():
    for s in r["steps"]:
        # Les noms qui portent un nombre (« création de 100 livres ») sont rapprochés par leur début.
        key = s["name"].split(" de ")[0] if s["name"].startswith("création") else s["name"]
        if key not in names: names.append(key)
def find(r, key):
    for s in r["steps"]:
        if s["name"] == key or (key.startswith("création") and s["name"].startswith("création")): return s
cols = list(reports)
lines = ["# Synthèse du test de résistance", "",
         "Durée en ms, puis plus long blocage du thread principal en ms entre parenthèses.", "",
         "| Étape | " + " | ".join(f"{n} livres" for n in cols) + " |",
         "| --- |" + " ---: |" * len(cols)]
for key in names:
    cells = []
    for n in cols:
        s = find(reports[n], key)
        cells.append("" if s is None else f"{s['milliseconds']:.0f} ({s['maxStallMilliseconds']:.0f})")
    lines.append(f"| {key} | " + " | ".join(cells) + " |")
lines += ["", "| Palier | Fichiers | Index (Ko) | Couvertures (Mo) | Mémoire max (Mo) | Échecs |", "| ---: | ---: | ---: | ---: | ---: | ---: |"]
for n in cols:
    r = reports[n]
    peak = max(s["peakFootprintMB"] for s in r["steps"])
    lines.append(f"| {n} | {r['files']} | {r['indexBytes'] // 1024} | {r['coverBytes'] // 1048576} | {peak:.0f} | {r['failures']} |")
open(os.path.join(out, "synthese.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
EOF
exit $rc
