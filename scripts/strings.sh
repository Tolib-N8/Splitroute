#!/bin/sh
# Извлекает строки интерфейса из исходников (как Xcode) и показывает те, которых нет в en.lproj.
#   sh scripts/strings.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=$(mktemp -d)
swift build --product Splitroute --scratch-path .build/strings \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
python3 - "$OUT" Resources/en.lproj/Localizable.strings <<'PY'
import glob, json, re, subprocess, sys
out, strings = sys.argv[1], sys.argv[2]
have = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', strings]))
missing = {}
for f in glob.glob(out + '/*.stringsdata'):
    d = json.load(open(f))
    for es in d['tables'].values():
        for e in es:
            k = e['key']
            if re.search('[А-Яа-яЁё]', k) and k not in have:
                missing[k] = f"{d['source'].split('/')[-1]}:{e['location']['startingLine']}"
for k, where in sorted(missing.items(), key=lambda x: x[1]):
    print(f'{where}\t{k!r}')
print(f'{len(missing)} непереведённых строк', file=sys.stderr)
sys.exit(1 if missing else 0)
PY
