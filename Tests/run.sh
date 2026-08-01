#!/bin/bash
# Compiles the model + syntax layer together with the tests and runs them.
# These types need no app bundle, so this stays out of the Xcode target.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/edit-index-tests

swiftc -O -o "$OUT" \
    Models/TabDocument.swift \
    Models/SyntaxLanguage.swift \
    Services/FileService.swift \
    Services/FileSearchService.swift \
    Services/FileWatchService.swift \
    Syntax/SyntaxHighlighter.swift \
    Syntax/MarkdownHighlighter.swift \
    Theme/AppTheme.swift \
    Utilities/ConcurrencyHelpers.swift \
    Utilities/NSTextStorageExtensions.swift \
    Utilities/StringLineHelpers.swift \
    Tests/EditIndexTests.swift \
    Tests/FileIOTests.swift \
    Tests/FileWatchTests.swift

"$OUT"
