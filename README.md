Готово. Полный `README.md` ниже — двуязычный, с навигацией между языками через якоря. Скопируйте содержимое целиком в файл `README.md` в корне репозитория.

````markdown
# HashTableDB1

<p align="center">
  <b>Persistent, thread-safe key–value database for PowerShell</b><br>
  <i>JSON storage &bull; asynchronous I/O &bull; exact type fidelity &bull; zero dependencies</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell" alt="PowerShell 7+">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="No dependencies">
  <img src="https://img.shields.io/badge/tests-14%2F14%20passed-brightgreen" alt="Tests">
  <img src="https://img.shields.io/badge/storage-JSON-informational" alt="JSON storage">
</p>

<p align="center"><a href="#english">🇬🇧 English</a> &nbsp;&bull;&nbsp; <a href="#russian">🇷🇺 Русский</a></p>

---

<a name="english"></a>

## 📘 English

### Contents
- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Public API](#public-api)
- [Properties](#properties)
- [Usage Examples](#usage-examples)
- [Storage Format](#storage-format)
- [Data Type Fidelity](#data-type-fidelity)
- [Performance](#performance)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)

### Features

- **Thread-safe by design** — live collections are `ConcurrentDictionary`; writes use CAS retry loops, TxLog state is monitor-protected.
- **Non-blocking persistence** — save and load run in background runspaces; the main thread (and your GUI) never freezes. Wait/poll helpers included.
- **Exact type fidelity** — `DateTime` (incl. `Kind`), Int32-keyed hashtables, `decimal` scale, date-shaped strings, `PSCustomObject` **and your own PowerShell classes** survive the JSON round-trip.
- **Incremental saves** — between consolidations only `*_updates.json` and `*_deletes.json` are rewritten; a full save happens automatically when pending changes exceed 30% of the main DB.
- **Crash-resistant writes** — `.tmp` → atomic rename swap, `.old` one-step rollback, timestamped backups with configurable retention, automatic recovery of corrupted files.
- **Fast** — custom C# `System.Text.Json` converter streams ≈ 760 MB/s on save.
- **Readable storage** — plain JSON instead of opaque CLIXML; legacy `.xml` databases are read and migrated automatically.
- **Transaction log** — append-only `.txlog` operation deltas for server-to-server replication.
- **Shared-folder support** — a single call grants a SID read or read+write access to the DB folder.
- **Zero dependencies** — one file: `HashTableDB1-Class.ps1`.

### Requirements

- **PowerShell 7.0+** (relies on `System.Text.Json`; Windows PowerShell 5.1 is not supported).
- Storage is cross-platform; the ACL helper (`EnsureDBFolderWithPermissions`) is Windows-only.

### Quick Start

```powershell
. "$PSScriptRoot\inc\HashtableDB1-Class.ps1"   # dot-source once: [HashTableDB1] is now available

$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = 'C:\Data\MyDB'   # folder is created automatically on save
$db.DatabaseFileName   = 'Users'          # files: Users_main.json, Users_updates.json, Users_deletes.json
$db.NumOfDbBackupsToKeep = 5              # keep 5 timestamped backups in OLD\

$db.Add('user42', @{ Name = 'John'; Roles = @('admin', 'dev') })
$db.Get('user42').Name        # John
$db.ContainsKey('user42')     # True

$db.SaveToDisk()
```

Reload later — same or another session:

```powershell
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = 'C:\Data\MyDB'
$db.DatabaseFileName   = 'Users'
$db.LoadFromDisk()             # True
$db.Get('user42').Roles[0]    # admin
```

### Public API

**Data operations**

| Method | Description |
|---|---|
| `Add($key, $value)` | Adds or updates a record. |
| `Remove($key)` | Removes a record (writes a tombstone). |
| `Get($key)` | Returns the record value, or `$null` if the key is missing. |
| `GetAllKeys()` | All keys of the merged view. |
| `GetAllValues()` | All values of the merged view. |
| `ContainsKey($key)` | `True` if the key exists. |
| `Clone()` | Shallow snapshot of the merged view as a plain `hashtable`. |
| `UpsertNestedHashTableKey($key, $subKey, $subValue = 1)` | Atomic upsert of a secondary key inside a hashtable record (CAS-retried). |
| `RemoveNestedHashTableKey($key, $subKey)` | Removes a secondary key; removes the record when it becomes empty. |
| `GetPendingChangesCount()` | Number of unsaved updates + tombstones. |
| `CreateEmptyDB()` | Resets the database to an empty state. |

**Persistence**

| Method | Description |
|---|---|
| `SaveToDisk()` | Synchronous save. Auto-consolidates when changes exceed 30% of the main DB. |
| `SaveToDiskAsync()` | Save in a background runspace — returns immediately. |
| `WaitForAsyncSaveToDisk()` | Blocks until the running async save completes. |
| `LoadFromDisk()` | Synchronous load. `$true` = data was re-read; `$false` = nothing new (not an error). Unchanged files are skipped by timestamp. |
| `LoadFromDiskAsync()` | Load in a background runspace (deserialization included). |
| `WaitForAsyncLoadFromDisk()` | Blocks until the running async load completes. |
| `CompactDatabase()` | Merges updates/deletes into the main DB (O(1) reference swap); forces a full save next time. |
| `SaveTransactionLogAsync()` | Writes the unsaved operation delta to `TxLog\*.txlog` asynchronously. |
| `WaitForPendingTransactionLogOperations()` | Blocks until the running TxLog save completes. |
| `EnsureDBFolderWithPermissions($SID, $AllowWrite = $false)` | Creates the DB folder and grants a SID read or read+write access. |
| `Dispose()` | Waits for all async operations, releases runspaces, pools and memory. |

### Properties

| Property | Default | Description |
|---|---|---|
| `DatabaseFolderPath` | `".\"` | Storage folder (created on save). |
| `DatabaseFileName` | `"HashTableDB"` | Base name for the three files. |
| `NumOfDbBackupsToKeep` | `0` | Timestamped backups kept in `OLD\` (0 = none). |
| `DatabaseParamsHT` | `@{}` | Arbitrary user parameters persisted together with the DB. |
| `ReadOnlyMode` | `$false` | Blocks all write operations. |
| `EnableTransactionLog` | `$false` | Enables the transaction log. |
| `TxLogRetentionDays` | `3` | Days to keep `.txlog` files and in-memory tick state. |
| `LockFileMaxWaitTime` | `30` | Max seconds to wait for a stuck async operation before force-killing it. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Result of the last operation: `0` = success, string code = error. |
| `IsForceSaveMain` | `$false` | Forces a full (main file) save on the next save call. |
| `MainFileLoadedDT` `UpdatesFileLoadedDT` `RemovedFileLoadedDT` | — | Last load/save timestamps per file; drive incremental loads. |
| `DatabaseReadAccessControlListIdentifiers` | `$null` | Reserved: SIDs for read access. |
| `CurrentBackupNumber` | `0` | Diagnostic counter of backup rotations. |
| `MainHT` `UpdatesHT` `MergedHT` `RemovedHT` | — | Live `ConcurrentDictionary` views. **Read-only usage; never modify directly.** |

### Usage Examples

**Async save without freezing the UI:**

```powershell
$db.SaveToDiskAsync()          # returns immediately

# ...your GUI / main loop keeps running...

$db.WaitForAsyncSaveToDisk()   # optional explicit barrier

# or poll the synchronized result
do { Start-Sleep -Milliseconds 200 } while (-not $db.AsyncResults.ContainsKey('Success'))
if (-not $db.AsyncResults['Success']) { throw $db.AsyncResults['Message'] }
```

**Async preload of a large database:**

```powershell
$db.LoadFromDiskAsync()        # deserialization runs in the background

# ...show a splash screen / keep serving reads from the old snapshot...

$db.WaitForAsyncLoadFromDisk()
```

**Nested hashtables (atomic sub-key updates):**

```powershell
$db.UpsertNestedHashTableKey('user42', 'LastLogin', (Get-Date))
$db.UpsertNestedHashTableKey('user42', 'LoginCount', 1)
$db.Get('user42').LoginCount            # 1

$db.RemoveNestedHashTableKey('user42', 'LastLogin')
```

**Custom parameters travel with the database:**

```powershell
$db.DatabaseParamsHT['SchemaVersion'] = 3
$db.SaveToDisk()

# ...after LoadFromDisk() in any session:
$db.DatabaseParamsHT['SchemaVersion']   # 3
```

**Transaction log (replication / audit):**

```powershell
$db.EnableTransactionLog = $true
$db.TxLogRetentionDays    = 7

$db.Add('user43', @{ Name = 'Ann' })
$db.Remove('user42')

$db.SaveToDiskAsync()   # also flushes the TxLog delta asynchronously
# -> TxLog\Users_<firstTick>_<lastTick>.txlog
#    [["A","user43",{...},tick],["R","user42",null,tick]]
```

**Folder permissions for a shared DB:**

```powershell
$db.EnsureDBFolderWithPermissions('S-1-5-21-...', $false)  # read only
$db.EnsureDBFolderWithPermissions('S-1-5-21-...', $true)  # read + write
```

### Storage Format

```
C:\Data\MyDB\
├── Users_main.json          # full database (rewritten only on consolidation)
├── Users_updates.json       # changed keys since the last full save
├── Users_deletes.json       # removed keys + ___DATABASEPARAMS___ (DB params)
├── Users_*.old              # previous versions (one-step rollback)
├── OLD\                     # timestamped backups, rotated by NumOfDbBackupsToKeep
│   └── Users_main.20260915-073016
└── TxLog\
    └── Users_<firstTick>_<lastTick>.txlog
```

**Save algorithm:** serialize to `*.tmp` → rename current `*.json` to `*.old` → rename `*.tmp` to `*.json` (retried on IO contention) → move `*.old` into `OLD\` with a timestamp and rotate the excess.

**Load algorithm:** files whose `LastWriteTime` is not newer than the stored `*FileLoadedDT` are skipped entirely. A missing `main.json` is restored from `.tmp`, then `.old` (both validated first — a corrupted `.tmp` never overwrites a good `.old`). Corrupted JSON falls back to `.old`; legacy `.xml` databases are read and then archived away automatically.

### Data Type Fidelity

A custom `System.Text.Json` converter keeps JSON readable while preserving PowerShell semantics:

| JSON marker | Restored as |
|---|---|
| `{"~": true, ...}` | `PSCustomObject` |
| `{"~i": true, "123": ...}` | hashtable with **Int32 keys** |
| `{"~D": "2024-06-15T14:30:45.1230000Z"}` | `DateTime` with exact value and `Kind` |
| `{"~m": "999999999999999.99"}` | `decimal` with exact scale |
| `{"~S": "2024-06-15T..."}` | date-shaped **string** (never auto-converted to DateTime) |
| `{"~C": "MyClass", ...}` | instance of your **PowerShell class** — properties, nested classes and int-keyed members restored |
| `{"__CLIXML__": "<Objs…"}` | complex .NET types (`X509Certificate2`, …) via CLIXML |

Numbers map to the smallest fitting type (`Int32` → `Int64` → …), arrays become `object[]`, hashtables are case-insensitive — the usual PowerShell semantics.

### Performance

Measured by the bundled test suite (`code_testing\Test-Hashtable-DB1.ps1`), PowerShell 7, desktop hardware, records ≈ 1 KB:

| Operation | Volume | Time |
|---|---|---|
| `Add` | 120 000 records | ≈ 2.3 s (~19–25 µs per record) |
| `Get` | 50 000 lookups | ≈ 0.34 s (~7 µs per lookup) |
| Random `Get` | 10 000 of 100 000 | ≈ 0.06 s |
| `SaveToDisk` | 120 000 records (~120 MB JSON) | ≈ 0.16 s |
| `LoadFromDisk` | 120 000 records | ≈ 0.48 s |
| `CompactDatabase` | 100 000-record base | ≈ 0.1 ms (reference swap) |

### Error Handling

```powershell
if (-not $db.LoadFromDisk() -and $db.ErrorLevel -ne 0) {
    Write-Warning "[$($db.ErrorLevel)] $($db.ErrorText)"
}
```

| `ErrorLevel` | Meaning |
|---|---|
| `0` | Success |
| `LFX1` | Main file missing — normal on first run; an empty DB is created |
| `LFX2` / `LFX4` / `LFX6` | main / updates / deletes corrupted, no valid fallback found |
| `LFX8` | Unexpected load error |
| `STX1` | Synchronous save failed |
| `STXT1` | Synchronous TxLog save failed |
| `TXLOG2` / `TXLOG3` | Async TxLog save failed / failed to start |
| `ASYNC2` | Async save failed to start |
| `ALOAD1` / `ALOAD2` | Async load failed to start / returned no output |
| `EDBFP1` | Folder or ACL operation failed |

### Thread Safety

- Reads (`Get`, `GetAllKeys`, `ContainsKey`, `Clone`) are lock-free.
- `Add` / `Remove` / nested-key upserts are thread-safe (`ConcurrentDictionary` + CAS retries; nested helpers throw after 100 lost races instead of silently losing data).
- Assume **one writer instance per folder**; multiple read-only clients are fine.

---

<a name="russian"></a>

## 📗 Русский

### Содержание
- [Возможности](#возможности)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Публичный API](#публичный-api)
- [Свойства](#свойства)
- [Примеры использования](#примеры-использования)
- [Формат хранения данных](#формат-хранения-данных)
- [Точность сохранения типов](#точность-сохранения-типов)
- [Производительность](#производительность)
- [Обработка ошибок](#обработка-ошибок)
- [Потокобезопасность](#потокобезопасность)

### Возможности

- **Потокобезопасность по построению** — рабочие коллекции это `ConcurrentDictionary`; записи используют CAS-повторы, состояние TxLog защищено монитором.
- **Неблокирующее сохранение/загрузка** — операции выполняются в фоновых runspace'ах; главный поток (и GUI) не замирает. Включены помощники ожидания/опроса.
- **Точное сохранение типов** — `DateTime` (включая `Kind`), хештейблы с ключами Int32, масштаб `decimal`, строки вида даты, `PSCustomObject` **и ваши собственные классы PowerShell** переживают круговой путь через JSON.
- **Инкрементальные сохранения** — между консолидациями перезаписываются только `*_updates.json` и `*_deletes.json`; полное сохранение выполняется автоматически, когда накопленные изменения превышают 30% основной БД.
- **Устойчивость к сбоям** — запись через `.tmp` → атомарный rename-обмен, откат на шаг назад через `.old`, датированные бэкапы с настраиваемым хранением, автоматическое восстановление повреждённых файлов.
- **Быстро** — собственный C#-конвертер `System.Text.Json` пишет со скоростью ≈ 760 МБ/с.
- **Читаемое хранилище** — обычный JSON вместо непрозрачного CLIXML; старые `.xml`-базы читаются и мигрируются автоматически.
- **Журнал транзакций** — добавляемый (append-only) `.txlog` с дельтами операций для репликации между серверами.
- **Работа с общей папкой** — один вызов выдаёт SID права чтения или чтения+записи на папку БД.
- **Ноль зависимостей** — один файл: `HashTableDB1-Class.ps1`.

### Требования

- **PowerShell 7.0+** (используется `System.Text.Json`; Windows PowerShell 5.1 не поддерживается).
- Хранилище кроссплатформенно; помощник ACL (`EnsureDBFolderWithPermissions`) — только Windows.

### Быстрый старт

```powershell
. "$PSScriptRoot\inc\HashtableDB1-Class.ps1"   # dot-source once: [HashTableDB1] is now available

$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = 'C:\Data\MyDB'   # folder is created automatically on save
$db.DatabaseFileName   = 'Users'          # files: Users_main.json, Users_updates.json, Users_deletes.json
$db.NumOfDbBackupsToKeep = 5              # keep 5 timestamped backups in OLD\

$db.Add('user42', @{ Name = 'John'; Roles = @('admin', 'dev') })
$db.Get('user42').Name        # John
$db.ContainsKey('user42')     # True

$db.SaveToDisk()
```

Повторная загрузка — в той же или другой сессии:

```powershell
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = 'C:\Data\MyDB'
$db.DatabaseFileName   = 'Users'
$db.LoadFromDisk()             # True
$db.Get('user42').Roles[0]    # admin
```

### Публичный API

**Операции с данными**

| Метод | Описание |
|---|---|
| `Add($key, $value)` | Добавляет или обновляет запись. |
| `Remove($key)` | Удаляет запись (создаёт надгробие-маркер). |
| `Get($key)` | Возвращает значение записи или `$null`, если ключа нет. |
| `GetAllKeys()` | Все ключи объединённого представления. |
| `GetAllValues()` | Все значения объединённого представления. |
| `ContainsKey($key)` | `True`, если ключ существует. |
| `Clone()` | Неглубокий снапшот объединённого представления обычным `hashtable`. |
| `UpsertNestedHashTableKey($key, $subKey, $subValue = 1)` | Атомарный upsert вторичного ключа внутри записи-хештейбла (с CAS-повторами). |
| `RemoveNestedHashTableKey($key, $subKey)` | Удаляет вторичный ключ; удаляет запись, когда она опустела. |
| `GetPendingChangesCount()` | Количество несохранённых изменений + надгробий. |
| `CreateEmptyDB()` | Сбрасывает базу в пустое состояние. |

**Сохранение/загрузка**

| Метод | Описание |
|---|---|
| `SaveToDisk()` | Синхронное сохранение. Автоконсолидация при изменениях > 30% основной БД. |
| `SaveToDiskAsync()` | Сохранение в фоновом runspace — возвращается немедленно. |
| `WaitForAsyncSaveToDisk()` | Блокируется до завершения текущего асинхронного сохранения. |
| `LoadFromDisk()` | Синхронная загрузка. `$true` = данные перечитаны; `$false` = нового нет (не ошибка). Неизменённые файлы пропускаются по таймстампам. |
| `LoadFromDiskAsync()` | Загрузка в фоновом runspace (включая десериализацию). |
| `WaitForAsyncLoadFromDisk()` | Блокируется до завершения текущей асинхронной загрузки. |
| `CompactDatabase()` | Вливает updates/deletes в основную БД (O(1), обмен ссылок); при следующем сохранении пишется полный файл. |
| `SaveTransactionLogAsync()` | Асинхронно записывает несохранённую дельту операций в `TxLog\*.txlog`. |
| `WaitForPendingTransactionLogOperations()` | Блокируется до завершения текущего сохранения TxLog. |
| `EnsureDBFolderWithPermissions($SID, $AllowWrite = $false)` | Создаёт папку БД и выдаёт SID права чтения или чтения+записи. |
| `Dispose()` | Дожидается всех асинхронных операций, освобождает runspace'ы, пулы и память. |

### Свойства

| Свойство | По умолчанию | Описание |
|---|---|---|
| `DatabaseFolderPath` | `".\"` | Папка хранения (создаётся при сохранении). |
| `DatabaseFileName` | `"HashTableDB"` | Базовое имя трёх файлов. |
| `NumOfDbBackupsToKeep` | `0` | Датированных бэкапов в `OLD\` (0 = не хранить). |
| `DatabaseParamsHT` | `@{}` | Произвольные пользовательские параметры, хранимые вместе с БД. |
| `ReadOnlyMode` | `$false` | Блокирует все операции записи. |
| `EnableTransactionLog` | `$false` | Включает журнал транзакций. |
| `TxLogRetentionDays` | `3` | Дней хранения файлов `.txlog` и состояния тиков в памяти. |
| `LockFileMaxWaitTime` | `30` | Максимум секунд ожидания зависшей async-операции до принудительного завершения. |
| `ErrorLevel` / `ErrorText` | `0` / `$null` | Результат последней операции: `0` = успех, строковый код = ошибка. |
| `IsForceSaveMain` | `$false` | Принудительное полное сохранение (основного файла) при следующем вызове. |
| `MainFileLoadedDT` `UpdatesFileLoadedDT` `RemovedFileLoadedDT` | — | Таймстампы последней загрузки/сохранения по файлам; движок инкрементальных загрузок. |
| `DatabaseReadAccessControlListIdentifiers` | `$null` | Зарезервировано: SID'ы для доступа на чтение. |
| `CurrentBackupNumber` | `0` | Диагностический счётчик ротаций бэкапов. |
| `MainHT` `UpdatesHT` `MergedHT` `RemovedHT` | — | Живые представления `ConcurrentDictionary`. **Только чтение; напрямую не менять.** |

### Примеры использования

**Асинхронное сохранение без заморозки UI:**

```powershell
$db.SaveToDiskAsync()          # returns immediately

# ...your GUI / main loop keeps running...

$db.WaitForAsyncSaveToDisk()   # optional explicit barrier

# or poll the synchronized result
do { Start-Sleep -Milliseconds 200 } while (-not $db.AsyncResults.ContainsKey('Success'))
if (-not $db.AsyncResults['Success']) { throw $db.AsyncResults['Message'] }
```

**Асинхронная предзагрузка большой базы:**

```powershell
$db.LoadFromDiskAsync()        # deserialization runs in the background

# ...show a splash screen / keep serving reads from the old snapshot...

$db.WaitForAsyncLoadFromDisk()
```

**Вложенные хештейблы (атомарное обновление подключей):**

```powershell
$db.UpsertNestedHashTableKey('user42', 'LastLogin', (Get-Date))
$db.UpsertNestedHashTableKey('user42', 'LoginCount', 1)
$db.Get('user42').LoginCount            # 1

$db.RemoveNestedHashTableKey('user42', 'LastLogin')
```

**Пользовательские параметры путешествуют вместе с базой:**

```powershell
$db.DatabaseParamsHT['SchemaVersion'] = 3
$db.SaveToDisk()

# ...after LoadFromDisk() in any session:
$db.DatabaseParamsHT['SchemaVersion']   # 3
```

**Журнал транзакций (репликация / аудит):**

```powershell
$db.EnableTransactionLog = $true
$db.TxLogRetentionDays    = 7

$db.Add('user43', @{ Name = 'Ann' })
$db.Remove('user42')

$db.SaveToDiskAsync()   # also flushes the TxLog delta asynchronously
# -> TxLog\Users_<firstTick>_<lastTick>.txlog
#    [["A","user43",{...},tick],["R","user42",null,tick]]
```

**Права на папку для общей БД:**

```powershell
$db.EnsureDBFolderWithPermissions('S-1-5-21-...', $false)  # read only
$db.EnsureDBFolderWithPermissions('S-1-5-21-...', $true)  # read + write
```

### Формат хранения данных

```
C:\Data\MyDB\
├── Users_main.json          # полная база (перезаписывается только при консолидации)
├── Users_updates.json       # изменённые ключи с последнего полного сохранения
├── Users_deletes.json       # удалённые ключи + ___DATABASEPARAMS___ (параметры БД)
├── Users_*.old              # предыдущие версии (откат на один шаг)
├── OLD\                     # датированные бэкапы, ротация по NumOfDbBackupsToKeep
│   └── Users_main.20260915-073016
└── TxLog\
    └── Users_<firstTick>_<lastTick>.txlog
```

**Алгоритм сохранения:** сериализация в `*.tmp` → текущий `*.json` переименовывается в `*.old` → `*.tmp` переименовывается в `*.json` (с повторами при конфликте ввода-вывода) → `*.old` переносится в `OLD\` с таймстампом, излишки ротируются.

**Алгоритм загрузки:** файлы, чей `LastWriteTime` не новее сохранённого `*FileLoadedDT`, пропускаются целиком. Отсутствующий `main.json` восстанавливается из `.tmp`, затем из `.old` (оба сперва валидируются — повреждённый `.tmp` никогда не затирает хороший `.old`). Повреждённый JSON откатывается на `.old`; старые `.xml`-базы читаются и автоматически отправляются в архив.

### Точность сохранения типов

Собственный конвертер `System.Text.Json` сохраняет JSON читаемым, не теряя семантики PowerShell:

| Маркер в JSON | Восстанавливается как |
|---|---|
| `{"~": true, ...}` | `PSCustomObject` |
| `{"~i": true, "123": ...}` | хештейбл с **ключами Int32** |
| `{"~D": "2024-06-15T14:30:45.1230000Z"}` | `DateTime` с точным значением и `Kind` |
| `{"~m": "999999999999999.99"}` | `decimal` с точным масштабом |
| `{"~S": "2024-06-15T..."}` | **строка** вида даты (никогда не превращается в DateTime) |
| `{"~C": "MyClass", ...}` | экземпляр вашего **класса PowerShell** — свойства, вложенные классы и int-ключи восстанавливаются |
| `{"__CLIXML__": "<Objs…"}` | сложные типы .NET (`X509Certificate2`, …) через CLIXML |

Числа маппятся в минимальный подходящий тип (`Int32` → `Int64` → …), массивы становятся `object[]`, хештейблы регистронезависимы — привычная семантика PowerShell.

### Производительность

Замерено комплектом тестов (`code_testing\Test-Hashtable-DB1.ps1`), PowerShell 7, настольное железо, записи ≈ 1 КБ:

| Операция | Объём | Время |
|---|---|---|
| `Add` | 120 000 записей | ≈ 2.3 с (~19–25 мкс на запись) |
| `Get` | 50 000 чтений | ≈ 0.34 с (~7 мкс на чтение) |
| Случайный `Get` | 10 000 из 100 000 | ≈ 0.06 с |
| `SaveToDisk` | 120 000 записей (~120 МБ JSON) | ≈ 0.16 с |
| `LoadFromDisk` | 120 000 записей | ≈ 0.48 с |
| `CompactDatabase` | база 100 000 записей | ≈ 0.1 мс (обмен ссылок) |

### Обработка ошибок

```powershell
if (-not $db.LoadFromDisk() -and $db.ErrorLevel -ne 0) {
    Write-Warning "[$($db.ErrorLevel)] $($db.ErrorText)"
}
```

| `ErrorLevel` | Значение |
|---|---|
| `0` | Успех |
| `LFX1` | Основной файл отсутствует — норма при первом запуске; создаётся пустая БД |
| `LFX2` / `LFX4` / `LFX6` | main / updates / deletes повреждён, валидного запасного варианта нет |
| `LFX8` | Неожиданная ошибка загрузки |
| `STX1` | Ошибка синхронного сохранения |
| `STXT1` | Ошибка синхронного сохранения TxLog |
| `TXLOG2` / `TXLOG3` | Ошибка / не удалось запустить асинхронное сохранение TxLog |
| `ASYNC2` | Не удалось запустить асинхронное сохранение |
| `ALOAD1` / `ALOAD2` | Не удалось запустить асинхронную загрузку / нет выходных данных |
| `EDBFP1` | Ошибка операции с папкой или ACL |

### Потокобезопасность

- Чтения (`Get`, `GetAllKeys`, `ContainsKey`, `Clone`) выполняются без блокировок.
- `Add` / `Remove` / upsert вторичных ключей потокобезопасны (`ConcurrentDictionary` + CAS-повторы; вложенные помощники после 100 проигранных гонок бросают исключение вместо тихой потери данных).
- Предполагается **один пишущий экземпляр на папку**; несколько клиентов только для чтения — допустимы.

---

## Project structure / Структура проекта

```
inc\HashTableDB1-Class.ps1              # the class + C# JSON converter (everything)
code_testing\Test-Hashtable-DB1.ps1    # test suite & benchmarks (14 tests)
```

## License / Лицензия

MIT
