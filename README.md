# HashTableDB1

<p align="center">
  <b>Persistent, thread-safe key-value database for PowerShell</b><br>
  <i>JSON storage &bull; asynchronous I/O &bull; exact type fidelity &bull; transaction log &bull; zero dependencies</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell" alt="PowerShell 7+">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="No dependencies">
  <img src="https://img.shields.io/badge/tests-15%2F15%20passed-brightgreen" alt="Tests">
  <img src="https://img.shields.io/badge/storage-JSON%20%2F%20CLIXML-informational" alt="JSON / CLIXML storage">
  <img src="https://img.shields.io/badge/TxLog-optional-blueviolet" alt="Transaction log">
</p>

<p align="center"><a href="#english">English</a> &bull; <a href="#russian">Русский</a></p>

---

<a id="english"></a>
## 🇬🇧 English

### Overview

**HashTableDB1** is a lightweight, dependency-free, persistent key-value store written in pure PowerShell 7+. It saves data to JSON files (or classic CLIXML XML in compatibility mode), supports asynchronous flushing and loading, and preserves exact .NET types via an internal type-tagging mechanism. It also ships with an optional append-only **transaction log (TxLog)** for replica synchronisation and crash recovery (last snapshot + journal tail).

### Features

- **Persistent** - data survives process restarts (JSON on disk).
- **Thread-safe** - lock-free reads over `ConcurrentDictionary`; writes use CAS retry loops, TxLog registration is lock-free (per-key `ConcurrentDictionary`) and the TxLog flush itself is serialized by a single `Monitor`.
- **Asynchronous I/O** - four independent background subsystems (save, load, class rehydration, TxLog) run inside persistent `RunspacePool(1,1)` instances and never block the caller.
- **Type fidelity** - integers, longs, doubles, booleans, dates, GUIDs, arrays and nested hashtables round-trip exactly.
- **Transaction log** - optional append-only journal of `Add` / `Remove` deltas with monotonic ticks, values captured at operation time and atomic tmp+rename writes; replayable from the saved-state watermark for crash recovery and replica sync.
- **Backup rotation** - timestamped `.old` backups with configurable retention.
- **CLIXML compatibility mode** - `StorageFormat = 'Xml'` writes classic `PSSerializer` XML for legacy consumers; files of the other format are auto-migrated (archived to `OLD/`), so the folder always holds exactly one format.
- **Zero dependencies** - pure PowerShell 7+, no modules required.
- **Simple API** - `Add`, `Remove`, `Get`, `ContainsKey`, `GetAllKeys`, `GetAllValues`, `SaveToDisk`, `SaveToDiskAsync`, `LoadFromDisk`, `LoadFromDiskAsync`, `CompactDatabase`, `Dispose`.

### Requirements

- PowerShell 7.0 or newer
- Write access to the target storage directory

### Quick start

```powershell
. $PSScriptRoot/HashTableDB1/HashtableDB1-Class.ps1   # dot-source: [HashTableDB1] + JSON converter

# Create (or open) a database
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = "$PWD"
$db.DatabaseFileName   = "MyDB"

# Write
$db.Add('user',    @{ name = 'Alice'; age = 30 })
$db.Add('counter', 42)
$db.Add('created', [datetime]::UtcNow)

# Read
$user = $db.Get('user')
"$($user.name) is $($user.age)"

# Check existence
if ($db.ContainsKey('counter')) { $db.Get('counter') }

# Remove
$db.Remove('counter')

# Persist synchronously (or use SaveToDiskAsync for non-blocking)
$db.SaveToDisk()

# Load back
$db.CreateEmptyDB()
$null = $db.LoadFromDisk()

# Release resources
$db.Dispose()
```

### API reference

| Member | Description |
| --- | --- |
| `[HashTableDB1]::new()` | Creates an empty in-memory database instance. |
| `Add($Key, $Value)` | Inserts or updates a key. |
| `Remove($Key)` | Deletes a key from the merged and updates tables, marks it in `RemovedHT`. |
| `Get($Key)` | Returns the value or `$null`. |
| `ContainsKey($Key)` | `$true` if the key exists in the merged view. |
| `GetAllKeys()` | Returns all keys from the merged view. |
| `GetAllValues()` | Returns all values from the merged view. |
| `GetPendingChangesCount()` | Number of entries in `UpdatesHT` + `RemovedHT`. |
| `Clone()` | Returns a case-insensitive `Hashtable` snapshot of the merged view. |
| `CompactDatabase()` | Atomically swaps `MergedHT` into `MainHT` and resets delta tables. |
| `SaveToDisk()` | Synchronous save (auto-compacts when deltas exceed 30 % of main). |
| `SaveToDiskAsync()` | Asynchronous save via background runspace. |
| `LoadFromDisk()` | Synchronous load with legacy-XML fallback and recovery from `.tmp` / `.old`. |
| `LoadFromDiskAsync()` | Asynchronous load; class types are resolved on the main thread, instance rehydration runs in the background. |
| `UpsertNestedHashTableKey($Key, $SubKey, $Value)` | Atomic (CAS-retried) upsert of a secondary key inside a hashtable record. |
| `RemoveNestedHashTableKey($Key, $SubKey)` | Removes a secondary key; removes the record when it becomes empty. |
| `SaveTransactionLogAsync()` | Writes unsaved operation deltas to `TxLog/*.txlog` in the background. |
| `WaitForAsyncSaveToDisk()` / `WaitForAsyncLoadFromDisk()` / `WaitForAsyncRehydrate()` / `WaitForPendingTransactionLogOperations()` | Block until the corresponding async operation completes. |
| `CreateEmptyDB()` | Clears all in-memory state. |
| `EnsureDBFolderWithPermissions($SID, [bool]$AllowWrite)` | Creates the DB folder and applies ACL for the given SID. |
| `Dispose()` | Waits for all async work, unregisters events, disposes pools. |

### Configuration properties

