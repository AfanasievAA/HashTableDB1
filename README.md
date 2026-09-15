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

<p align="center"><a href="#english">English</a> &bull; <a href="#russian">Русский</a></p>

---

<a id="english"></a>
## 🇬🇧 English

### Overview

**HashTableDB1** is a lightweight, dependency-free, persistent key–value store written in pure PowerShell 7+. It saves data to a JSON file, supports asynchronous flushing, and preserves exact .NET types via an internal type-tagging mechanism.

### Features

- **Persistent** — data survives process restarts (JSON on disk).
- **Thread-safe** — synchronized access via `[System.Threading.Monitor]` and a `ReaderWriterLockSlim`.
- **Asynchronous I/O** — background writer thread flushes dirty state without blocking callers.
- **Type fidelity** — integers, longs, doubles, booleans, dates, GUIDs, arrays and nested hashtables round-trip exactly.
- **Zero dependencies** — pure PowerShell 7+, no modules required.
- **Simple API** — `Get`, `Set`, `Remove`, `Contains`, `Keys`, `Clear`, `Save`, `Dispose`.

### Requirements

- PowerShell 7.0 or newer
- Write access to the target storage directory

### Installation

```powershell
git clone https://github.com/<your-user>/HashTableDB1.git
Import-Module ./HashTableDB1/HashTableDB1.ps1
```

### Quick start

```powershell
Import-Module ./HashTableDB1/HashTableDB1.ps1

# Open (or create) a database file
$db = [HashTableDB1]::new("$PWD/data.json")

# Write
$db.Set('user', @{ name = 'Alice'; age = 30 })
$db.Set('counter', 42)
$db.Set('created', [datetime]::UtcNow)

# Read
$user = $db.Get('user')
"$($user.name) is $($user.age)"

# Check existence
if ($db.Contains('counter')) { $db.Get('counter') }

# Remove
$db.Remove('counter')

# Persist synchronously (optional — auto-flush also runs)
$db.Save()

# Release resources
$db.Dispose()
```

### API reference

| Member | Description |
| --- | --- |
| `[HashTableDB1]::new([string]$Path)` | Opens or creates a database at `$Path`. |
| `Get([string]$Key)` | Returns the value or `$null`. |
| `Set([string]$Key, $Value)` | Inserts or updates a key. |
| `Remove([string]$Key)` | Deletes a key; returns `$true` if removed. |
| `Contains([string]$Key)` | `$true` if the key exists. |
| `Keys()` | Returns all keys as `string[]`. |
| `Clear()` | Removes all entries. |
| `Save()` | Forces a synchronous flush to disk. |
| `Dispose()` | Stops the background writer and releases locks. |

### Type fidelity

Values are stored with a type tag, so these round-trip exactly:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (nested).

### Architecture

```
+-------------------+       +---------------------+
|   Caller thread   | ----> |  HashTableDB1 core  |
+-------------------+       |  - in-memory table  |
                            |  - RW lock          |
                            +----------+----------+
                                       |
                                       v
                            +---------------------+
                            |  Background writer  |
                            |  (async flush)      |
                            +----------+----------+
                                       |
                                       v
                                 data.json
```

### Testing

```powershell
Invoke-Pester ./tests
```

Expected: **14 / 14 passed**.

### License

MIT — see [LICENSE](LICENSE).

---

<a id="russian"></a>
## 🇷🇺 Русский

### Обзор

**HashTableDB1** — лёгкое, не имеющее зависимостей, персистентное хранилище «ключ–значение», написанное на чистом PowerShell 7+. Данные сохраняются в JSON-файл, поддерживается асинхронная запись на диск и точное сохранение .NET-типов через внутреннюю систему тегов.

### Возможности

- **Персистентность** — данные переживают перезапуск процесса (JSON на диске).
- **Потокобезопасность** — синхронизация через `[System.Threading.Monitor]` и `ReaderWriterLockSlim`.
- **Асинхронный ввод-вывод** — фоновый поток-писатель сбрасывает «грязное» состояние, не блокируя вызывающий код.
- **Точность типов** — целые, длинные, дробные, логические, даты, GUID, массивы и вложенные хеш-таблицы восстанавливаются без потерь.
- **Ноль зависимостей** — только PowerShell 7+.
- **Простой API** — `Get`, `Set`, `Remove`, `Contains`, `Keys`, `Clear`, `Save`, `Dispose`.

### Требования

- PowerShell 7.0 или новее
- Права на запись в целевую директорию

### Установка

```powershell
git clone https://github.com/<your-user>/HashTableDB1.git
Import-Module ./HashTableDB1/HashTableDB1.ps1
```

### Быстрый старт

```powershell
Import-Module ./HashTableDB1/HashTableDB1.ps1

# Открыть или создать файл базы
$db = [HashTableDB1]::new("$PWD/data.json")

# Запись
$db.Set('user', @{ name = 'Alice'; age = 30 })
$db.Set('counter', 42)
$db.Set('created', [datetime]::UtcNow)

# Чтение
$user = $db.Get('user')
"$($user.name) is $($user.age)"

# Проверка наличия
if ($db.Contains('counter')) { $db.Get('counter') }

# Удаление
$db.Remove('counter')

# Принудительное сохранение (необязательно — автосброс уже работает)
$db.Save()

# Освобождение ресурсов
$db.Dispose()
```

### Справочник API

| Метод | Описание |
| --- | --- |
| `[HashTableDB1]::new([string]$Path)` | Открывает или создаёт базу по пути `$Path`. |
| `Get([string]$Key)` | Возвращает значение или `$null`. |
| `Set([string]$Key, $Value)` | Добавляет или обновляет ключ. |
| `Remove([string]$Key)` | Удаляет ключ; возвращает `$true`, если удалён. |
| `Contains([string]$Key)` | `$true`, если ключ существует. |
| `Keys()` | Возвращает все ключи как `string[]`. |
| `Clear()` | Удаляет все записи. |
| `Save()` | Принудительно синхронно сбрасывает на диск. |
| `Dispose()` | Останавливает фоновый писатель и освобождает блокировки. |

### Точность типов

Значения хранятся с тегом типа, поэтому без потерь восстанавливаются:

`[int]`, `[long]`, `[double]`, `[decimal]`, `[bool]`, `[string]`, `[datetime]`, `[guid]`, `[array]`, `[hashtable]` (вложенные).

### Архитектура

```
+-------------------+       +---------------------+
|  Поток вызова     | ----> |  Ядро HashTableDB1  |
+-------------------+       |  - таблица в памяти |
                            |  - RW-блокировка    |
                            +----------+----------+
                                       |
                                       v
                            +---------------------+
                            |  Фоновый писатель   |
                            |  (асинхронный сброс)|
                            +----------+----------+
                                       |
                                       v
                                 data.json
```

### Тестирование

```powershell
Invoke-Pester ./tests
```

Ожидается: **14 / 14 passed**.

### Лицензия

MIT — см. [LICENSE](LICENSE).
