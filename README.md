# TextEditor

A native macOS text editor built with **Swift + AppKit** — for those who love **Notepad++** but have to work on Mac.

Not a code editor. Not an IDE. Just a **fast, lightweight text editor** with the features you actually need — like Notepad++ or EmEditor on Windows. If you switched from Windows to Mac and miss the simplicity of opening files, searching across folders, and editing with tabs and bookmarks without loading a 500MB Electron app, this is for you.

**What makes it feel like home:**
- Find & Replace dialog with Match Case, Whole Word, Regex — not hidden behind a toolbar
- **Find in Files (grep)** with file type filters and exclude presets, just like EmEditor/Notepad++
- Bookmarks with F2/Shift+F2 navigation
- Tabbed editing with middle-click to close
- Syntax highlighting for 10 languages
- No project files, no workspace, no config — just open and edit

## Features

### Editor
- **Tabbed editing** — open multiple files, drag-drop reorder, middle-click to close, context menu (Close, Close All to Left/Right, Copy Full Path, Copy File Name, Reveal in Finder)
- **Smart tab titles** — disambiguates same-name files by showing parent directory (e.g. `src/main.cpp` vs `tests/main.cpp`)
- **Line numbers** — auto-width gutter with bookmark highlights
- **Current line highlight** — soft blue background on the active line
- **Auto-indent** — Enter copies leading whitespace from the current line
- **Word wrap toggle** — View > Word Wrap
- **Font selection** — View > Font via NSFontPanel
- **Status bar** — "Ln 5, Col 12 | 100 lines, 2500 chars"
- **Undo/Redo** — native NSUndoManager (Cmd+Z / Cmd+Shift+Z)

### Syntax Highlighting
10 languages with keyword, type, string, comment, and number colorization:

| Language | Extensions |
|----------|-----------|
| C/C++/ObjC | `.c` `.h` `.cpp` `.cc` `.cxx` `.hpp` `.hxx` `.m` `.mm` |
| Java | `.java` |
| Python | `.py` `.pyw` `.pyi` |
| JavaScript | `.js` `.jsx` `.mjs` `.cjs` |
| TypeScript | `.ts` `.tsx` `.mts` `.cts` |
| Go | `.go` |
| Rust | `.rs` |
| Bash | `.sh` `.bash` `.zsh` `.ksh` `.fish` |
| Markdown | `.md` `.markdown` |
| Plain text | everything else |

Supports multi-line constructs: block comments (`/* */`), Python triple quotes (`"""`, `'''`), Go raw strings, Bash variables, Python decorators, C preprocessor directives, markdown fenced code blocks.

### Find & Replace (Cmd+F / Cmd+Opt+F)
- **Modeless floating panel** with toggle between Find and Replace modes
- **Incremental search** — highlights update as you type
- **Match highlighting** — yellow (all matches), orange (current match)
- **Match counter** — "3 of 15" with navigation
- **Find Next/Prev** (Cmd+G / Cmd+Shift+G) with wrap-around
- **Replace / Replace All** — single undo group for Replace All
- **Options** — Match Case, Whole Word, Regex, Wrap Around

### Find in Files (Cmd+Shift+F)
- **File Types filter** (e.g. `*.java;*.py`), **Exclude presets** (C++/Qt, Python, Node.js, Java, Swift)
- **Parallel search** — up to 8 concurrent threads, non-blocking UI
- **Live results** — streamed to table every 200ms
- **5,000 match limit** with Stop button
- **Results panel** — split pane with File/Line/Content columns, double-click to open
- **Go to Line** (Cmd+L)

### File Operations
- **Open** (Cmd+O) — multi-select, binary file filtering (60+ extensions)
- **Save / Save As** (Cmd+S / Cmd+Shift+S)
- **Open Recent** — persisted across app restarts
- **Encoding** — UTF-8 with ISO-8859-1 fallback
- **Drag & Drop** — open files from Finder
- **Async file loading** — large files loaded off the main thread

### Bookmarks
- **Toggle** (Cmd+F2) — bookmark current line
- **Navigate** (F2 / Shift+F2) — next/previous with wraparound
- **Clear All** — remove all bookmarks in current tab
- Visual highlight in line number gutter