| Property | Default | Description |
| --- | --- | --- |
| `DatabaseFolderPath` | `"./"` | Storage folder (created on save). |
| `DatabaseFileName` | `"HashTableDB"` | Base name of the three files. |
| `StorageFormat` | `'Json'` | `'Json'` (default: fast, readable, type-fidelity markers) or `'Xml'` (CLIXML compatibility mode). |
| `NumOfDbBackupsToKeep` | `0` | Timestamped backups kept in `OLD/` (0 = none). |
| `DatabaseParamsHT` | `@{}` | User parameters persisted with the DB (stored inside the deletes file). |
| `ReadOnlyMode` | `$false` | Blocks all write operations. |
| `EnableTransactionLog` | `$false` | Enables the transaction log. |
| `TxLogRetentionDays` | `3` | Retention window for `.txlog` files on disk (in-memory state is trimmed after every successful flush). |
| `TxLogFlushToDisk` | `$false` | fsync the txlog file to physical disk before it becomes visible (recovery-critical mode; costs an I/O stall per flush). |
| `DbStateAsOfTick` | `0` | Saved-state watermark: every op with tick ≤ this value is already reflected in the DB files (persisted as `___DBSTATEASTOFTICK___` in the deletes file, published on save, restored on load). Replay/sync must apply only txlog entries with a newer tick. |
| `LockFileMaxWaitTime` | `30` | Max seconds to wait for a stuck async operation before force-kill. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Result of the last operation: `0` = success, string code = error. |
| `MainFileLoadedDT` / `UpdatesFileLoadedDT` / `RemovedFileLoadedDT` | - | Per-file load/save timestamps; drive incremental loads (unchanged files are skipped). |

### Type fidelity

Values are stored with a type tag, so these round-trip exactly:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (nested).

PowerShell classes (user-defined, non-`System.*` / non-`Microsoft.*` namespaces) are serialized with a `~C` marker and rehydrated on load by a native C# batch pass: `~C` nodes are collected in a single traversal, each unique class name is resolved once into a type map, and all instances are rehydrated in one pass (a PowerShell fallback covers constructors with parameters). Complex `System.*` types fall back to minified CLIXML.

JSON markers used by the converter:

| Marker | Restored as |
| --- | --- |
| `{"~": true, ...}` | `PSCustomObject` |
| `{"~i": true, "123": ...}` | hashtable with Int32 keys |
| `{"~D": "2024-06-15T14:30:45.1230000Z"}` | `DateTime` with exact value and `Kind` |
| `{"~m": "999999999999999.99"}` | `decimal` with exact scale |
| `{"~S": "2024-06-15T..."}` | date-shaped string (never auto-converted to `DateTime`) |
| `{"~C": "MyClass", ...}` | instance of your PowerShell class |
| `{"__CLIXML__": "<Objs..."}` | complex .NET types via CLIXML |

In `Xml` (CLIXML) mode these tags do not exist: primitives, `DateTime`, arrays and hashtables round-trip via native `PSSerializer` semantics, while PowerShell classes come back as `Deserialized.*` property bags (accepted compatibility trade-off).

### Architecture

```
+-------------------+       +---------------------+
|   Caller thread   | ----> |  HashTableDB1 core  |
+-------------------+       |  - MainHT           |
                            |  - UpdatesHT        |
                            |  - RemovedHT        |
                            |  - MergedHT (view)  |
                            +----------+----------+
                                       |
              +------------------------+------------------------+
              |                        |                        |
              v                        v                        v
    +-------------------+   +-------------------+   +-------------------+
    |  Async save pool  |   |  Async load pool  |   |  Async TxLog pool |
    |  RunspacePool(1,1)|   |  RunspacePool(1,1)|   |  RunspacePool(1,1)|
    +---------+---------+   +---------+---------+   +---------+---------+
              |                       |                       |
              v                       v                       v
       *_main.json              *_main.json           TxLog/*.txlog
       *_updates.json           *_updates.json
       *_deletes.json           *_deletes.json
```

*Class rehydration runs as a fourth background operation, reusing the free load pool when possible.*

## Performance

Measured by the bundled suite (`code_testing/Test-Hashtable-DB1.ps1`) in fresh processes,
PowerShell 7, desktop hardware, records ≈ 1 KB:

| Operation | Volume | Json (default) | Xml (compatibility mode) |
| --- | --- | --- | --- |
| `Add` | 120 000 records | ≈ 2.7-3.4 s | format-independent* |
| `Get` | 50 000 lookups | ≈ 0.3 s | format-independent* |
| Random `Get` | 10 000 of 100 000 | ≈ 0.05 s | format-independent* |
| `SaveToDisk` | 120 000 records (~120 MB Json) | ≈ 0.17 s (~700 000 rec/s) | ≈ 2.4 s (~14× slower) |
| `LoadFromDisk` | 120 000 records | ≈ 0.5 s (~240 000 rec/s) | ≈ 2.4 s (~5× slower) |
| `SaveToDiskAsync` ×2 | 120 000 records | ≈ 0.25-0.3 s | ≈ 2.4 s |
| Peak transient memory on `SaveToDisk` | 120 000 records | ≈ +80 MB | ≈ +0.9 GB |
| `CompactDatabase` | 100 000-record base | ≈ 0.1 ms (reference swap) | same |

\* In-memory operations do not depend on the storage format. However, a large Xml save leaves
Large Object Heap residue (the whole CLIXML document is built as a single in-memory string),
which can slow down subsequent in-memory work until the heap is trimmed - prefer `Json`
unless legacy consumers require CLIXML.

---

## Asynchronous operations

HashTableDB1 ships **four independent async subsystems**, each backed by a
persistent `RunspacePool(1,1)` and a `Register-ObjectEvent`-driven completion handler.
The caller thread **never blocks** on disk I/O - GUI scripts stay responsive while
multi-hundred-MB databases are being flushed or loaded.

| Subsystem | Entry point | Completion wait | Backing field |
| --- | --- | --- | --- |
| Async save | `SaveToDiskAsync()` | `WaitForAsyncSaveToDisk()` | `$AsynchronousSaveOperationState` |
| Async load | `LoadFromDiskAsync()` | `WaitForAsyncLoadFromDisk()` | `$AsynchronousLoadOperationState` |
| Async TxLog | `SaveTransactionLogAsync()` | `WaitForPendingTransactionLogOperations()` | `$AsynchronousTransactionLogSaveState` |
| Async rehydrate | internal: launched by the async-load event action | `WaitForAsyncRehydrate()` | `$AsynchronousRehydrateOperationState` (reuses the free load pool when possible) |

### Typical async workflow

```powershell
# 1. Start a background load - returns immediately
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = "$PWD"
$db.DatabaseFileName   = "MyDB"
$db.LoadFromDiskAsync()

# 2. Do something else on the main thread (render UI, parse args, ...)
Show-SplashScreen

# 3. Block only when the data is actually needed
$db.WaitForAsyncLoadFromDisk()
$db.Get('user')

# 4. Write a lot of data, then flush in the background
$db.Add('a', 1); $db.Add('b', 2); $db.Add('c', 3)
$db.SaveToDiskAsync()
```

