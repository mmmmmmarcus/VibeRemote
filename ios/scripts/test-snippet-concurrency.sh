#!/bin/bash
set -euo pipefail
mkdir -p .airbuild/artifacts
# macOS cannot set iOS Data Protection classes (EINVAL). Adapt only those two
# platform calls for this process-concurrency test. iOS XCTest independently
# tests protection policy/backup metadata; locked-device behavior needs hardware.
python3 - <<'PY'
from pathlib import Path
source = Path('ios/Shared/SnippetStore.swift').read_text()
for old, new in [('.protectionKey: FileProtectionType.complete, ', ''),
                 ('[.withoutOverwriting, .completeFileProtection]', '[.withoutOverwriting]')]:
    assert source.count(old) == 1, 'Review platform adapter after store policy changes'
    source = source.replace(old, new)
Path('.airbuild/artifacts/SnippetStore-macOSConcurrency.swift').write_text(source)
PY
swiftc -parse-as-library .airbuild/artifacts/SnippetStore-macOSConcurrency.swift ios/scripts/tests/SnippetConcurrency.swift -o .airbuild/artifacts/snippet-concurrency
.airbuild/artifacts/snippet-concurrency | tee .airbuild/artifacts/snippet-concurrency.txt
rm .airbuild/artifacts/SnippetStore-macOSConcurrency.swift .airbuild/artifacts/snippet-concurrency
