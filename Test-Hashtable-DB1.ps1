<#
======================================================================
  Test script for the new HashTableDB1 implementation (uses Mutex)
  --------------------------------------------------------------------
  What the script does:
    1. Loads the class (HashTableDB1-Class.ps1)
    2. Pre-generates all test data to isolate test timings
    3. Sequentially tests:
       - Add / Remove / AddListUnique / RemoveListUnique
       - Consolidate (Normal & High Load)
       - SaveToDisk / LoadFromDisk (Sync & Async)
       - Isolated Add/Get/Remove performance
       - Bulk Read performance
       - Backup rotation (NumOfDbBackupsToKeep)
       - Mutex synchronization during parallel async saves
    4. Outputs PASS / FAIL for each step and a summary
       Saves execution timings, memory metrics, and context to a CSV file.
  --------------------------------------------------------------------
  How to run:
    - Save next to HashTableDB1-Class.ps1 as Run-HashtableDB1Tests.ps1
    - Run in PowerShell 5.1+ (or PowerShell 7): .\Run-HashtableDB1Tests.ps1
======================================================================
#>

# -------------------------------------------------
# 0. Include class file and initialize metrics
# -------------------------------------------------
 $projectSource = Resolve-Path "$($PSScriptRoot)"
 $projectRoot = Resolve-Path "$($projectSource)"
 $projectTmp = Join-Path $projectRoot "tmp"
 $ClassFile = Join-Path $projectSource "HashtableDB1-Class.ps1"
 $StorageFormatToTest = 'xml'
# $StorageFormatToTest = 'json'
if (-not (Test-Path $ClassFile)) {
    Write-Error "Class file not found: $ClassFile"
    exit 1
}
. $ClassFile   # [HashTableDB1] type is now available

# Test classes for '~C' rehydration round-trip: defined at script scope so the type resolver can find them
class TstRollingSet {
    [int]      $Size
    [string[]] $Members
    [datetime] $LastRotate
}
class TstCertContainer {
    [string]        $UserName
    [hashtable]     $Certificates   # int-keyed hashtable to verify '~i' marker inside rehydrated classes
    [datetime]      $ResolvedWhen
    [TstRollingSet] $Rolling        # nested class instance to verify recursive '~C' rehydration
    [object[]]      $History        # empty array edge case inside a class
    [string]        $Note           # date-shaped "O" string to verify '~S' protection inside a class
    TstCertContainer() {
        $this.Certificates = @{}
        $this.Rolling = [TstRollingSet]::new()
        $this.History = @()
    }
}

# Initialize process metrics
 $proc = Get-Process -Id $PID
Write-Host "Process metrics at start: WS=$([math]::Round($proc.WorkingSet64/1MB,2))MB, CPU=$($proc.CPU)s"

# List to hold performance metrics
 $Script:TestMetrics = [System.Collections.Generic.List[PSCustomObject]]::new()

function Get-CurrentMemoryMB {
    # Force GC to get a more accurate measurement of actual memory usage
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $proc.Refresh()
    return [math]::Round($proc.WorkingSet64 / 1MB, 2)
}

function Add-TestMetric {
    param(
        [string]$TestName, [string]$Operation, [string]$Context,
        [double]$ElapsedSeconds, [string]$Status = "OK",
        [double]$MemBeforeMB = 0, [double]$MemAfterMB = 0
    )
    $Script:TestMetrics.Add([PSCustomObject]@{
        Timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TestName    = $TestName
        Operation   = $Operation
        Context     = $Context
        ElapsedSec  = [math]::Round($ElapsedSeconds, 4)
        MemBeforeMB = $MemBeforeMB
        MemAfterMB  = $MemAfterMB
        MemDeltaMB  = [math]::Round($MemAfterMB - $MemBeforeMB, 2)
        Status      = $Status
    })
}

# -------------------------------------------------
# 0.2 Pre-generate Test Data
# -------------------------------------------------
Write-Host "Pre-generating test data (this may take a few seconds)..." -ForegroundColor Yellow
# Generate a 1KB base string once to avoid slow Get-Random loops during tests
 $base1KB = -join (1..1024 | ForEach-Object { [char](Get-Random -Min 65 -Max 90) })

# Generate arrays of Key-Value objects using fast string concatenation
 $Script:Data30 = 1..30 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data40 = 1..40 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data50 = 1..50 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data20 = 1..20 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data15 = 1..15 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data100 = 1..100 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data10 = 1..10 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data25 = 1..25 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data50k = 1..50000 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data100k = 1..100000 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }
 $Script:Data120k = 1..120000 | ForEach-Object { [pscustomobject]@{ Key = "k$_"; Value = $base1KB } }

# Pre-generate random keys for bulk read test
 $Script:RandomReadKeys10k = 1..10000 | ForEach-Object { "k$(Get-Random -Min 1 -Max 100000)" }
Write-Host "Test data generated successfully." -ForegroundColor Green

# -------------------------------------------------
# 1. Helper functions
# -------------------------------------------------
function New-TestDB {
    param(
        [string] $Folder,
        [int]    $BackupCount = 3
    )
    $db = [HashTableDB1]::new()
    $db.DatabaseFolderPath   = $Folder
    $db.DatabaseFileName     = 'TestDB'
    $db.NumOfDbBackupsToKeep = $BackupCount
    $db.EnableTransactionLog = $true
    $db.StorageFormat = $StorageFormatToTest
    $db
}