### Why async matters

- **No GUI freeze** - the `InvocationStateChanged` event action is deliberately lightweight;
  heavy work (deserialization, `ConcurrentDictionary` build, TxLog rebuild) happens *inside*
  the background runspace.
- **Atomic state swap** - `MergedHT` is replaced **last**, so concurrent readers keep serving
  the old consistent view until the very end of the swap. Assignment order:
  `MainHT` → `UpdatesHT` → `RemovedHT` → `MergedHT`.
- **Background class rehydration** - `LoadFromDiskAsync` collects `~C` marker nodes in the
  background (Phase 3); the event action resolves each unique class name once on the main
  thread (user classes exist only in that session) and immediately launches a fourth
  background operation that rehydrates all instances in a single native pass - the main
  thread never freezes on large class-heavy datasets. If no `~C` markers were seen, the
  traversal is skipped entirely.
- **Bounded waits** - every `WaitFor*` uses `LockFileMaxWaitTime` (default **30 s**);
  on timeout the runspace is force-killed and the pool re-created on next use.
- **Self-healing** - bad `PSEventJob` states (`Failed`, `Blocked`) are detected and cleaned
  up automatically via `CleanupAsync`. `HadErrors` streams are surfaced via
  `writeAsyncInstanceErrors` with category, ID and script stack trace.
- **Persistent pools** - `RunspacePool` instances are created once and reused across
  every call, avoiding cold-start cost on each save / load / TxLog flush.

### Async error handling

Each async action wraps `EndInvoke` in a `try / catch / finally`:

```powershell
try   { $null = $PSInstance.EndInvoke($asyncResult) }
catch { $thisObj.ErrorLevel = "STXASNC1"; $thisObj.ErrorText = $_.Exception.Message }
finally { [HashTableDB1]::CleanupAsync([ref]$thisObj.AsynchronousSaveOperationState) }
```

`CleanupAsync` performs a bounded synchronous stop (max 3 s in `Stopping` state),
disposes the `PSInstance`, unregisters the event, and nulls the references so the pool
is re-created on the next operation.

---

## Transaction log (TxLog)

The TxLog is an **opt-in append-only journal** that records the last operation per key
(`Add` / `Remove` / nested upserts) with a monotonically increasing tick and the value
captured at operation time. It is designed for **replica synchronisation** and
**crash recovery** (last snapshot + journal tail).

Enable it once on the writer side:

```powershell
$db.EnableTransactionLog   = $true
$db.TxLogRetentionDays     = 7      # auto-delete files older than 7 days
# $db.TxLogFlushToDisk     = $true  # optional: fsync each txlog file (recovery-critical mode)
$db.DatabaseFolderPath     = "$PWD"
```

### What gets written

For every batch of changes a file is created under `TxLog/`:

```
<DatabaseFileName>_<firstTick>_<lastTick>.txlog
```

Content is a compact JSON array of `[op, key, value, tick]` tuples:

```json
[
  ["A", "user:42", { "name": "Alice" }, 133712345678901234],
  ["R", "user:17", null,                133712345678902345]
]
```

- `op` - `"A"` (add/update) or `"R"` (remove)
- `value` - the value captured at operation registration time for `"A"`, `null` for `"R"` (exact replay record, never re-read from the merged view)
- `tick` - monotonic tick issued by the internal `TxTickGenerator` (wall-clock based, CAS-clamped above every previously issued tick - immune to backward clock jumps)

Files are written atomically: data goes to `<name>.txlog.tmp` and is renamed only after
a successful serialization, so a crash can never leave a torn `.txlog` - file ranges stay
strictly increasing and non-overlapping.

The writer also maintains the in-memory state:

| Field | Type | Purpose |
| --- | --- | --- |
| `KeyToTx` | `ConcurrentDictionary[string, object]` | Last `(tick, op, value)` record per key, captured at op time. Lock-free; doubles as last-writer-wins bookkeeping for sync. Bounded by distinct keys, trimmed after every successful flush. |
| `TxTickGenerator` | C# class (hidden) | Monotonic tick source (CAS-clamped wall clock). On load it is bootstrapped above the saved-state watermark, so a replica with a lagging clock never issues ticks below the state it just loaded. |
| `TxLogSaveLock` | `object` (hidden) | Serializes sync + async invocations of the TxLog flush scriptblock. |
| `LastTransactionLogSavedTimestamp` | `long` | High-water mark: only entries with a newer tick are written on the next flush. |
| `LastTxLogTick` | `long` | Last tick persisted to a txlog file. |

### Saved-state watermark (replay position)

Every save writes `___DBSTATEASTOFTICK___` into the deletes file: all operations with
`tick <= DbStateAsOfTick` are already reflected in the saved `main` / `updates` / `deletes`
files. The property is published on save and restored on load. **Replay/sync must apply
only txlog entries with a newer tick** - this makes recovery deterministic:

1. Load the database files (the watermark comes with them).
2. Read `TxLog/*.txlog` in ascending `firstTick` order (file names carry the ranges).
3. Skip whole files whose `lastTick <= DbStateAsOfTick`; apply per-entry `tick > watermark`
   as `"A" -> Add(key, value)` / `"R" -> Remove(key)` (idempotent, last-writer-wins by tick).

A reference implementation of this algorithm is the `Invoke-TxLogReplay` helper in the
test suite (Test 15). When applying a *remote* replica's log, do not route entries through
`Add`/`Remove` of your own writer instance - that would re-register the ops in your TxLog
and echo them back; write to the dictionaries directly instead.

### Retention & cleanup

`SaveTxLogScriptBlock` cleans up on every successful flush:

1. **In-memory trim** - every `KeyToTx` record with `tick <= lastTick of the flushed file`
   is removed, so memory holds only the *unsaved* delta, not a retention window of
   history. Safe by construction: new ticks are issued strictly above the generator
   watermark, so a concurrently registered op can never be trimmed.
2. **Orphan `.tmp` GC** - crash-leftover `<name>_*_*.txlog.tmp` files older than 1 hour
   are deleted (the age guard covers a foreign in-flight writer).
3. **On-disk retention** - `.txlog` files regex-matched by name and deleted if
   `GetLastWriteTime < cutoff` (3 retry attempts on `IOException`).