### Crash Recovery
- Auto-backup every 10 seconds
- Hash-based deduplication (skip unchanged content)
- Restore unsaved work on next launch
- Cleanup on normal exit

### macOS Integration
- Native window chrome with document-edited indicator
- Proxy icon in title bar (Cmd+click for path)
- Programmatic menu bar with standard macOS shortcuts
- NSFontPanel for font selection
- Finder file-open events
- Terminates after last window closed

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New | Cmd+N |
| Open | Cmd+O |
| Save | Cmd+S |
| Save As | Cmd+Shift+S |
| Close Tab | Cmd+W |
| Find | Cmd+F |
| Replace | Cmd+Opt+F |
| Find Next | Cmd+G |
| Find Previous | Cmd+Shift+G |
| Find in Files | Cmd+Shift+F |
| Go to Line | Cmd+L |
| Toggle Bookmark | Cmd+F2 |
| Next Bookmark | F2 |
| Previous Bookmark | Shift+F2 |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |

## Build

### Requirements
- macOS 13.0+
- Xcode 15+ (Swift 5, AppKit)

### Build & Run

```bash
# Command line
xcodebuild -project TextEditor.xcodeproj -scheme TextEditor -configuration Release build

# Or open in Xcode
open TextEditor.xcodeproj
```

### Install

```bash
# Build and copy to /Applications
xcodebuild -project TextEditor.xcodeproj -scheme TextEditor -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/TextEditor-*/Build/Products/Release/TextEditor.app /Applications/
```

## Architecture

Fully programmatic AppKit (no storyboards/nibs). Key design decisions:

- **Per-tab state** — each tab owns a `TabDocument` (model), `EditorView` (NSTextView subclass), `NSScrollView` with `LineNumberRulerView`, and a dedicated `SyntaxHighlighter` (NSTextStorageDelegate)
- **Incremental highlighting** — only re-highlights edited lines on each keystroke; per-line caches for multi-line constructs (block comments, triple quotes, fenced code blocks)
- **O(log n) line lookups** — `TabDocument.lineStartOffsets` array updated incrementally on each edit, enabling binary search for line/column calculations instead of scanning from the start of the file
- **Thread-safe concurrency** — Find in Files uses `OperationQueue` with `AtomicCounter`/`AtomicFlag`/`ThreadSafeArray` for lock-free result streaming
- **Debounced find** — find highlights update 300ms after typing stops, not on every keystroke

## Project Structure

```
texteditor/
├── App/
│   ├── AppDelegate.swift              # @main entry point, lifecycle
│   └── MainMenu.swift                 # Programmatic menu bar (8 menus)
│
├── Models/
│   ├── TabDocument.swift              # Per-tab state, line-start cache, syntax caches
│   └── SyntaxLanguage.swift           # 10-language keyword/type sets + detection
│
├── Views/
│   ├── MainWindowController.swift     # Window setup, crash recovery
│   ├── EditorTabViewController.swift  # Tab management, file ops, find/replace, bookmarks
│   ├── TabBarView.swift               # Custom-drawn tab bar with drag-drop
│   ├── EditorView.swift               # NSTextView subclass
│   ├── LineNumberRulerView.swift      # Line numbers + bookmark highlights
│   ├── StatusBarView.swift            # Cursor position + document stats
│   ├── FindPanelController.swift      # Modeless Find/Replace panel
│   ├── FindInFilesController.swift    # Find in Files dialog
│   └── DirSearchResultsView.swift     # Search results table
│
├── Syntax/
│   ├── SyntaxHighlighter.swift        # Token scanner, block comment cache
│   └── MarkdownHighlighter.swift      # Markdown-specific highlighting
│
├── Services/
│   ├── FileService.swift              # File I/O, encoding fallback, binary detection
│   ├── CrashRecoveryService.swift     # Periodic backup with hash dedup
│   └── PersistenceService.swift       # Recent files + directory history
│
├── Utilities/
│   ├── ConcurrencyHelpers.swift       # AtomicCounter, AtomicFlag, ThreadSafeArray, KeyCode
│   ├── StringLineHelpers.swift        # NSString extensions (lineNumber, lineCount, isWholeWord)
│   └── NSTextStorageExtensions.swift  # Safe attribute application with range validation
│
└── Theme/
    └── AppTheme.swift                 # Centralized colors + fonts
```
