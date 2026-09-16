# HashTableDB1

<p align="center">
  <b>Persistent, thread-safe key-value database for PowerShell</b><br>
  <i>JSON storage &bull; asynchronous I/O &bull; exact type fidelity &bull; transaction log &bull; zero dependencies</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell" alt="PowerShell 7+">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="No dependencies">
  <img src="https://img.shields.io/badge/tests-14%2F14%20passed-brightgreen" alt="Tests">
  <img src="https://img.shields.io/badge/storage-JSON%20%2F%20CLIXML-informational" alt="JSON / CLIXML storage">
  <img src="https://img.shields.io/badge/TxLog-optional-blueviolet" alt="Transaction log">
</p>

<p align="center"><a href="#english">English</a> &bull; <a href="#russian">Русский</a></p>

---

<a id="english"></a>
## 🇬🇧 English

### Overview

**HashTableDB1** is a lightweight, dependency-free, persistent key-value store written in pure PowerShell 7+. It saves data to JSON files (or classic CLIXML XML in compatibility mode), supports asynchronous flushing and loading, and preserves exact .NET types via an internal type-tagging mechanism. It also ships with an optional append-only **transaction log (TxLog)** for replica synchronisation and point-in-time recovery.

### Features

- **Persistent** - data survives process restarts (JSON on disk).
- **Thread-safe** - lock-free reads over `ConcurrentDictionary`; writes use CAS retry loops, TxLog state is guarded by `[System.Threading.Monitor]`.
- **Asynchronous I/O** - three independent background subsystems (save, load, TxLog) run inside persistent `RunspacePool(1,1)` instances and never block the caller.
- **Type fidelity** - integers, longs, doubles, booleans, dates, GUIDs, arrays and nested hashtables round-trip exactly.
- **Transaction log** - optional append-only journal of every `Add` / `Remove` with `FileTimeUtc` ticks.
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
| `LoadFromDiskAsync()` | Asynchronous load; class rehydration happens on the main thread. |
| `UpsertNestedHashTableKey($Key, $SubKey, $Value)` | Atomic (CAS-retried) upsert of a secondary key inside a hashtable record. |
| `RemoveNestedHashTableKey($Key, $SubKey)` | Removes a secondary key; removes the record when it becomes empty. |
| `SaveTransactionLogAsync()` | Writes unsaved operation deltas to `TxLog/*.txlog` in the background. |
| `WaitForAsyncSaveToDisk()` / `WaitForAsyncLoadFromDisk()` / `WaitForPendingTransactionLogOperations()` | Block until the corresponding async operation completes. |
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
| `TxLogRetentionDays` | `3` | Retention window for `.txlog` files and in-memory tick state. |
| `LockFileMaxWaitTime` | `30` | Max seconds to wait for a stuck async operation before force-kill. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Result of the last operation: `0` = success, string code = error. |
| `MainFileLoadedDT` / `UpdatesFileLoadedDT` / `RemovedFileLoadedDT` | - | Per-file load/save timestamps; drive incremental loads (unchanged files are skipped). |

### Type fidelity

Values are stored with a type tag, so these round-trip exactly:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (nested).

PowerShell classes (user-defined, non-`System.*` / non-`Microsoft.*` namespaces) are serialized with a `~C` marker and rehydrated by `HashtableDB1Class_RestoreClassesScriptBlock` on load. Complex `System.*` types fall back to minified CLIXML.

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

## Performance

Measured by the bundled suite (`code_testing/Test-Hashtable-DB1.ps1`) in fresh processes,
PowerShell 7, desktop hardware, records ≈ 1 KB:

| Operation | Volume | Json (default) | Xml (compatibility mode) |
| --- | --- | --- | --- |
| `Add` | 120 000 records | ≈ 3.2-3.7 s | format-independent* |
| `Get` | 50 000 lookups | ≈ 0.43 s | format-independent* |
| Random `Get` | 10 000 of 100 000 | ≈ 0.10 s | format-independent* |
| `SaveToDisk` | 120 000 records (~120 MB Json) | ≈ 0.21 s (~570 000 rec/s) | ≈ 2.4 s (~11× slower) |
| `LoadFromDisk` | 120 000 records | ≈ 0.79 s (~152 000 rec/s) | ≈ 2.4 s (~3× slower) |
| `SaveToDiskAsync` ×2 | 120 000 records | ≈ 0.29 s | ≈ 2.4 s |
| Peak transient memory on `SaveToDisk` | 120 000 records | ≈ +80 MB | ≈ +0.9 GB |
| `CompactDatabase` | 100 000-record base | ≈ 0.1 ms (reference swap) | same |