`LastTransactionLogSavedTimestamp` (the high-water mark) and `LastTxLogTick` advance
only after a successful commit; on any failure the pending delta stays in memory and
the next flush rewrites the same tick range under the same file name (idempotent
overwrite).

### Why a TxLog is worth it

| Without TxLog | With TxLog |
| --- | --- |
| Replica must reload the whole DB | Replica replays only deltas |
| Recovery = last full snapshot | Recovery = snapshot + tail of journal |
| No audit trail | Every change is timestamped and attributable |
| Conflicts hidden | Last-writer-wins is explicit and replayable |
| Disk usage grows with full DB size | Disk usage bounded by retention policy |

The journal is **append-only**, so writes are sequential and fast; the retention
policy keeps disk usage bounded without operator intervention.

### TxLog performance notes

- Registration is **lock-free**: one closed-generic `Tuple(tick, op, value)` allocation and
  one `ConcurrentDictionary` overwrite per operation (~1 µs), no `PSObject` wrapping and
  no locks on the write hot path.
- Delta collection is a single native C# pass over `KeyToTx` (filter by cutoff, build the
  entry list, track min/max ticks for the file name) - no PowerShell loops and no
  snapshot copy under a lock.
- Memory is bounded by *distinct changed keys since the last flush* (trimmed after every
  successful write), not by the retention window.
- The TxLog writer runs in its own `RunspacePool(1,1)`; a save of the main DB and a
  TxLog flush can run **concurrently**. Sync and async flushes are mutually excluded by
  `TxLogSaveLock`.
- The bundled test suite runs with TxLog enabled, so the in-memory timings in the
  performance table already include the registration overhead.

---

## Backup & recovery

### Backup rotation

When `NumOfDbBackupsToKeep > 0`, every successful save rotates the previous
`*_main.json`, `*_updates.json`, `*_deletes.json` into an `OLD/` subfolder with
a `yyyyMMdd-HHmmss` suffix:

```
OLD/MyDB_main.20260115-134501
OLD/MyDB_updates.20260115-134501
OLD/MyDB_deletes.20260115-134501
```

Retention is enforced by `_MoveOld`, which sorts backups lexicographically
(timestamp order) and deletes the oldest overflow. All file operations use
`_RetryFileOp` - 5 attempts with 100 ms backoff on `IOException` /
`UnauthorizedAccessException` (AV scanners, search indexers, etc.).

### Automatic recovery

On load, if a primary file is missing or corrupted, the loader tries `.tmp`
and `.old` variants in order. Each candidate is validated by a full
deserialization before being promoted, so a corrupted `.tmp` never overwrites
a good `.old`:

```
*_main.json   →   *_main.json.tmp   →   *_main.json.old
*_updates.json →  *_updates.json.tmp →  *_updates.json.old
*_deletes.json →  *_deletes.json.tmp →  *_deletes.json.old
```

Legacy `.xml` files from earlier versions are transparently handled, and the
`StorageFormat` property controls which format is written:

- Files are picked up JSON-first: if `<file>_main.json` does not exist but
  `<file>_main.xml` does, the XML is loaded via `PSSerializer.Deserialize`.
- Cross-format migration is automatic in both directions: after loading files whose
  format differs from `StorageFormat`, the database is resaved in the configured format
  and the old-format files are archived to `OLD/` (when backups are enabled) or deleted -
  the folder always holds exactly one format.
- `StorageFormat = 'Xml'` (CLIXML compatibility mode) keeps writing classic
  `PSSerializer` XML for legacy consumers that cannot read JSON.

### Error codes

| Code | Meaning |
| --- | --- |
| `LFX1` | Main database file does not exist (first run - treated as normal). |
| `LFX2` | Main database corrupted and no valid fallback found. |
| `LFX4` | Updates database corrupted and no valid fallback found. |
| `LFX6` | Deletes database corrupted and no valid fallback found. |
| `LFX8` | Unexpected load error. |
| `STX1` | Synchronous save failed. |
| `STXT1` | Synchronous TxLog save failed. |
| `STXASNC1` | Async save `EndInvoke` threw. |
| `TXLOG2` | Async TxLog `EndInvoke` threw. |
| `TXLOG3` | Failed to start async TxLog save. |
| `RHYD1` | Failed to start async class rehydration. |
| `RHYD2` | Async class rehydration `EndInvoke` threw. |
| `ALOAD1` | Failed to start async load. |
| `ALOAD2` | Async load `EndInvoke` returned no output. |
| `EDBFP1` | Failed to ensure DB folder with permissions. |

### Testing

```powershell
# The suite is a plain script (not Pester) - run it in a fresh process
pwsh -NoProfile -File ./code_testing/Test-Hashtable-DB1.ps1
```

The `$StorageFormatToTest` variable at the top of the script selects the storage format for
save/load tests (`'json'` or `'xml'`). Expected: **15 / 15 passed** in Json mode; in Xml mode
Test 14 (JSON type-fidelity markers) is skipped by design, while Test 15 (TxLog correctness,
watermark and crash-recovery replay) is format-independent and always runs.

### License

MIT - see [LICENSE](LICENSE).

---

<a id="russian"></a>
## 🇷🇺 Русский

### Обзор

**HashTableDB1** - лёгкое, не имеющее зависимостей, персистентное хранилище
«ключ-значение», написанное на чистом PowerShell 7+. Данные сохраняются в JSON-файлы (или классический CLIXML XML в режиме совместимости),
поддерживается асинхронная запись и загрузка, а также точное сохранение .NET-типов
через внутреннюю систему тегов. Дополнительно реализован опциональный
append-only **транзакционный лог (TxLog)** для синхронизации реплик и
восстановления после сбоев (последний снимок + хвост журнала).

### Возможности