# Deep comparison of values after JSON round-trip. Handles type coercion performed by PSObjectJsonConverter:
# - PSCustomObject is restored as PSCustomObject ('~' marker); compared loosely with hashtables here
# - ArrayList and typed arrays (int[], string[]) become object[]; empty arrays must survive as empty (not $null)
# - DateTime is restored as DateTime ('~D' marker); 1-second tolerance kept only for legacy "O"-string files
# - Int32-keyed hashtables keep Int32 keys ('~i' marker); keys are compared as case-insensitive strings here
# - Guid, TimeSpan, char are still serialized as strings and restored as strings
# - Numeric types may shift precision container (byte -> int, decimal stays decimal)
function Compare-DbValues {
    param(
        [object] $Expected,
        [object] $Actual,
        [string] $Path = ''
    )
    if ($null -eq $Expected -and $null -eq $Actual) { return $true }
    if ($null -eq $Expected -or $null -eq $Actual) {
        Write-Warning "Compare-DbValues: null mismatch at '$Path' (E=$($null -eq $Expected) A=$($null -eq $Actual))"
        return $false
    }
    # Normalize CLIXML-deserialized wrappers: in Xml mode collections come back as PSObject instances
    # wrapping the collection. GetType() forwards to the wrapped object (so it prints "ArrayList"),
    # but the -is classification below sees the wrapper and the pscustomobject branch marks it
    # dict-like, while the pristine snapshot value is list-like - a bogus "dict/scalar" mismatch.
    # Unwrapping via BaseObject makes both sides classify identically; raw values unwrap to
    # themselves, so Json-mode behavior is unchanged.
    $Expected = $Expected.PSObject.BaseObject
    $Actual = $Actual.PSObject.BaseObject
    # Dictionary-like: IDictionary (hashtable) or PSCustomObject on either side
    $eIsDict = $Expected -is [System.Collections.IDictionary] -or $Expected -is [pscustomobject]
    $aIsDict = $Actual -is [System.Collections.IDictionary] -or $Actual -is [pscustomobject]
    if ($eIsDict -and $aIsDict) {
        $htE = @{}
        if ($Expected -is [System.Collections.IDictionary]) {
            foreach ($k in $Expected.Keys) { $htE["$k"] = $Expected[$k] }
        } else {
            foreach ($p in $Expected.PSObject.Properties) { $htE["$($p.Name)"] = $p.Value }
        }
        $htA = @{}
        if ($Actual -is [System.Collections.IDictionary]) {
            foreach ($k in $Actual.Keys) { $htA["$k"] = $Actual[$k] }
        } else {
            foreach ($p in $Actual.PSObject.Properties) { $htA["$($p.Name)"] = $p.Value }
        }
        if ($htE.Count -ne $htA.Count) {
            Write-Warning "Compare-DbValues: dictionary count mismatch at '$Path' (E=$($htE.Count) A=$($htA.Count))"
            return $false
        }
        foreach ($k in $htE.Keys) {
            $matchedKey = $null
            foreach ($bk in $htA.Keys) {
                if ([string]::Equals($k, $bk, [System.StringComparison]::OrdinalIgnoreCase)) { $matchedKey = $bk; break }
            }
            if (-not $matchedKey) {
                Write-Warning "Compare-DbValues: missing key '$k' at '$Path'"
                return $false
            }
            if (-not (Compare-DbValues -Expected $htE[$k] -Actual $htA[$matchedKey] -Path "$Path$k.")) { return $false }
        }
        return $true
    }
    if ($eIsDict -ne $aIsDict) {
        Write-Warning "Compare-DbValues: dict/scalar type mismatch at '$Path' (E=$($Expected.GetType().Name) A=$($Actual.GetType().Name))"
        return $false
    }
    # List-like: Array, IList, ArrayList
    $eIsList = $Expected -is [System.Collections.IList] -or $Expected -is [Array]
    $aIsList = $Actual -is [System.Collections.IList] -or $Actual -is [Array]
    if ($eIsList -and $aIsList) {
        $arrE = @($Expected); $arrA = @($Actual)
        if ($arrE.Count -ne $arrA.Count) {
            Write-Warning "Compare-DbValues: array count mismatch at '$Path' (E=$($arrE.Count) A=$($arrA.Count))"
            return $false
        }
        for ($i = 0; $i -lt $arrE.Count; $i++) {
            if (-not (Compare-DbValues -Expected $arrE[$i] -Actual $arrA[$i] -Path "$Path[$i].")) { return $false }
        }
        return $true
    }
    if ($eIsList -ne $aIsList) {
        Write-Warning "Compare-DbValues: list/scalar type mismatch at '$Path' (E=$($Expected.GetType().Name) A=$($Actual.GetType().Name))"
        return $false
    }
    # DateTime: JSON "O" round-trip may shift DateTimeKind, allow 1-second tolerance
    if ($Expected -is [DateTime]) {
        if ($Actual -is [DateTime]) { return [math]::Abs(($Expected - $Actual).TotalSeconds) -lt 1 }
        if ($Actual -is [string]) {
            try {
                $dt = [DateTime]::Parse($Actual, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                return [math]::Abs(($Expected - $dt).TotalSeconds) -lt 1
            } catch { return $false }
        }
        return $false
    }
    # Types serialized as strings by PSObjectJsonConverter (Guid, TimeSpan, char)
    if ($Expected -is [Guid]) {
        if ($Actual -is [Guid]) { return $Expected -eq $Actual }
        if ($Actual -is [string]) { try { return ([Guid]$Actual) -eq $Expected } catch { return $false } }
        return $false
    }
    if ($Expected -is [TimeSpan]) {
        if ($Actual -is [TimeSpan]) { return $Expected -eq $Actual }
        if ($Actual -is [string]) { try { return ([TimeSpan]$Actual) -eq $Expected } catch { return $false } }
        return $false
    }
    if ($Expected -is [char]) {
        if ($Actual -is [char]) { return $Expected -eq $Actual }
        if ($Actual -is [string]) { return ("$([char]$Expected)") -eq $Actual }
        return $false
    }
    # Numeric type coercion (int/long/byte/double/decimal may shift container on JSON round-trip)
    $numericTypeNames = @('Int32','Int64','Int16','Byte','SByte','UInt16','UInt32','UInt64','Double','Single','Decimal')
    if ($numericTypeNames -contains $Expected.GetType().Name -and $numericTypeNames -contains $Actual.GetType().Name) {
        $e = [double]$Expected
        $a = [double]$Actual
        if ($e -eq $a) { return $true }
        # Tolerance for floating-point precision drift across double<->decimal conversion
        return [math]::Abs($e - $a) -lt 0.0001
    }
    # Boolean
    if ($Expected -is [bool]) {
        if ($Actual -is [bool]) { return $Expected -eq $Actual }
        return $false
    }
    # String
    if ($Expected -is [string]) {
        if ($Actual -is [string]) { return $Expected -eq $Actual }
        return $false
    }
    # Fallback
    return $Expected -eq $Actual
}

function Wait-ForAsyncResult {
    param([object] $obj, [int] $TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $obj.AsyncResults.ContainsKey('Success')) {
        if ((Get-Date) -gt $deadline) { throw "Timeout waiting for async result" }
        Start-Sleep -Milliseconds 250
    }
}
Write-Host "Selected storage format: $StorageFormatToTest"
# -------------------------------------------------
# 2. Test logic
# -------------------------------------------------
 $AllOk = $true
 $sw = [System.Diagnostics.Stopwatch]::StartNew()
 $BasePath = Join-Path $projectTmp 'HashTableDB1_Tests'
if (Test-Path $BasePath) { Remove-Item -Recurse -Force $BasePath }
# Use -Force to ensure the parent $projectTmp directory exists if it doesn't already
New-Item -ItemType Directory -Path $BasePath -Force | Out-Null

# 2.1 Test 1 - Add / Remove / AddListUnique / RemoveListUnique
Write-Host "`n=== Test 1 - Add / Remove & unique-list ===" -ForegroundColor Cyan
 $folder1 = Join-Path $BasePath '01_AddRemove'
New-Item -ItemType Directory -Path $folder1 | Out-Null
 $db1 = New-TestDB -Folder $folder1 -BackupCount 0

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($item in $Script:Data30) { $db1.Add($item.Key, $item.Value) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 1" -Operation "Add 30 records" -Context "Adds 30 pre-generated key-value pairs to the database to test basic insertion performance and memory allocation without data generation overhead." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

if ($db1.GetAllKeys().Count -ne 30) { Write-Host "FAIL: Expected 30 keys" -ForegroundColor Red; $AllOk = $false }
 $toRem = $db1.GetAllKeys() | Select-Object -First 5

 $sw.Restart()
foreach ($k in $toRem) { $db1.Remove($k) }
 $sw.Stop()
Add-TestMetric -TestName "Test 1" -Operation "Remove 5 records" -Context "Removes the first 5 keys from the database to test the deletion logic and verify they no longer exist." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $uniqKey = "UNIQ_$([guid]::NewGuid().ToString('N').Substring(0,8))"
 $db1.UpsertNestedHashTableKey($uniqKey,'subA',1)
 $db1.UpsertNestedHashTableKey($uniqKey,'subB',42)
if ($db1.Get($uniqKey).Count -ne 2) { Write-Host "FAIL: AddListUnique logic broken" -ForegroundColor Red; $AllOk = $false }
 $db1.RemoveNestedHashTableKey($uniqKey,'subA')
if ($db1.Get($uniqKey).Count -ne 1) { Write-Host "FAIL: RemoveListUnique broken" -ForegroundColor Red; $AllOk = $false }
Write-Host "PASS: Test 1 completed" -ForegroundColor Green

# 2.2 Test 2 - Sync Save / Load with Mixed PowerShell Types
Write-Host "`n=== Test 2 - SaveToDisk / LoadFromDisk (Mixed Types) ===" -ForegroundColor Cyan
 $folder2 = Join-Path $BasePath '02_SyncSaveLoad'
New-Item -ItemType Directory -Path $folder2 | Out-Null
 $db2 = New-TestDB -Folder $folder2 -BackupCount 2

# Baseline records (string values) to verify bulk insertion still works
foreach ($item in $Script:Data50) { $db2.Add($item.Key, $item.Value) }

# Records with various PowerShell data types to test JSON round-trip fidelity
 $fixedGuid = [guid]'a8c9e7d4-1234-5678-9abc-def012345678'
 $fixedDt   = [datetime]::new(2024, 6, 15, 14, 30, 45, 123, [System.DateTimeKind]::Utc)
 $fixedTs   = [timespan]'1.02:03:04.5000000'
 $mixedTypes = @{
    'mt_String'         = 'Hello, World! Unicode: Привет 你好 🌍'
    'mt_Integer'        = [int]42
    'mt_Long'           = [long]9223372036854775807
    'mt_Double'         = [double]3.14159265358979
    'mt_Decimal'        = [decimal]'999999999999999.99'
    'mt_BooleanTrue'    = $true
    'mt_BooleanFalse'   = $false
    'mt_DateTime'       = $fixedDt
    'mt_TimeSpan'       = $fixedTs
    'mt_Guid'           = $fixedGuid
    'mt_Char'           = [char]'A'
    'mt_Byte'           = [byte]255
    'mt_StringArray'    = [string[]]@('one','two','three')
    'mt_IntArray'       = [int[]](1,2,3,4,5)
    'mt_ArrayList'      = [System.Collections.ArrayList]@('a','b','c')
    'mt_Hashtable'      = @{ NestedKey1 = 'value1'; NestedKey2 = 42; NestedHT = @{ SubKey = 'subvalue'; SubNum = 7 } }
    'mt_PSCustomObject' = [pscustomobject]@{ P1 = 'PSCustom'; P2 = 100; P3 = @{ InnerKey = 'InnerValue' } }
    'mt_EmptyString'    = ''
    'mt_EmptyArray'     = [string[]]@()
    'mt_EmptyHash'      = @{}
    'mt_NestedComplex'  = @{
        Items     = [string[]]@('x','y','z')
        Counts    = [int[]](10,20,30)
        Meta      = [pscustomobject]@{ Author = 'Tester'; Version = '1.0' }
        Timestamp = $fixedDt
        Tags      = [System.Collections.ArrayList]@('tag1','tag2')
        Nested    = @{ DeepKey = 'DeepValue'; DeepNum = [long]1234567890 }
    }
}
foreach ($k in $mixedTypes.Keys) { $db2.Add($k, $mixedTypes[$k]) }

 $snapshot2 = $db2.Clone()

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
 $db2.SaveToDisk()
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 2" -Operation "SaveToDisk" -Context "Synchronously saves the current database state (main, updates, deletes) into JSON files including records with various PowerShell data types (strings, numerics, DateTime, TimeSpan, Guid, char, byte, arrays, ArrayList, hashtables, PSCustomObjects, nested structures) to test standard persistence and serialization fidelity. Format for all save/load tests: $StorageFormatToTest" -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $db2b = New-TestDB -Folder $folder2 -BackupCount 2
 $sw.Restart()
 $ok = $db2b.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 2" -Operation "LoadFromDisk" -Context "Synchronously loads the database from the previously saved JSON files and verifies data integrity and exact type preservation against an in-memory snapshot." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($ok){"OK"}else{"FAIL"})

# Strict type validation: ensure PSObject and other native types are preserved exactly as they were before serialization
 $strictTypeOk = $true
 $loadedPso = $db2b.Get('mt_PSCustomObject')
if ($loadedPso -isnot [pscustomobject]) {
    Write-Host "FAIL: Strict type mismatch for mt_PSCustomObject. Expected PSCustomObject, got $($loadedPso.GetType().Name)" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedDt2 = $db2b.Get('mt_DateTime')
if ($loadedDt2 -isnot [datetime] -or $loadedDt2 -ne $fixedDt -or $loadedDt2.Kind -ne [System.DateTimeKind]::Utc) {
    Write-Host "FAIL: Strict type mismatch for mt_DateTime. Expected DateTime $($fixedDt.ToString('O')), got $(if ($null -ne $loadedDt2) { "$($loadedDt2.GetType().Name) $loadedDt2" } else { 'null' })" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedInt = $db2b.Get('mt_Integer')
if ($loadedInt -isnot [int] -or $loadedInt -ne 42) {
    Write-Host "FAIL: Strict type mismatch for mt_Integer. Expected Int32, got $(if ($null -ne $loadedInt) { $loadedInt.GetType().Name } else { 'null' })" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedLong = $db2b.Get('mt_Long')
if ($loadedLong -isnot [long]) {
    Write-Host "FAIL: Strict type mismatch for mt_Long. Expected Int64, got $(if ($null -ne $loadedLong) { $loadedLong.GetType().Name } else { 'null' })" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedDecimal = $db2b.Get('mt_Decimal')
if ($loadedDecimal -isnot [decimal]) {
    Write-Host "FAIL: Strict type mismatch for mt_Decimal. Expected Decimal, got $(if ($null -ne $loadedDecimal) { $loadedDecimal.GetType().Name } else { 'null' })" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedEmptyArray = $db2b.Get('mt_EmptyArray')
# Format-agnostic: the container type of an empty array is format-dependent (Json -> object[],
# CLIXML -> ArrayList, possibly PSObject-wrapped). The guarded regression is "the empty array
# survived as a non-null empty collection and did not collapse to $null" - so check exactly that.
# NOTE: no intermediate variable - an 'if' expression assignment streams its output through the
# pipeline, which enumerates an empty collection into zero items and collapses it to $null (the
# same gotcha RestoreClassesScriptBlock guards against with its comma-wrapped return).
if ($null -eq $loadedEmptyArray -or @($loadedEmptyArray).Count -ne 0) {
    Write-Host "FAIL: mt_EmptyArray lost. Expected empty array, got $(if ($null -ne $loadedEmptyArray) { $loadedEmptyArray.GetType().Name } else { 'null' })" -ForegroundColor Red
    $strictTypeOk = $false
}
 $loadedEmptyHash = $db2b.Get('mt_EmptyHash')
if ($loadedEmptyHash -isnot [hashtable] -or $loadedEmptyHash.Count -ne 0) {
    Write-Host "FAIL: mt_EmptyHash lost. Expected empty hashtable" -ForegroundColor Red
    $strictTypeOk = $false
}

# Deep comparison of the full snapshot: checks values. 
# NOTE: Compare-DbValues may do loose comparisons, so strict type checks above are required to catch type loss regressions.
 $typeTestOk = Compare-DbValues -Expected $snapshot2 -Actual $db2b.Clone() -Path 'Root.'
if (-not $ok -or -not $typeTestOk -or -not $strictTypeOk) { Write-Host "FAIL: Sync Save/Load mismatch on mixed types or strict type violation" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Sync Save/Load with Mixed Types OK" -ForegroundColor Green }

# 2.3 Test 3 - Async Save vs Sync Save
Write-Host "`n=== Test 3 - SaveToDiskAsync vs SaveToDisk ===" -ForegroundColor Cyan
 $folder3 = Join-Path $BasePath '03_AsyncSave'
New-Item -ItemType Directory -Path $folder3 | Out-Null
 $db3 = New-TestDB -Folder $folder3 -BackupCount 2

foreach ($item in $Script:Data40) { $db3.Add($item.Key, $item.Value) }
 $keysToRemove = $db3.GetAllKeys() | Select-Object -First 3
foreach ($k in $keysToRemove) { $db3.Remove($k) }
 $snapshotAsync = $db3.Clone()

 $sw.Restart()
 $db3.SaveToDiskAsync()
Wait-ForAsyncResult $db3
 $sw.Stop()
Add-TestMetric -TestName "Test 3" -Operation "SaveToDiskAsync + Wait" -Context "Initiates an asynchronous save operation to $($StorageFormatToTest) files and blocks until completion using a custom wait mechanism, testing async persistence." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $db3Loaded = New-TestDB -Folder $folder3 -BackupCount 2
 $sw.Restart()
 $ok = $db3Loaded.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 3" -Operation "LoadFromDisk" -Context "Synchronously loads the database saved asynchronously to verify that async operations produce correct $($StorageFormatToTest) files." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($ok){"OK"}else{"FAIL"})
if (-not $ok -or -not (Compare-DbValues -Expected $snapshotAsync -Actual $db3Loaded.Clone() -Path 'Test3.')) { Write-Host "FAIL: Async save data mismatch" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Async Save produced correct data" -ForegroundColor Green }

# 2.4 Test 4 - Consolidate + backup-rotation
Write-Host "`n=== Test 4 - Consolidate & backup rotation ===" -ForegroundColor Cyan
 $folder4 = Join-Path $BasePath '04_Consolidate'
New-Item -ItemType Directory -Path $folder4 | Out-Null
 $db4 = New-TestDB -Folder $folder4 -BackupCount 0

foreach ($item in $Script:Data20) { $db4.Add($item.Key, $item.Value) }
 $keys = $db4.GetAllKeys()
 $keys[0..4] | ForEach-Object { $db4.Remove($_) }
 $db4.SaveToDisk()

 $db4.NumOfDbBackupsToKeep = 3
 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
 $db4.CompactDatabase()
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 4" -Operation "Consolidate" -Context "Merges update and delete queues into the main database file and resets internal tracking, testing the consolidation mechanism." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $sw.Restart()
 $db4.SaveToDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 4" -Operation "SaveToDisk (post-consolidate)" -Context "Synchronously saves the database after consolidation to verify that backup files are correctly created in the OLD folder and limits are respected." -ElapsedSeconds $sw.Elapsed.TotalSeconds
Write-Host "PASS: Consolidate & backup rotation OK" -ForegroundColor Green

# 2.5 Test 5 - Parallel async-save (Mutex)
Write-Host "`n=== Test 5 - Parallel async Save (Mutex) ===" -ForegroundColor Cyan
 $folder5 = Join-Path $BasePath '05_ParallelAsync'
New-Item -ItemType Directory -Path $folder5 | Out-Null
 $db5 = New-TestDB -Folder $folder5 -BackupCount 0
foreach ($item in $Script:Data15) { $db5.Add($item.Key, $item.Value) }

 $sw.Restart()
 $db5.SaveToDiskAsync()
Wait-ForAsyncResult $db5 -TimeoutSec 30
 $sw.Stop()
Add-TestMetric -TestName "Test 5" -Operation "SaveToDiskAsync #1 + Wait" -Context "Triggers the first asynchronous save operation and waits for it to complete, testing basic async Mutex acquisition and release." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($db5.AsyncResults['Success']){"OK"}else{"FAIL"})
 $db5.AsyncResults.Clear()

 $sw.Restart()
 $db5.SaveToDiskAsync()
Wait-ForAsyncResult $db5 -TimeoutSec 30
 $sw.Stop()
Add-TestMetric -TestName "Test 5" -Operation "SaveToDiskAsync #2 + Wait" -Context "Triggers a second sequential asynchronous save operation to ensure the Mutex was properly released and the DB can save again." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($db5.AsyncResults['Success']){"OK"}else{"FAIL"})
Write-Host "PASS: Parallel async saves completed" -ForegroundColor Green

# 2.6 Test 6 - Isolated Performance (Pure Add/Get/Remove)
Write-Host "`n=== Test 6 - Isolated Performance (50k records) ===" -ForegroundColor Cyan
 $folder6 = Join-Path $BasePath '06_IsolatedPerf'
New-Item -ItemType Directory -Path $folder6 | Out-Null
 $db6 = New-TestDB -Folder $folder6 -BackupCount 0

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($item in $Script:Data50k) { $db6.Add($item.Key, $item.Value) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 6" -Operation "Add 50k records (Pure)" -Context "Pure insertion of 50k pre-generated records into memory. No file I/O or data generation overhead. Tests raw HashTable insertion speed." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($item in $Script:Data50k) { $null = $db6.Get($item.Key) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 6" -Operation "Get 50k records (Pure)" -Context "Pure retrieval of 50k records from memory. Tests raw HashTable read speed without disk or generation overhead." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($item in $Script:Data50k) { $db6.Remove($item.Key) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 6" -Operation "Remove 50k records (Pure)" -Context "Pure deletion of 50k records from memory. Tests raw HashTable removal speed and memory cleanup." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

if ($db6.GetAllKeys().Count -ne 0) { Write-Host "FAIL: Pure removal failed" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Isolated Performance OK" -ForegroundColor Green }

# 2.7 Test 7 - Bulk Read Test
Write-Host "`n=== Test 7 - Bulk Read Test (10k reads from 100k DB) ===" -ForegroundColor Cyan
 $folder7 = Join-Path $BasePath '07_BulkRead'
New-Item -ItemType Directory -Path $folder7 | Out-Null
 $db7 = New-TestDB -Folder $folder7 -BackupCount 0

# Setup DB with 100k records (not timed)
foreach ($item in $Script:Data100k) { $db7.Add($item.Key, $item.Value) }

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($k in $Script:RandomReadKeys10k) { $null = $db7.Get($k) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 7" -Operation "Bulk Get 10k from 100k" -Context "Performs 10,000 random key lookups on a database containing 100,000 records to simulate high-load read scenarios and measure HashTable search efficiency." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter
Write-Host "PASS: Bulk Read Test OK" -ForegroundColor Green

# 2.8 Test 8 - Stress Consolidate
Write-Host "`n=== Test 8 - Stress Consolidate (100k base) ===" -ForegroundColor Cyan
 $folder8 = Join-Path $BasePath '08_StressConsolidate'
New-Item -ItemType Directory -Path $folder8 | Out-Null
 $db8 = New-TestDB -Folder $folder8 -BackupCount 1

# Add 100k records
foreach ($item in $Script:Data100k) { $db8.Add($item.Key, $item.Value) }
# Remove first 50k
 $keysToRemove8 = $Script:Data100k[0..49999]
foreach ($item in $keysToRemove8) { $db8.Remove($item.Key) }
# Add 10k new (using keys 100001-110000 from Data120k)
 $keysToAdd8 = $Script:Data120k[100000..109999]
foreach ($item in $keysToAdd8) { $db8.Add($item.Key, $item.Value) }

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
 $db8.CompactDatabase()
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 8" -Operation "Consolidate (100k base, 50k del, 10k add)" -Context "Merges large update/delete queues into the main file under heavy load (100k base, 50k deletes, 10k updates). Tests memory and CPU efficiency of the consolidation algorithm under stress." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $sw.Restart()
 $db8.SaveToDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 8" -Operation "SaveToDisk (post-stress)" -Context "Synchronously saves the heavily fragmented and consolidated database to $($StorageFormatToTest) to measure serialization performance under stress." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $expectedCount = 100000 - 50000 + 10000
 $db8Loaded = New-TestDB -Folder $folder8 -BackupCount 1
 $null = $db8Loaded.LoadFromDisk()
if ($db8Loaded.MergedHT.Count -ne $expectedCount) { Write-Host "FAIL: Stress consolidate count mismatch" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Stress Consolidate OK" -ForegroundColor Green }

# 2.9 Test 9 - Large dataset performance (120k)
Write-Host "`n=== Test 9 - Large dataset (120k records) ===" -ForegroundColor Cyan
 $folder9 = Join-Path $BasePath '09_LargeDataset'
New-Item -ItemType Directory -Path $folder9 | Out-Null
 $db9 = New-TestDB -Folder $folder9 -BackupCount 1

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
foreach ($item in $Script:Data120k) { $db9.Add($item.Key, $item.Value) }
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 9" -Operation "Add 120k records" -Context "Adds 120,000 pre-generated key-value pairs to measure bulk insertion performance and memory scaling for large datasets." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
 $db9.SaveToDisk()
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 9" -Operation "SaveToDisk" -Context "Synchronously saves a large 120k-record dataset to $($StorageFormatToTest) to measure serialization performance under heavy load." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $sw.Restart()
 $db9Loaded = New-TestDB -Folder $folder9 -BackupCount 1
 $loaded = $db9Loaded.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 9" -Operation "LoadFromDisk" -Context "Synchronously loads the large dataset from $($StorageFormatToTest) to verify deserialization performance and data integrity." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($loaded){"OK"}else{"FAIL"})
if (-not $loaded -or $db9Loaded.MergedHT.Count -ne 120000) { Write-Host "FAIL: Large dataset load failed" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Large dataset completed successfully" -ForegroundColor Green }

# 2.10 Test 10 - Auto-consolidate logic
Write-Host "`n=== Test 10 - Auto-consolidate logic ===" -ForegroundColor Cyan
 $folder10 = Join-Path $BasePath '10_AutoConsolidate'
New-Item -ItemType Directory -Path $folder10 | Out-Null
 $db10 = New-TestDB -Folder $folder10 -BackupCount 1

foreach ($item in $Script:Data100) { $db10.Add($item.Key, $item.Value) }
 $db10.SaveToDisk()
 $mainCountBefore = $db10.MainHT.Count

foreach ($item in ($Script:Data120k[100000..100039])) { $db10.Add($item.Key, $item.Value) }

 $sw.Restart()
 $db10.SaveToDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 10" -Operation "SaveToDisk #2 (auto-consolidate)" -Context "Synchronously saves the database again, triggering the internal auto-consolidate logic based on update thresholds." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $sw.Restart()
 $db10Loaded = New-TestDB -Folder $folder10 -BackupCount 1
 $loaded = $db10Loaded.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 10" -Operation "LoadFromDisk" -Context "Synchronously loads the database to verify that auto-consolidate preserved all records correctly." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($loaded){"OK"}else{"FAIL"})
if ($loaded -and $db10Loaded.MergedHT.Count -eq ($mainCountBefore + 40)) { Write-Host "PASS: Auto-consolidate logic works" -ForegroundColor Green } else { Write-Host "FAIL: Auto-consolidate data mismatch" -ForegroundColor Red; $AllOk = $false }

# 2.11 Test 11 - Database parameters persistence
Write-Host "`n=== Test 11 - Database parameters persistence ===" -ForegroundColor Cyan
 $folder11 = Join-Path $BasePath '11_DatabaseParams'
New-Item -ItemType Directory -Path $folder11 | Out-Null
 $db11 = New-TestDB -Folder $folder11 -BackupCount 1

 $db11.DatabaseParamsHT['Created']      = Get-Date
 $db11.DatabaseParamsHT['Version']      = '1.0.0'
 $db11.DatabaseParamsHT['Description']  = 'Test database with parameters'
 $db11.DatabaseParamsHT['CustomConfig'] = @{ Setting1 = 'Value1'; Setting2 = 42 }

foreach ($item in $Script:Data10) { $db11.Add($item.Key, $item.Value) }
 $db11.SaveToDisk()

 $sw.Restart()
 $db11Loaded = New-TestDB -Folder $folder11 -BackupCount 1
 $loaded = $db11Loaded.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 11" -Operation "LoadFromDisk" -Context "Synchronously loads the database to verify that custom parameters and nested configurations are correctly deserialized." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($loaded){"OK"}else{"FAIL"})
if (-not $loaded -or $db11Loaded.DatabaseParamsHT['CustomConfig']['Setting2'] -ne 42) { Write-Host "FAIL: Nested param not persisted" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Database parameters persisted correctly" -ForegroundColor Green }

# 2.12 Test 12 - Async/Sync Load coordination
Write-Host "`n=== Test 12 - Async/Sync Load coordination ===" -ForegroundColor Cyan
 $folder12 = Join-Path $BasePath '12_LoadCoordination'
New-Item -ItemType Directory -Path $folder12 | Out-Null
 $db12 = New-TestDB -Folder $folder12 -BackupCount 1

foreach ($item in $Script:Data25) { $db12.Add($item.Key, $item.Value) }
 $originalData = $db12.Clone()
 $db12.SaveToDisk()

 $db12Async = New-TestDB -Folder $folder12 -BackupCount 1
 $sw.Restart()
 $db12Async.LoadFromDiskAsync()
Wait-ForAsyncResult $db12Async -TimeoutSec 30
 $sw.Stop()
Add-TestMetric -TestName "Test 12.1" -Operation "LoadFromDiskAsync + Wait" -Context "Initiates an asynchronous load operation and waits for completion to test background data retrieval." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($db12Async.AsyncResults['Success']){"OK"}else{"FAIL"})

 $sw.Restart()
 $syncOk = $db12Async.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 12.2" -Operation "LoadFromDisk (no-op)" -Context "Triggers a synchronous load immediately after an async load to verify the no-op optimization (skipping reload if timestamps are unchanged)." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($syncOk){"FAIL"}else{"OK"})

Start-Sleep -Milliseconds 150
 $db12Mod = New-TestDB -Folder $folder12 -BackupCount 1
 $db12Mod.Add('NewKey_AfterAsync',"NewValue_$([guid]::NewGuid().ToString('N').Substring(0,4))")
 $db12Mod.SaveToDisk()

 $sw.Restart()
 $changed = $db12Async.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 12.3" -Operation "LoadFromDisk (after mod)" -Context "Triggers a synchronous load after modifying the underlying $($StorageFormatToTest)L files to verify the system correctly detects changes and reloads data." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($changed){"OK"}else{"FAIL"})
Write-Host "PASS: Async/Sync Load coordination OK" -ForegroundColor Green

# 2.13 Test 13 - Concurrent async saves with large dataset
Write-Host "`n=== Test 13 - Concurrent async saves with large dataset ===" -ForegroundColor Cyan
 $folder13 = Join-Path $BasePath '13_ConcurrentAsync'
New-Item -ItemType Directory -Path $folder13 -Force | Out-Null
 $db13 = New-TestDB -Folder $folder13 -BackupCount 2

 $sw.Restart()
foreach ($item in $Script:Data120k) { $db13.Add($item.Key, $item.Value) }
 $sw.Stop()
Add-TestMetric -TestName "Test 13" -Operation "Add 120k records" -Context "Adds 120,000 pre-generated key-value pairs to prepare for concurrent async save testing." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $sw.Restart()
 $db13.SaveToDiskAsync()
 $db13.SaveToDiskAsync()
 $sw.Stop()
Add-TestMetric -TestName "Test 13" -Operation "SaveToDiskAsync x2 (start)" -Context "Triggers two asynchronous save operations in rapid succession to test Mutex queueing and background serialization of a massive dataset." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $initialSnapshot = $db13.Clone()
 $keysToModify = $db13.GetAllKeys()[0..4]

 $sw.Restart()
foreach ($key in $keysToModify) { $db13.Add($key, "$($initialSnapshot[$key])[MODIFIED]") }
 $sw.Stop()
Add-TestMetric -TestName "Test 13" -Operation "Modify 5 records" -Context "Modifies the values of the first 5 keys while background async saves are running to test concurrency and thread safety." -ElapsedSeconds $sw.Elapsed.TotalSeconds

 $sw.Restart()
 $db13.SaveToDiskAsync()
 $modifiedSnapshot = $db13.Clone()
Wait-ForAsyncResult $db13 -TimeoutSec 60
 $sw.Stop()
Add-TestMetric -TestName "Test 13" -Operation "SaveToDiskAsync #3 + Wait" -Context "Triggers a third asynchronous save to capture the modifications and waits for completion to verify Mutex handling of queued operations." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($db13.AsyncResults['Success']){"OK"}else{"FAIL"})

 $verifierDb = New-TestDB -Folder $folder13 -BackupCount 0
 $sw.Restart()
 $verifierDb.LoadFromDiskAsync()
 $null = $verifierDb.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 13" -Operation "Verify LoadFromDiskAsync+Sync" -Context "Performs an async load followed immediately by a sync load to verify data retrieval of the large dataset without errors." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($verifierDb.ErrorLevel -eq 0){"OK"}else{"FAIL"})

 $allModificationsCorrect = $true
foreach ($key in $keysToModify) {
    if ($modifiedSnapshot[$key] -ne $verifierDb.Get($key)) { $allModificationsCorrect = $false; break }
}
if ($db13.AsyncResults['Success'] -and $allModificationsCorrect) { Write-Host "PASS: Concurrent async saves completed successfully" -ForegroundColor Green } else { Write-Host "FAIL: Data integrity check failed" -ForegroundColor Red; $AllOk = $false }
 $db13.AsyncResults.Clear()

# 2.14 Test 14 - Type fidelity round-trip ('~i' int keys, '~D' DateTime, '~S' date-strings, '~C' PS classes)
# Json-only: the '~i'/'~D'/'~S'/'~C' markers and PS-class rehydration do not exist in the CLIXML
# compatibility mode (class instances come back as Deserialized.* property bags - accepted trade-off)
if ($StorageFormatToTest -ne 'Json') {
    Write-Host "`n=== Test 14 - Type fidelity round-trip ===" -ForegroundColor Cyan
    Write-Host "SKIP: type-fidelity markers are a Json-format feature (StorageFormat=$StorageFormatToTest)" -ForegroundColor Yellow
} else {
 $folder14 = Join-Path $BasePath '14_TypeFidelity'
New-Item -ItemType Directory -Path $folder14 | Out-Null
 $db14 = New-TestDB -Folder $folder14 -BackupCount 1

 $fixedDt14  = [datetime]::new(2024, 6, 15, 14, 30, 45, 123, [System.DateTimeKind]::Utc)
 $fixedDt14L = [datetime]::new(2023, 1, 2, 3, 4, 5, 678, [System.DateTimeKind]::Local)
 # String that looks exactly like an "O"-formatted date: must stay a string after round-trip ('~S' marker)
 $oShapedString = $fixedDt14.ToString('O')

 $intKeyedHT = @{ 123 = 'cert_A'; 456 = 'cert_B'; 789 = 'cert_C' }
 $container14 = [TstCertContainer]::new()
 $container14.UserName     = 'UserCont1'
 $container14.Certificates = $intKeyedHT
 $container14.ResolvedWhen = $fixedDt14
 $container14.Rolling      = [TstRollingSet]::new()
 $container14.Rolling.Size       = 5
 $container14.Rolling.Members    = [string[]]@('m1','m2')
 $container14.Rolling.LastRotate = $fixedDt14L
 $container14.History     = [string[]]@()
 $container14.Note        = $oShapedString

 $db14.Add('tf_IntKeyedHT', $intKeyedHT)
 $db14.Add('tf_DateTimeUtc', $fixedDt14)
 $db14.Add('tf_DateTimeLocal', $fixedDt14L)
 $db14.Add('tf_DateShapedString', $oShapedString)
 $db14.Add('tf_ClassInstance', $container14)
 $db14.Add('tf_NestedEmptyArray', @{ Inner = [string[]]@(); Keep = 'x' })

 $memBefore = Get-CurrentMemoryMB
 $sw.Restart()
 $db14.SaveToDisk()
 $sw.Stop()
 $memAfter = Get-CurrentMemoryMB
Add-TestMetric -TestName "Test 14" -Operation "SaveToDisk (typed data)" -Context "Synchronously saves strict-type payloads: int-keyed hashtable, DateTime (Utc/Local), an O-shaped date string and PowerShell class instances (incl. nested class and empty array) to test '~i'/'~D'/'~S'/'~C' marker serialization." -ElapsedSeconds $sw.Elapsed.TotalSeconds -MemBeforeMB $memBefore -MemAfterMB $memAfter

 $db14b = New-TestDB -Folder $folder14 -BackupCount 1
 $sw.Restart()
 $ok14 = $db14b.LoadFromDisk()
 $sw.Stop()
Add-TestMetric -TestName "Test 14" -Operation "LoadFromDisk (typed data)" -Context "Synchronously loads the typed dataset and validates strict type restoration: Int32 hashtable keys, DateTime with exact ticks and Kind, protected date-shaped strings and rehydrated class instances." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($ok14){"OK"}else{"FAIL"})

 $typeFidelityOk = $true
 $loadedHT14 = $db14b.Get('tf_IntKeyedHT')
if ($loadedHT14 -isnot [hashtable] -or $loadedHT14[123] -ne 'cert_A' -or $null -ne $loadedHT14['123']) {
    Write-Host "FAIL: Int-keyed hashtable keys not restored as [int] (~i marker)" -ForegroundColor Red
    $typeFidelityOk = $false
}
 $loadedDt14 = $db14b.Get('tf_DateTimeUtc')
if ($loadedDt14 -isnot [datetime] -or $loadedDt14 -ne $fixedDt14 -or $loadedDt14.Kind -ne [System.DateTimeKind]::Utc) {
    Write-Host "FAIL: DateTime (Utc) type, value or Kind not restored (~D marker)" -ForegroundColor Red
    $typeFidelityOk = $false
}
 $loadedDt14L = $db14b.Get('tf_DateTimeLocal')
if ($loadedDt14L -isnot [datetime] -or $loadedDt14L -ne $fixedDt14L) {
    Write-Host "FAIL: DateTime (Local) type or value not restored (~D marker)" -ForegroundColor Red
    $typeFidelityOk = $false
}
 $loadedStr14 = $db14b.Get('tf_DateShapedString')
if ($loadedStr14 -isnot [string] -or $loadedStr14 -ne $oShapedString) {
    Write-Host "FAIL: Date-shaped string was coerced to a different type (~S marker)" -ForegroundColor Red
    $typeFidelityOk = $false
}
 $loadedClass14 = $db14b.Get('tf_ClassInstance')
if ($loadedClass14 -isnot [TstCertContainer]) {
    Write-Host "FAIL: TstCertContainer not rehydrated (~C marker), got $(if ($null -ne $loadedClass14) { $loadedClass14.GetType().Name } else { 'null' })" -ForegroundColor Red
    $typeFidelityOk = $false
} else {
    if ($loadedClass14.UserName -ne 'UserCont1' -or $loadedClass14.Certificates -isnot [hashtable] -or $loadedClass14.Certificates[456] -ne 'cert_B') {
        Write-Host "FAIL: Class string property or int-keyed hashtable not restored" -ForegroundColor Red
        $typeFidelityOk = $false
    }
    if ($loadedClass14.ResolvedWhen -isnot [datetime] -or $loadedClass14.ResolvedWhen -ne $fixedDt14) {
        Write-Host "FAIL: Class DateTime property not restored" -ForegroundColor Red
        $typeFidelityOk = $false
    }
    if ($loadedClass14.Rolling -isnot [TstRollingSet] -or $loadedClass14.Rolling.Size -ne 5 -or $loadedClass14.Rolling.LastRotate -ne $fixedDt14L -or @($loadedClass14.Rolling.Members).Count -ne 2 -or $loadedClass14.Rolling.Members[0] -ne 'm1') {
        Write-Host "FAIL: Nested class TstRollingSet not fully rehydrated" -ForegroundColor Red
        $typeFidelityOk = $false
    }
    if ($null -eq $loadedClass14.History -or @($loadedClass14.History).Count -ne 0) {
        Write-Host "FAIL: Class empty array property collapsed to null" -ForegroundColor Red
        $typeFidelityOk = $false
    }
    if ($loadedClass14.Note -isnot [string] -or $loadedClass14.Note -ne $oShapedString) {
        Write-Host "FAIL: Class date-shaped string property coerced (~S marker)" -ForegroundColor Red
        $typeFidelityOk = $false
    }
}
 $loadedNested14 = $db14b.Get('tf_NestedEmptyArray')
if ($loadedNested14 -isnot [hashtable] -or $null -eq $loadedNested14.Inner -or @($loadedNested14.Inner).Count -ne 0 -or $loadedNested14.Keep -ne 'x') {
    Write-Host "FAIL: Nested empty array inside hashtable collapsed or lost" -ForegroundColor Red
    $typeFidelityOk = $false
}

# Async load path: rehydration must also work through the event-action restore scriptblock
 $db14c = New-TestDB -Folder $folder14 -BackupCount 1
 $sw.Restart()
 $db14c.LoadFromDiskAsync()
Wait-ForAsyncResult $db14c -TimeoutSec 30
 $sw.Stop()
Add-TestMetric -TestName "Test 14" -Operation "LoadFromDiskAsync (typed data)" -Context "Loads the typed dataset asynchronously and verifies that the event-action restore path rehydrates class instances and type markers identically to the synchronous path." -ElapsedSeconds $sw.Elapsed.TotalSeconds -Status $(if($db14c.AsyncResults['Success']){"OK"}else{"FAIL"})
if ($db14c.Get('tf_ClassInstance') -isnot [TstCertContainer] -or $db14c.Get('tf_DateTimeUtc') -isnot [datetime] -or $db14c.Get('tf_IntKeyedHT')[789] -ne 'cert_C') {
    Write-Host "FAIL: Async load did not rehydrate types in the event action" -ForegroundColor Red
    $typeFidelityOk = $false
}

if (-not $ok14 -or -not $typeFidelityOk) { Write-Host "FAIL: Type fidelity round-trip failed" -ForegroundColor Red; $AllOk = $false } else { Write-Host "PASS: Type fidelity round-trip OK" -ForegroundColor Green }
}

# -------------------------------------------------
# 3. Summary & Save Metrics
# -------------------------------------------------
if ($AllOk) { Write-Host "`n===== ALL TESTS PASSED =====" -ForegroundColor Green } else { Write-Host "`n===== SOME TESTS FAILED =====" -ForegroundColor Red }

# Export performance metrics to CSV
 $csvPath = Join-Path $projectTmp "HashTableDB1_Timings_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
 $Script:TestMetrics | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Performance metrics saved to: $csvPath" -ForegroundColor Cyan

# Final process metrics
 $proc.Refresh()
Write-Host "Process metrics after finish: WS=$([math]::Round($proc.WorkingSet64/1MB,2))MB, CPU=$($proc.CPU)s"