\* In-memory operations do not depend on the storage format. However, a large Xml save leaves
Large Object Heap residue (the whole CLIXML document is built as a single in-memory string),
which can slow down subsequent in-memory work until the heap is trimmed - prefer `Json`
unless legacy consumers require CLIXML.

---

## Asynchronous operations

HashTableDB1 ships **three independent async subsystems**, each backed by its own
persistent `RunspacePool(1,1)` and a `Register-ObjectEvent`-driven completion handler.
The caller thread **never blocks** on disk I/O - GUI scripts stay responsive while
multi-hundred-MB databases are being flushed or loaded.

| Subsystem | Entry point | Completion wait | Backing field |
| --- | --- | --- | --- |
| Async save | `SaveToDiskAsync()` | `WaitForAsyncSaveToDisk()` | `$AsynchronousSaveOperationState` |
| Async load | `LoadFromDiskAsync()` | `WaitForAsyncLoadFromDisk()` | `$AsynchronousLoadOperationState` |
| Async TxLog | `SaveTransactionLogAsync()` | `WaitForPendingTransactionLogOperations()` | `$AsynchronousTransactionLogSaveState` |

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
- **Lightweight rehydration on the main thread** - `LoadFromDiskAsync` collects
  `~C` marker nodes in the background (Phase 3), then the event action rehydrates them
  in reverse DFS order so nested instances exist before their containers copy them out
  of raw hashtables. If no `~C` markers were seen, the traversal is skipped entirely.
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

The TxLog is an **opt-in append-only journal** that records every `Add` / `Remove`
with a monotonically increasing `FileTimeUtc` tick. It is designed for
**replica synchronisation** and **point-in-time recovery**.

Enable it once on the writer side:

```powershell
$db.EnableTransactionLog   = $true
$db.TxLogRetentionDays     = 7      # auto-delete files older than 7 days
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
- `value` - actual value for `"A"`, `null` for `"R"`
- `tick` - `DateTime.UtcNow.ToFileTimeUtc()`

The writer also maintains two in-memory indexes:

| Field | Type | Purpose |
| --- | --- | --- |
| `KeyToTick` | `ConcurrentDictionary[string, long]` | Last tick per key, for retention pruning. |
| `TickToKeys` | `SortedDictionary[long, List<Tuple<string,string>>]` | Chronological order of `(key, op)` entries. |

`TickToKeys` is guarded by `TickToKeysLock` (`[System.Threading.Monitor]`) because
`SortedDictionary` is not thread-safe. `KeyToTick` is a `ConcurrentDictionary` and
needs no external lock.

### Retention & cleanup

`SaveTxLogScriptBlock` performs **three cleanup passes** on every flush:

1. `KeyToTick` - drop keys whose last tick is older than the retention window.
2. `TickToKeys` - drop tick buckets older than the window (under `TickToKeysLock`).
3. On-disk `.txlog` files - regex-matched by name and deleted if
   `GetLastWriteTime < cutoff` (3 retry attempts on `IOException`).

`LastTransactionLogSavedTimestamp` tracks the high-water mark so only **new** deltas
are written on the next flush. `LastTxLogTick` is retained for external API
compatibility.

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

- Entries are stored as `[System.Tuple]::Create($key, $op)` - direct .NET allocation
  without `PSObject` wrapping, significantly faster than hashtable literals on bulk deltas.
- `KeyToTick` is a `ConcurrentDictionary`; `TickToKeys` is a `SortedDictionary`
  guarded by a single `Monitor` lock - one lock acquisition per batch, not per key.
- The TxLog writer runs in its own `RunspacePool(1,1)`; a save of the main DB and a
  TxLog flush can run **concurrently**.

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
| `ALOAD1` | Failed to start async load. |
| `ALOAD2` | Async load `EndInvoke` returned no output. |
| `EDBFP1` | Failed to ensure DB folder with permissions. |

### Testing

```powershell
# The suite is a plain script (not Pester) - run it in a fresh process
pwsh -NoProfile -File ./code_testing/Test-Hashtable-DB1.ps1
```

The `$StorageFormatToTest` variable at the top of the script selects the storage format for
save/load tests (`'json'` or `'xml'`). Expected: **14 / 14 passed** in Json mode; in Xml mode
Test 14 (JSON type-fidelity markers) is skipped by design.

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
восстановления на момент времени.

### Возможности

- **Персистентность** - данные переживают перезапуск процесса (JSON на диске).
- **Потокобезопасность** - чтение без блокировок поверх `ConcurrentDictionary`; записи через CAS-повторы, состояние TxLog защищено `[System.Threading.Monitor]`.
- **Асинхронный ввод-вывод** - три независимые фоновые подсистемы (save, load, TxLog) работают в постоянных `RunspacePool(1,1)` и не блокируют вызывающий поток.
- **Точность типов** - целые, длинные, дробные, логические, даты, GUID, массивы и вложенные хеш-таблицы восстанавливаются без потерь.
- **Транзакционный лог** - опциональный append-only журнал всех `Add` / `Remove` с тиками `FileTimeUtc`.
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
| `LoadFromDiskAsync()` | Асинхронная загрузка; рехидратация классов - в основном потоке. |
| `UpsertNestedHashTableKey($Key, $SubKey, $Value)` | Атомарный (CAS-повторы) upsert вторичного ключа внутри записи-хеш-таблицы. |
| `RemoveNestedHashTableKey($Key, $SubKey)` | Удаляет вторичный ключ; удаляет запись, когда она опустела. |
| `SaveTransactionLogAsync()` | Фоновая запись несохранённых дельт операций в `TxLog/*.txlog`. |
| `WaitForAsyncSaveToDisk()` / `WaitForAsyncLoadFromDisk()` / `WaitForPendingTransactionLogOperations()` | Блокируются до завершения соответствующей async-операции. |
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
| `TxLogRetentionDays` | `3` | Окно хранения `.txlog`-файлов и тиков в памяти. |
| `LockFileMaxWaitTime` | `30` | Максимум секунд ожидания зависшей async-операции до принудительного завершения. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Результат последней операции: `0` = успех, строковый код = ошибка. |
| `MainFileLoadedDT` / `UpdatesFileLoadedDT` / `RemovedFileLoadedDT` | - | Таймстампы загрузки/сохранения по файлам; движок инкрементальных загрузок. |

### Точность типов

Значения хранятся с тегом типа, поэтому без потерь восстанавливаются:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (вложенные).

Пользовательские классы PowerShell (не из `System.*` / `Microsoft.*`) сериализуются
с маркером `~C` и восстанавливаются через `HashtableDB1Class_RestoreClassesScriptBlock`.
Сложные `System.*`-типы падают в minified CLIXML.

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

## Производительность

Замерено комплектом тестов (`code_testing/Test-Hashtable-DB1.ps1`) в свежих процессах,
PowerShell 7, настольное железо, записи ≈ 1 КБ:

| Операция | Объём | Json (по умолчанию) | Xml (режим совместимости) |
| --- | --- | --- | --- |
| `Add` | 120 000 записей | ≈ 3.2-3.7 с | не зависит от формата* |
| `Get` | 50 000 чтений | ≈ 0.43 с | не зависит от формата* |
| Случайный `Get` | 10 000 из 100 000 | ≈ 0.10 с | не зависит от формата* |
| `SaveToDisk` | 120 000 записей (~120 МБ Json) | ≈ 0.21 с (~570 000 зап/с) | ≈ 2.4 с (≈ в 11 раз медленнее) |
| `LoadFromDisk` | 120 000 записей | ≈ 0.79 с (~152 000 зап/с) | ≈ 2.4 с (≈ в 3 раза медленнее) |
| `SaveToDiskAsync` ×2 | 120 000 записей | ≈ 0.29 с | ≈ 2.4 с |
| Пиковая транзиентная память при `SaveToDisk` | 120 000 записей | ≈ +80 МБ | ≈ +0.9 ГБ |
| `CompactDatabase` | база 100 000 записей | ≈ 0.1 мс (обмен ссылок) | так же |

\* Операции в памяти не зависят от формата хранения. Однако крупное сохранение в Xml оставляет
«осадок» в Large Object Heap (весь CLIXML-документ строится одной строкой в памяти), что может
замедлять последующие операции в памяти до усадки кучи - используйте `Json`, если CLIXML
не требуется легаси-потребителям.

---

## Асинхронные операции

HashTableDB1 содержит **три независимые асинхронные подсистемы**, каждая со своим
постоянным `RunspacePool(1,1)` и обработчиком завершения через `Register-ObjectEvent`.
Вызывающий поток **никогда не блокируется** на дисковом вводе-выводе - GUI-скрипт
остаётся отзывчивым, пока многогигабайтная база сбрасывается на диск или загружается.

| Подсистема | Точка входа | Ожидание завершения | Поле состояния |
| --- | --- | --- | --- |
| Асинхронное сохранение | `SaveToDiskAsync()` | `WaitForAsyncSaveToDisk()` | `$AsynchronousSaveOperationState` |
| Асинхронная загрузка | `LoadFromDiskAsync()` | `WaitForAsyncLoadFromDisk()` | `$AsynchronousLoadOperationState` |
| Асинхронный TxLog | `SaveTransactionLogAsync()` | `WaitForPendingTransactionLogOperations()` | `$AsynchronousTransactionLogSaveState` |

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
- **Лёгкая рехидратация в основном потоке** - `LoadFromDiskAsync` собирает узлы
  с маркером `~C` в фоне (фаза 3), а затем обработчик события восстанавливает их
  в обратном DFS-порядке, чтобы вложенные экземпляры существовали раньше, чем их
  контейнеры скопируют их из сырых хеш-таблиц. Если маркеров `~C` не было,
  обход полностью пропускается.
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

TxLog - это **опциональный append-only журнал**, фиксирующий каждую операцию
`Add` / `Remove` с монотонно возрастающим тиком `FileTimeUtc`. Предназначен для
**синхронизации реплик** и **восстановления на момент времени**.

Включается один раз на стороне писателя:

```powershell
$db.EnableTransactionLog   = $true
$db.TxLogRetentionDays     = 7      # автоудаление файлов старше 7 дней
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
- `value` - фактическое значение для `"A"`, `null` для `"R"`
- `tick` - `DateTime.UtcNow.ToFileTimeUtc()`

Писатель также поддерживает два in-memory индекса:

| Поле | Тип | Назначение |
| --- | --- | --- |
| `KeyToTick` | `ConcurrentDictionary[string, long]` | Последний тик по ключу - для обрезки по retention. |
| `TickToKeys` | `SortedDictionary[long, List<Tuple<string,string>>]` | Хронологический порядок записей `(key, op)`. |

`TickToKeys` защищён `TickToKeysLock` (`[System.Threading.Monitor]`), потому что
`SortedDictionary` не потокобезопасен. `KeyToTick` - `ConcurrentDictionary`,
внешняя блокировка не нужна.

### Хранение и очистка

`SaveTxLogScriptBlock` выполняет **три прохода очистки** при каждом сбросе:

1. `KeyToTick` - удаляются ключи, последний тик которых старше окна хранения.
2. `TickToKeys` - удаляются бакеты тиков старше окна (под `TickToKeysLock`).
3. Файлы `.txlog` на диске - сопоставляются регуляркой и удаляются, если
   `GetLastWriteTime < cutoff` (3 попытки при `IOException`).

`LastTransactionLogSavedTimestamp` хранит high-water mark, поэтому при следующем
сбросе пишутся только **новые** дельты. `LastTxLogTick` сохранён для совместимости
с внешним API.

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

- Записи хранятся как `[System.Tuple]::Create($key, $op)` - прямая аллокация .NET
  без обёртки `PSObject`, что значительно быстрее хеш-табличных литералов на
  массовых дельтах.
- `KeyToTick` - `ConcurrentDictionary`; `TickToKeys` - `SortedDictionary` под
  одним `Monitor`-локом: одно взятие блокировки на пачку, а не на ключ.
- Писатель TxLog работает в отдельном `RunspacePool(1,1)`, поэтому сохранение
  основной БД и сброс TxLog могут идти **параллельно**.

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
| `ALOAD1` | Не удалось запустить асинхронную загрузку. |
| `ALOAD2` | `EndInvoke` асинхронной загрузки вернул пустой вывод. |
| `EDBFP1` | Не удалось обеспечить папку БД с правами. |

### Тестирование

```powershell
# Комплект тестов - обычный скрипт (не Pester), запускать в свежем процессе
pwsh -NoProfile -File ./code_testing/Test-Hashtable-DB1.ps1
```

Переменная `$StorageFormatToTest` в начале скрипта задаёт формат для тестов
сохранения/загрузки (`'json'` или `'xml'`). Ожидается: **14 / 14 passed** в режиме Json;
в режиме Xml тест 14 (маркеры точности типов JSON) пропускается по замыслу.

### Лицензия

MIT - см. [LICENSE](LICENSE).