- **Персистентность** - данные переживают перезапуск процесса (JSON на диске).
- **Потокобезопасность** - чтение без блокировок поверх `ConcurrentDictionary`; записи через CAS-повторы, регистрация TxLog lock-free (per-key `ConcurrentDictionary`), сам сброс TxLog сериализуется одним `Monitor`.
- **Асинхронный ввод-вывод** - четыре независимые фоновые подсистемы (save, load, реанимация классов, TxLog) работают в постоянных `RunspacePool(1,1)` и не блокируют вызывающий поток.
- **Точность типов** - целые, длинные, дробные, логические, даты, GUID, массивы и вложенные хеш-таблицы восстанавливаются без потерь.
- **Транзакционный лог** - опциональный append-only журнал дельт `Add` / `Remove` с монотонными тиками, захватом значений в момент операции и атомарной записью tmp+rename; воспроизводим от watermark'а сохранённого состояния для восстановления и синхронизации.
- **Ротация бэкапов** - временные метки `.old` с настраиваемым хранением.
- **Режим совместимости CLIXML** - `StorageFormat = 'Xml'` пишет классический XML `PSSerializer` для легаси-потребителей; файлы другого формата мигрируют автоматически (уходят в `OLD/`), поэтому в папке всегда ровно один формат.
- **Ноль зависимостей** - только PowerShell 7+.
- **Простой API** - `Add`, `Remove`, `Get`, `ContainsKey`, `GetAllKeys`, `GetAllValues`, `SaveToDisk`, `SaveToDiskAsync`, `LoadFromDisk`, `LoadFromDiskAsync`, `CompactDatabase`, `Dispose`.

### Требования

- PowerShell 7.0 или новее
- Права на запись в целевую директорию

### Быстрый старт

```powershell
. $PSScriptRoot/HashTableDB1/HashtableDB1-Class.ps1   # dot-sourcing: [HashTableDB1] и конвертер загружены

# Создать (или открыть) базу
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = "$PWD"
$db.DatabaseFileName   = "MyDB"

# Запись
$db.Add('user',    @{ name = 'Alice'; age = 30 })
$db.Add('counter', 42)
$db.Add('created', [datetime]::UtcNow)

# Чтение
$user = $db.Get('user')
"$($user.name) is $($user.age)"

# Проверка наличия
if ($db.ContainsKey('counter')) { $db.Get('counter') }

# Удаление
$db.Remove('counter')

# Синхронное сохранение (или SaveToDiskAsync - не блокирует)
$db.SaveToDisk()

# Загрузка обратно
$db.CreateEmptyDB()
$null = $db.LoadFromDisk()

# Освобождение ресурсов
$db.Dispose()
```

### Справочник API

| Метод | Описание |
| --- | --- |
| `[HashTableDB1]::new()` | Создаёт пустой in-memory экземпляр базы. |
| `Add($Key, $Value)` | Добавляет или обновляет ключ. |
| `Remove($Key)` | Удаляет ключ из merged и updates, помечает в `RemovedHT`. |
| `Get($Key)` | Возвращает значение или `$null`. |
| `ContainsKey($Key)` | `$true`, если ключ есть в merged-представлении. |
| `GetAllKeys()` | Все ключи merged-представления. |
| `GetAllValues()` | Все значения merged-представления. |
| `GetPendingChangesCount()` | Число записей в `UpdatesHT` + `RemovedHT`. |
| `Clone()` | Возвращает `Hashtable` без учёта регистра - снимок merged. |
| `CompactDatabase()` | Атомарно переносит `MergedHT` в `MainHT` и сбрасывает дельты. |
| `SaveToDisk()` | Синхронное сохранение (авто-компакт при дельтах > 30 % от main). |
| `SaveToDiskAsync()` | Асинхронное сохранение через фоновый runspace. |
| `LoadFromDisk()` | Синхронная загрузка с fallback на legacy-XML и восстановлением из `.tmp` / `.old`. |
| `LoadFromDiskAsync()` | Асинхронная загрузка; типы классов резолвятся в основном потоке, реанимация экземпляров идёт в фоне. |
| `UpsertNestedHashTableKey($Key, $SubKey, $Value)` | Атомарный (CAS-повторы) upsert вторичного ключа внутри записи-хеш-таблицы. |
| `RemoveNestedHashTableKey($Key, $SubKey)` | Удаляет вторичный ключ; удаляет запись, когда она опустела. |
| `SaveTransactionLogAsync()` | Фоновая запись несохранённых дельт операций в `TxLog/*.txlog`. |
| `WaitForAsyncSaveToDisk()` / `WaitForAsyncLoadFromDisk()` / `WaitForAsyncRehydrate()` / `WaitForPendingTransactionLogOperations()` | Блокируются до завершения соответствующей async-операции. |
| `CreateEmptyDB()` | Очищает всё in-memory состояние. |
| `EnsureDBFolderWithPermissions($SID, [bool]$AllowWrite)` | Создаёт папку БД и назначает ACL для указанного SID. |
| `Dispose()` | Ждёт все async-операции, снимает события, dispose пулов. |

### Свойства конфигурации

| Свойство | По умолчанию | Описание |
| --- | --- | --- |
| `DatabaseFolderPath` | `"./"` | Папка хранения (создаётся при сохранении). |
| `DatabaseFileName` | `"HashTableDB"` | Базовое имя трёх файлов. |
| `StorageFormat` | `'Json'` | `'Json'` (по умолчанию: быстро, читаемо, маркеры точности типов) или `'Xml'` (режим совместимости CLIXML). |
| `NumOfDbBackupsToKeep` | `0` | Датированных бэкапов в `OLD/` (0 = не хранить). |
| `DatabaseParamsHT` | `@{}` | Пользовательские параметры, хранимые вместе с БД (внутри deletes-файла). |
| `ReadOnlyMode` | `$false` | Блокирует все операции записи. |
| `EnableTransactionLog` | `$false` | Включает транзакционный лог. |
| `TxLogRetentionDays` | `3` | Окно хранения `.txlog`-файлов на диске (in-memory состояние обрезается после каждого успешного сброса). |
| `TxLogFlushToDisk` | `$false` | Принудительный fsync txlog-файла на физический диск перед его появлением - режим, критичный к восстановлению; стоит I/O-паузы на каждый сброс. |
| `DbStateAsOfTick` | `0` | Watermark сохранённого состояния: все операции с тиком ≤ значения уже отражены в файлах БД (пишется как `___DBSTATEASTOFTICK___` в deletes-файл, публикуется при save, восстанавливается при load). Replay/sync должны применять только записи txlog с более новым тиком. |
| `LockFileMaxWaitTime` | `30` | Максимум секунд ожидания зависшей async-операции до принудительного завершения. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Результат последней операции: `0` = успех, строковый код = ошибка. |
| `MainFileLoadedDT` / `UpdatesFileLoadedDT` / `RemovedFileLoadedDT` | - | Таймстампы загрузки/сохранения по файлам; движок инкрементальных загрузок. |

### Точность типов

Значения хранятся с тегом типа, поэтому без потерь восстанавливаются:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (вложенные).

Пользовательские классы PowerShell (не из `System.*` / `Microsoft.*`) сериализуются
с маркером `~C` и восстанавливаются при загрузке нативным C#-проходом: узлы `~C`
собираются одним обходом, каждое уникальное имя класса резолвится один раз в карту
типов, и все экземпляры реанимируются за один проход (PowerShell-fallback покрывает
конструкторы с параметрами). Сложные `System.*`-типы падают в minified CLIXML.

Маркеры JSON, используемые конвертером:

| Маркер | Восстанавливается как |
| --- | --- |
| `{"~": true, ...}` | `PSCustomObject` |
| `{"~i": true, "123": ...}` | хеш-таблица с ключами Int32 |
| `{"~D": "2024-06-15T14:30:45.1230000Z"}` | `DateTime` с точным значением и `Kind` |
| `{"~m": "999999999999999.99"}` | `decimal` с точным масштабом |
| `{"~S": "2024-06-15T..."}` | строка вида даты (никогда не превращается в `DateTime`) |
| `{"~C": "MyClass", ...}` | экземпляр вашего класса PowerShell |
| `{"__CLIXML__": "<Objs..."}` | сложные типы .NET через CLIXML |

В режиме `Xml` (CLIXML) этих маркеров нет: примитивы, `DateTime`, массивы и хеш-таблицы
проходят круг через нативную семантику `PSSerializer`, а классы PowerShell возвращаются
как `Deserialized.*`-обёртки (принятая плата совместимости).

### Архитектура

```
+-------------------+       +---------------------+
|  Поток вызова     | ----> |  Ядро HashTableDB1  |
+-------------------+       |  - MainHT           |
                            |  - UpdatesHT        |
                            |  - RemovedHT        |
                            |  - MergedHT (view)  |
                            +----------+----------+
                                       |
              +------------------------+------------------------+
              |                        |                        |
              v                        v                        v
    +-------------------+   +-------------------+   +-------------------+
    |  Async save pool  |   |  Async load pool  |   |  Async TxLog pool |
    |  RunspacePool(1,1)|   |  RunspacePool(1,1)|   |  RunspacePool(1,1)|
    +---------+---------+   +---------+---------+   +---------+---------+
              |                       |                       |
              v                       v                       v
       *_main.json              *_main.json           TxLog/*.txlog
       *_updates.json           *_updates.json
       *_deletes.json           *_deletes.json
```

*Реанимация классов идёт четвёртой фоновой операцией, переиспользуя освободившийся load-пул.*

## Производительность

Замерено комплектом тестов (`code_testing/Test-Hashtable-DB1.ps1`) в свежих процессах,
PowerShell 7, настольное железо, записи ≈ 1 КБ:

| Операция | Объём | Json (по умолчанию) | Xml (режим совместимости) |
| --- | --- | --- | --- |
| `Add` | 120 000 записей | ≈ 2.7-3.4 с | не зависит от формата* |
| `Get` | 50 000 чтений | ≈ 0.3 с | не зависит от формата* |
| Случайный `Get` | 10 000 из 100 000 | ≈ 0.05 с | не зависит от формата* |
| `SaveToDisk` | 120 000 записей (~120 МБ Json) | ≈ 0.17 с (~700 000 зап/с) | ≈ 2.4 с (≈ в 14 раз медленнее) |
| `LoadFromDisk` | 120 000 записей | ≈ 0.5 с (~240 000 зап/с) | ≈ 2.4 с (≈ в 5 раз медленнее) |
| `SaveToDiskAsync` ×2 | 120 000 записей | ≈ 0.25-0.3 с | ≈ 2.4 с |
| Пиковая транзиентная память при `SaveToDisk` | 120 000 записей | ≈ +80 МБ | ≈ +0.9 ГБ |
| `CompactDatabase` | база 100 000 записей | ≈ 0.1 мс (обмен ссылок) | так же |

\* Операции в памяти не зависят от формата хранения. Однако крупное сохранение в Xml оставляет
«осадок» в Large Object Heap (весь CLIXML-документ строится одной строкой в памяти), что может
замедлять последующие операции в памяти до усадки кучи - используйте `Json`, если CLIXML
не требуется легаси-потребителям.

---

## Асинхронные операции

HashTableDB1 содержит **четыре независимые асинхронные подсистемы**, каждая на
постоянном `RunspacePool(1,1)` с обработчиком завершения через `Register-ObjectEvent`.
Вызывающий поток **никогда не блокируется** на дисковом вводе-выводе - GUI-скрипт
остаётся отзывчивым, пока многогигабайтная база сбрасывается на диск или загружается.

| Подсистема | Точка входа | Ожидание завершения | Поле состояния |
| --- | --- | --- | --- |
| Асинхронное сохранение | `SaveToDiskAsync()` | `WaitForAsyncSaveToDisk()` | `$AsynchronousSaveOperationState` |
| Асинхронная загрузка | `LoadFromDiskAsync()` | `WaitForAsyncLoadFromDisk()` | `$AsynchronousLoadOperationState` |
| Асинхронный TxLog | `SaveTransactionLogAsync()` | `WaitForPendingTransactionLogOperations()` | `$AsynchronousTransactionLogSaveState` |
| Асинхронная реанимация классов | внутренняя: запускается обработчиком события async-load | `WaitForAsyncRehydrate()` | `$AsynchronousRehydrateOperationState` (переиспользует освободившийся load-пул) |

### Типичный асинхронный сценарий

```powershell
# 1. Запускаем фоновую загрузку - управление возвращается сразу
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = "$PWD"
$db.DatabaseFileName   = "MyDB"
$db.LoadFromDiskAsync()

# 2. Делаем что-то ещё в основном потоке (рисуем UI, парсим аргументы)
Show-SplashScreen

# 3. Блокируемся только когда данные реально нужны
$db.WaitForAsyncLoadFromDisk()
$db.Get('user')

# 4. Пишем много данных и сбрасываем в фоне
$db.Add('a', 1); $db.Add('b', 2); $db.Add('c', 3)
$db.SaveToDiskAsync()
```

### Почему это важно

- **GUI не замерзает** - обработчик `InvocationStateChanged` намеренно лёгкий;
  тяжёлая работа (десериализация, сборка `ConcurrentDictionary`, перестройка TxLog)
  выполняется *внутри* фонового runspace.
- **Атомарная подмена состояния** - `MergedHT` заменяется **последним**, поэтому
  конкурентные читатели видят старый консистентный снимок до самого конца подмены.
  Порядок присваивания: `MainHT` → `UpdatesHT` → `RemovedHT` → `MergedHT`.
- **Реанимация классов в фоне** - `LoadFromDiskAsync` собирает узлы с маркером `~C`
  в фоне (фаза 3); обработчик события резолвит каждое уникальное имя класса один раз
  в основном потоке (пользовательские классы существуют только в этой сессии) и сразу
  запускает четвёртую фоновую операцию, которая реанимирует все экземпляры одним
  нативным проходом - основной поток не замирает даже на больших данных с классами.
  Если маркеров `~C` не было, обход полностью пропускается.
- **Ограниченные ожидания** - каждый `WaitFor*` использует `LockFileMaxWaitTime`
  (по умолчанию **30 с**); по таймауту runspace принудительно убивается, а пул
  пересоздаётся при следующем вызове.
- **Самовосстановление** - «плохие» состояния `PSEventJob` (`Failed`, `Blocked`)
  обнаруживаются и чистятся автоматически через `CleanupAsync`. Ошибки из
  `HadErrors` выводятся через `writeAsyncInstanceErrors` с категорией, ID и
  стеком вызовов.
- **Постоянные пулы** - `RunspacePool` создаётся один раз и переиспользуется
  во всех вызовах, что избавляет от холодного старта на каждом save / load / TxLog.

### Обработка ошибок в async

Каждое действие оборачивает `EndInvoke` в `try / catch / finally`:

```powershell
try   { $null = $PSInstance.EndInvoke($asyncResult) }
catch { $thisObj.ErrorLevel = "STXASNC1"; $thisObj.ErrorText = $_.Exception.Message }
finally { [HashTableDB1]::CleanupAsync([ref]$thisObj.AsynchronousSaveOperationState) }
```

`CleanupAsync` выполняет ограниченную синхронную остановку (максимум 3 с в
состоянии `Stopping`), dispose `PSInstance`, снимает событие и обнуляет ссылки,
чтобы пул был пересоздан при следующей операции.

---

## Транзакционный лог (TxLog)

TxLog - это **опциональный append-only журнал**, фиксирующий последнюю операцию
по каждому ключу (`Add` / `Remove` / вложенные upsert'ы) с монотонно возрастающим
тиком и значением, захваченным в момент операции. Предназначен для
**синхронизации реплик** и **восстановления после сбоев** (последний снимок + хвост журнала).

Включается один раз на стороне писателя:

```powershell
$db.EnableTransactionLog   = $true
$db.TxLogRetentionDays     = 7      # автоудаление файлов старше 7 дней
# $db.TxLogFlushToDisk     = $true  # опционально: fsync каждого txlog-файла (критично для восстановления)
$db.DatabaseFolderPath     = "$PWD"
```

### Что записывается

На каждую пачку изменений создаётся файл в `TxLog/`:

```
<DatabaseFileName>_<firstTick>_<lastTick>.txlog
```

Содержимое - компактный JSON-массив кортежей `[op, key, value, tick]`:

```json
[
  ["A", "user:42", { "name": "Alice" }, 133712345678901234],
  ["R", "user:17", null,                133712345678902345]
]
```

- `op` - `"A"` (add/update) или `"R"` (remove)
- `value` - значение, захваченное в момент регистрации операции, для `"A"`; `null` для `"R"` (точная replay-запись, никогда не перечитывается из merged-представления)
- `tick` - монотонный тик внутреннего `TxTickGenerator` (на основе wall-clock, CAS-зажат поверх всех ранее выданных тиков - неуязвим к прыжкам часов назад)

Файлы пишутся атомарно: данные уходят в `<имя>.txlog.tmp` и переименовываются только
после успешной сериализации, поэтому краш не может оставить битый `.txlog` - диапазоны
файлов строго возрастают и не пересекаются.

Писатель также поддерживает in-memory состояние:

| Поле | Тип | Назначение |
| --- | --- | --- |
| `KeyToTx` | `ConcurrentDictionary[string, object]` | Последняя запись `(tick, op, value)` по ключу, захваченная в момент операции. Lock-free; одновременно служит учётом last-writer-wins для синхронизации. Ограничена числом различных ключей, обрезается после каждого успешного сброса. |
| `TxTickGenerator` | C#-класс (hidden) | Монотонный источник тиков (CAS-зажатый wall-clock). При загрузке поднимается выше watermark'а сохранённого состояния, чтобы реплика с отстающими часами не выдавала тики ниже только что загруженного состояния. |
| `TxLogSaveLock` | `object` (hidden) | Сериализует sync- и async-запуски scriptblock'а сброса TxLog. |
| `LastTransactionLogSavedTimestamp` | `long` | High-water mark: при следующем сбросе пишутся только записи с более новым тиком. |
| `LastTxLogTick` | `long` | Последний тик, записанный в txlog-файл. |

### Watermark сохранённого состояния (позиция replay)

Каждое сохранение пишет `___DBSTATEASTOFTICK___` в deletes-файл: все операции с
`tick <= DbStateAsOfTick` уже отражены в сохранённых файлах `main` / `updates` /
`deletes`. Свойство публикуется при save и восстанавливается при load.
**Replay/sync должны применять только записи txlog с более новым тиком** - это делает
восстановление детерминированным:

1. Загрузить файлы БД (watermark приходит вместе с ними).
2. Читать `TxLog/*.txlog` по возрастанию `firstTick` (диапазоны - в именах файлов).
3. Целиком пропускать файлы с `lastTick <= DbStateAsOfTick`; применять по-записно
   `tick > watermark` как `"A" -> Add(key, value)` / `"R" -> Remove(key)`
   (идемпотентно, last-writer-wins по тику).

Референсная реализация алгоритма - хелпер `Invoke-TxLogReplay` в тестовом наборе
(тест 15). При применении **чужого** журнала реплики не прогоняйте записи через
`Add`/`Remove` своего экземпляра-писателя - это перерегистрирует операции в вашем
TxLog и создаст эхо; пишите в словари напрямую.

### Хранение и очистка

`SaveTxLogScriptBlock` чистит при каждом успешном сбросе:

1. **Обрезка in-memory** - удаляются все записи `KeyToTx` с `tick <= lastTick`
   записанного файла, поэтому память держит только *несохранённую* дельту,
   а не окно retention всей истории. Безопасно по построению: новые тики выдаются
   строго выше watermark'а генератора, поэтому конкурентно зарегистрированная
   операция не может быть обрезана.
2. **GC осиротевших `.tmp`** - оставшиеся после крашей `<имя>_*_*.txlog.tmp` старше
   1 часа удаляются (возраст учитывает чужого параллельного писателя).
3. **Retention на диске** - файлы `.txlog`, сопоставленные регуляркой по имени,
   удаляются, если `GetLastWriteTime < cutoff` (3 попытки при `IOException`).

`LastTransactionLogSavedTimestamp` (high-water mark) и `LastTxLogTick` продвигаются
только после успешного коммита; при любой ошибке дельта остаётся в памяти, и следующий
сброс перезапишет тот же диапазон тиков под тем же именем файла (идемпотентная
перезапись).

### Чем полезен TxLog

| Без TxLog | С TxLog |
| --- | --- |
| Реплике нужно перезагрузить всю БД | Реплика проигрывает только дельты |
| Восстановление = последний полный снимок | Восстановление = снимок + хвост журнала |
| Нет аудита | Каждое изменение с меткой времени |
| Конфликты скрыты | Last-writer-wins явный и воспроизводимый |
| Диск растёт вместе с полной БД | Диск ограничен политикой хранения |

Журнал **append-only**, поэтому запись последовательная и быстрая; политика
хранения ограничивает занимаемое место без вмешательства оператора.

### Производительность TxLog

- Регистрация **lock-free**: одна аллокация закрытого generic `Tuple(tick, op, value)`
  и одна перезапись `ConcurrentDictionary` на операцию (~1 мкс), без обёртки
  `PSObject` и без блокировок на hot-path записи.
- Сбор дельты - один нативный C#-проход по `KeyToTx` (фильтр по cutoff, сборка списка
  записей, min/max тики для имени файла) - без PowerShell-циклов и без копии под локом.
- Память ограничена *числом изменённых ключей с последнего сброса* (обрезка после
  каждой успешной записи), а не окном retention.
- Писатель TxLog работает в отдельном `RunspacePool(1,1)`, поэтому сохранение
  основной БД и сброс TxLog могут идти **параллельно**. Sync- и async-сбросы
  взаимно исключаются `TxLogSaveLock`.
- Тестовый набор выполняется с включённым TxLog, поэтому тайминги in-memory
  в таблице производительности уже включают накладные регистрации.

---

## Бэкапы и восстановление

### Ротация бэкапов

Когда `NumOfDbBackupsToKeep > 0`, каждое успешное сохранение переносит
предыдущие `*_main.json`, `*_updates.json`, `*_deletes.json` в подпапку `OLD/`
с суффиксом `yyyyMMdd-HHmmss`:

```
OLD/MyDB_main.20260115-134501
OLD/MyDB_updates.20260115-134501
OLD/MyDB_deletes.20260115-134501
```

Политику хранения обеспечивает `_MoveOld`: сортирует бэкапы лексикографически
(в порядке timestamp) и удаляет самые старые излишки. Все файловые операции
используют `_RetryFileOp` - 5 попыток с задержкой 100 мс при `IOException` /
`UnauthorizedAccessException` (антивирусы, индексаторы и т. п.).

### Автоматическое восстановление

При загрузке, если основной файл отсутствует или повреждён, загрузчик пробует
варианты `.tmp` и `.old` по порядку. Каждый кандидат валидируется полной
десериализацией, прежде чем быть повышен до основного, поэтому повреждённый
`.tmp` никогда не перезапишет хороший `.old`:

```
*_main.json   →   *_main.json.tmp   →   *_main.json.old
*_updates.json →  *_updates.json.tmp →  *_updates.json.old
*_deletes.json →  *_deletes.json.tmp →  *_deletes.json.old
```

Legacy `.xml` из старых версий обрабатываются прозрачно, а свойство `StorageFormat`
управляет тем, какой формат записывается:

- Файлы выбираются с приоритетом JSON: если `<file>_main.json` нет, но `<file>_main.xml`
  есть - XML загружается через `PSSerializer.Deserialize`.
- Миграция между форматами автоматическая в обе стороны: после загрузки файлов, формат
  которых отличается от `StorageFormat`, база пересохраняется в настроенном формате, а
  файлы старого формата уходят в `OLD/` (если включены бэкапы) или удаляются - в папке
  всегда ровно один формат.
- `StorageFormat = 'Xml'` (режим совместимости CLIXML) продолжает писать классический
  XML `PSSerializer` для легаси-потребителей, которые не умеют читать JSON.

### Коды ошибок

| Код | Значение |
| --- | --- |
| `LFX1` | Основной файл БД не существует (первый запуск - считается нормой). |
| `LFX2` | Основная БД повреждена, валидный fallback не найден. |
| `LFX4` | Updates-БД повреждена, валидный fallback не найден. |
| `LFX6` | Deletes-БД повреждена, валидный fallback не найден. |
| `LFX8` | Неожиданная ошибка загрузки. |
| `STX1` | Синхронное сохранение не удалось. |
| `STXT1` | Синхронный сброс TxLog не удался. |
| `STXASNC1` | `EndInvoke` асинхронного сохранения бросил исключение. |
| `TXLOG2` | `EndInvoke` асинхронного TxLog бросил исключение. |
| `TXLOG3` | Не удалось запустить асинхронный сброс TxLog. |
| `RHYD1` | Не удалось запустить асинхронную реанимацию классов. |
| `RHYD2` | `EndInvoke` асинхронной реанимации классов бросил исключение. |
| `ALOAD1` | Не удалось запустить асинхронную загрузку. |
| `ALOAD2` | `EndInvoke` асинхронной загрузки вернул пустой вывод. |
| `EDBFP1` | Не удалось обеспечить папку БД с правами. |

### Тестирование

```powershell
# Комплект тестов - обычный скрипт (не Pester), запускать в свежем процессе
pwsh -NoProfile -File ./code_testing/Test-Hashtable-DB1.ps1
```

Переменная `$StorageFormatToTest` в начале скрипта задаёт формат для тестов
сохранения/загрузки (`'json'` или `'xml'`). Ожидается: **15 / 15 passed** в режиме Json;
в режиме Xml тест 14 (маркеры точности типов JSON) пропускается по замыслу, а тест 15
(корректность TxLog, watermark и replay-восстановление) форматонезависим и выполняется
всегда.

### Лицензия

MIT - см. [LICENSE](LICENSE).