<#
.SYNOPSIS
HashTableDB1 is a high-performance, thread-safe, persistent key-value database for PowerShell. It uses ConcurrentDictionary for in-memory operations and automatically persists to JSON files (with legacy XML fallback). It supports synchronous/asynchronous saving/loading, automatic consolidation, backup rotation, and transaction logging.

.DESCRIPTION
This class is designed for high-load scenarios. It maintains three internal dictionaries: MainHT, UpdatesHT, and RemovedHT. A MergedHT provides a real-time unified view. NEVER modify the internal dictionaries directly; use the class methods. Despite method names containing "XML" (for historical compatibility), the actual persistence format is JSON.

.NOTES
  Version:        1.25
  Author:         Andrew Afanasiev
  Date:           17 Sep 2026
  Contacts:       AfanasievAA@yandex.ru
  !!!! NO Vibecoding here please !!!! This is heavily loaded and intense script. Any wrong "optimization" proposed by your favorite AI will probably end up in data loss! I'm not joking folks. Use your own head before committing any changes to this script.
  If you feel lucky enough to modify this, there are 3 test scripts which you can find and code_testing folder. Fire them up after your modification. Run one by one and ensure there are NO errors in any test, or else you'll end up in data loss.
  For those who did not listen and ruined data. A backup is kept in the OLD subfolder; you can restore it and manually replay changes from the transaction log (TxLog). Do not call me when that happens - You've been warned.

.PROPERTIES
DatabaseFolderPath [string]      : Directory path for database files. Default: ".\"
DatabaseFileName [string]        : Base name for the database files. Default: "HashTableDB"
NumOfDbBackupsToKeep [int]       : Number of backup files to keep in the "OLD" subfolder. 0 = no backups.
EnableTransactionLog [bool]      : Enables transaction logging for differential sync.
TxLogRetentionDays [int]         : Days to retain transaction logs. Default: 3.
DatabaseParamsHT [hashtable]     : Custom metadata hashtable saved alongside the database.
ReadOnlyMode [bool]              : If true, prevents saving.
ErrorLevel [string/int]          : 0 on success, error code string on failure.
ErrorText [string]               : Error description.
MainFileLoadedDT, UpdatesFileLoadedDT, RemovedFileLoadedDT [DateTime] : Timestamps of loaded files.
MainHT, UpdatesHT, MergedHT, RemovedHT : Internal thread-safe states. DO NOT MODIFY DIRECTLY.

.METHODS
[void] CreateEmptyDB() : Clears all internal hashtables and resets state.
[void] Add($KeyName, $HashValue) : Adds or updates a key with the specified value.
[void] Remove($KeyName) : Marks a key as removed.
[void] UpsertNestedHashTableKey($KeyName, $SecondaryKey, $SecondaryKeyValue=1) : Thread-safe upsert of a secondary key inside a hashtable value.
[void] RemoveNestedHashTableKey($KeyName, $SecondaryKey) : Thread-safe removal of a secondary key.
[object] Get($KeyName) : Retrieves a value by key.
[object] GetAllKeys() : Returns all active keys in the database.
[object] GetAllValues() : Returns all active values.
[bool] ContainsKey($KeyName) : Checks if a key exists.
[hashtable] Clone() : Creates a deep copy of the current MergedHT as a standard hashtable.
[void] CompactDatabase() : Forces merging of UpdatesHT and RemovedHT into MainHT and clears update queues.
[void] SaveToDisk() : Synchronously saves the database to JSON files.
[void] SaveToDiskAsync() : Asynchronously saves the database using background runspaces.
[void] WaitForAsyncSaveToDisk() : Blocks execution until the current async save completes.
[bool] LoadFromDisk() : Synchronously loads the database from JSON files. Returns $true if data was loaded/updated.
[void] LoadFromDiskAsync() : Asynchronously loads the database in the background.
[void] WaitForAsyncLoadFromDisk() : Blocks execution until the current async load completes.
[void] EnsureDBFolderWithPermissions($SID, [bool]$AllowWrite = $false) : Creates the folder and sets ACLs for a specific SID.
[void] Dispose() : Waits for async operations, cleans up runspaces, and clears memory.

.EXAMPLE
### 1. Initialization and Basic Usage
$db = [HashTableDB1]::new()
$db.DatabaseFolderPath = "C:\Temp\MyDB"
$db.DatabaseFileName = "AppData"
$db.NumOfDbBackupsToKeep = 3
$db.EnableTransactionLog = $true

# Create folder if missing
$db.EnsureDBFolderWithPermissions($null)

# Load existing data (returns $true if loaded, $false if not found/no changes)
$null = $db.LoadFromDisk()

# Add / Update data
$db.Add("User1", @{ Name = "Alice"; Role = "Admin" })
$db.Add("User2", @{ Name = "Bob"; Role = "User" })

# Add secondary keys safely
$db.UpsertNestedHashTableKey("User1", "Permissions", "FullAccess")

# Read data
$user1 = $db.Get("User1")

# Remove data
$db.Remove("User2")

.EXAMPLE
$db.SaveToDisk()
# Force merge updates into main file to keep update file small
$db.CompactDatabase()
$db.SaveToDisk()

.EXAMPLE
### 3. Asynchronous Save with Wait
$db.Add("User3", @{ Name = "Charlie" })
$db.SaveToDiskAsync() # Non-blocking save
# Do other work here...
# Wait for background save to finish before exiting or disposing
$db.WaitForAsyncSaveToDisk()

# Cleanup
$db.Dispose()

.EXAMPLE
### 4. Using Database Parameters
$db.DatabaseParamsHT["Version"] = "1.0.0"
$db.DatabaseParamsHT["LastModifiedBy"] = $env:USERNAME
$db.SaveToDisk() # Parameters are saved automatically inside the deletes file.
#>

# Registering C# converter for System.Text.Json to handle PowerShell objects natively and fast
 $psConverterType = 'PSObjectJsonConverter' -as [type]
if ($psConverterType -and -not $psConverterType.GetMethod('BuildConcurrentDictionary', [System.Reflection.BindingFlags]'Public, Static')) {
    # Add-Type cannot hot-reload a compiled type: if an older PSObjectJsonConverter is already loaded in
    # this process, the guard below silently skips compilation while the PowerShell code keeps calling
    # methods the old type lacks - every load then fails with a hidden MethodNotFound (LFX8, empty DB).
    throw "PSObjectJsonConverter is already loaded from an outdated version (missing static BuildConcurrentDictionary). Close and reopen the PowerShell session, then run again."
}
if (-not $psConverterType) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Reflection;

/// <summary>
/// Custom JSON converter for System.Text.Json optimized for PowerShell objects. Natively handles PSObject, Hashtable, ArrayList, and falls back to CLIXML for complex types.
/// </summary>
public class PSObjectJsonConverter : JsonConverter<object> {
    // Regex to minify CLIXML output by removing whitespace between XML tags, reducing JSON size
    private static readonly System.Text.RegularExpressions.Regex _xmlMinifyRegex = 
        new System.Text.RegularExpressions.Regex(@">\s+<", System.Text.RegularExpressions.RegexOptions.Compiled);

    // Cache for type categorization to avoid expensive reflection on every Write call. 0=unknown, 1=non-generic dict (e.g. Hashtable), 2=generic dict, 3=non-generic list (e.g. ArrayList), 4=generic list
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<Type, int> _typeKindCache = 
        new System.Collections.Concurrent.ConcurrentDictionary<Type, int>();

    // Determines the dictionary/list kind of a type using cached reflection
    private static int GetTypeKind(Type t) {
        return _typeKindCache.GetOrAdd(t, tp => {
            if (typeof(IDictionary).IsAssignableFrom(tp)) return 1;
            foreach (var i in tp.GetInterfaces()) {
                if (i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IDictionary<,>)) return 2;
            }
            if (typeof(IList).IsAssignableFrom(tp)) return 3;
            foreach (var i in tp.GetInterfaces()) {
                if (i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IList<>)) return 4;
            }
            return 0;
        });
    }

    // Max recursion depth to prevent StackOverflowException on circular object references
    private const int MaxDepth = 100;
    // Thread-static depth tracker to avoid thread contention and locks during serialization
    [ThreadStatic] private static int _currentDepth;
    // Thread-static flag set by Read when a '~C' class marker is encountered. Lets PowerShell skip the
    // expensive full-tree RestoreClasses traversal for data guaranteed to contain no class instances.
    [ThreadStatic] private static bool _sawClassMarker;

    // Resets '~C' marker detection for the current thread. Call before deserializing a batch of files.
    public static void ResetClassMarkerDetection() { _sawClassMarker = false; }

    // True if Deserialize on this thread has seen at least one '~C' marker since the last reset
    public static bool HasReadClassMarkers() { return _sawClassMarker; }

    // Class-name resolution is passed from PowerShell as System.Func<string, System.Type> (a BCL type,
    // always resolvable at PowerShell class compile time) because user class types live in the session
    // state, invisible to this assembly.

    // Fast C# replacement for the slow PowerShell traversal in RestoreClassesScriptBlock/Phase 3:
    // walks all container roots (IDictionary / Array / PSObject) iteratively with a stack and a
    // reference-identity visited set, and collects '~C' hashtable nodes together with their exact
    // parent container and slot (dictionary key / array index / property name). Nodes are appended
    // in DFS order (containers before children); process the list in reverse to rehydrate children
    // before their parents copy them out of raw hashtables.
    public static List<object[]> CollectClassNodes(object[] roots) {
        var pending = new List<object[]>();
        if (roots == null) { return pending; }
        var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<object[]>();
        foreach (var root in roots) {
            if (root != null) { stack.Push(new object[] { null, null, root }); }
        }
        while (stack.Count > 0) {
            var frame = stack.Pop();
            var node = frame[2];
            if (node == null) { continue; }
            var ht = node as System.Collections.IDictionary;
            if (ht != null) {
                if (visited.Add(node)) {
                    if (ht.Contains("~C")) { pending.Add(frame); }
                    foreach (System.Collections.DictionaryEntry e in ht) {
                        if (e.Value != null) { stack.Push(new object[] { ht, e.Key, e.Value }); }
                    }
                }
            } else {
                var arr = node as System.Array;
                if (arr != null) {
                    if (visited.Add(node)) {
                        for (int i = 0; i < arr.Length; i++) {
                            if (arr.GetValue(i) != null) { stack.Push(new object[] { arr, i, arr.GetValue(i) }); }
                        }
                    }
                } else {
                    PSObject pso = node as PSObject;
                    if (pso != null && !(node is System.Management.Automation.PSCustomObject)) { pso = null; }
                    // Only descend into PSCustomObject instances (deserialized class-ish shapes);
                    // other PSObject wrappers unwrap to their BaseObject elsewhere
                    if (pso == null && node is System.Management.Automation.PSCustomObject) {
                        pso = (PSObject)node;
                    }
                    if (pso != null && visited.Add(node)) {
                        foreach (var prop in pso.Properties) {
                            if (prop.IsSettable && prop.Value != null) { stack.Push(new object[] { pso, prop.Name, prop.Value }); }
                        }
                    }
                }
            }
        }
        return pending;
    }

    // Fast C# replacement for the slow PowerShell rehydration in TryRehydrateScriptBlock:
    // creates a live class instance and maps hashtable properties via reflection.
    // conversion via LanguagePrimitives preserves PowerShell assignment semantics.
    // Returns null when not applicable/possible - the caller then falls back to the PS scriptblock.
    public static object RehydrateClassNode(System.Collections.IDictionary node, System.Func<string, System.Type> resolver) {
        if (node == null) { return null; }
        string className = node["~C"] as string;
        if (className == null) { return null; }
        if (resolver == null) { return null; }
        Type targetType = null;
        try { targetType = resolver(className); } catch { targetType = null; }
        if (targetType == null) { return null; }
        object instance = null;
        try {
            instance = System.Activator.CreateInstance(targetType);
        } catch {
            instance = null;
        }
        if (instance == null) { return null; }
        bool mapped = false;
        foreach (System.Collections.DictionaryEntry e in node) {
            string k = e.Key as string;
            if (k == null || k == "~C") { continue; }
            PropertyInfo prop = targetType.GetProperty(k, BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);
            if (prop != null && prop.CanWrite) {
                try {
                    object converted = System.Management.Automation.LanguagePrimitives.ConvertTo(e.Value, prop.PropertyType);
                    if (converted != null || !prop.PropertyType.IsValueType) { prop.SetValue(instance, converted); }
                    mapped = true;
                } catch {
                    // Skip properties that fail conversion instead of aborting the whole instance
                }
            }
        }
        // If the type exposes a LoadFromData method, let it rebuild derived/internal state
        // (e.g. hidden caches like RollingSet.nodeDict) from the raw property map
        bool loaded = false;
        MethodInfo loadFromData = targetType.GetMethod("LoadFromData", BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);
        if (loadFromData != null && loadFromData.GetParameters().Length == 1) {
            try {
                object ret = loadFromData.Invoke(instance, new object[] { node });
                if (ret is bool && (bool)ret) { loaded = true; }
            } catch { }
        }
        if (!mapped && !loaded) { return null; }
        return instance;
    }

    // Fast C# replacement for the slow PowerShell copy loops in Clone() and the save snapshot:
    // builds a case-insensitive Hashtable from any IDictionary (hashtable, ConcurrentDictionary,
    // generic Dictionary - all implement the non-generic IDictionary interface)
    public static System.Collections.Hashtable BuildHashtable(System.Collections.IDictionary source) {
        var ht = new System.Collections.Hashtable(System.StringComparer.OrdinalIgnoreCase);
        if (source == null) { return ht; }
        foreach (System.Collections.DictionaryEntry e in source) {
            ht[e.Key] = e.Value;
        }
        return ht;
    }

    // Fast C# replacement for slow PowerShell copy loops: builds a ConcurrentDictionary from a deserialized IDictionary
    public static System.Collections.Concurrent.ConcurrentDictionary<string, object> BuildConcurrentDictionary(System.Collections.IDictionary source, string excludeKey) {
        var cd = new System.Collections.Concurrent.ConcurrentDictionary<string, object>(System.StringComparer.OrdinalIgnoreCase);
        if (source == null) { return cd; }
        foreach (System.Collections.DictionaryEntry e in source) {
            string k = e.Key as string;
            if (k == null) { k = e.Key.ToString(); }
            if (excludeKey != null && string.Equals(k, excludeKey, StringComparison.Ordinal)) { continue; }
            cd[k] = e.Value;
        }
        return cd;
    }

    // Fast C# replacement for slow PowerShell merge loops: merged = main + updates - removed
    public static System.Collections.Concurrent.ConcurrentDictionary<string, object> BuildMergedDictionary(System.Collections.Concurrent.ConcurrentDictionary<string, object> mainCd, System.Collections.Concurrent.ConcurrentDictionary<string, object> updatesCd, System.Collections.Concurrent.ConcurrentDictionary<string, object> removedCd) {
        var merged = new System.Collections.Concurrent.ConcurrentDictionary<string, object>(System.StringComparer.OrdinalIgnoreCase);
        if (mainCd != null) { foreach (var e in mainCd) { merged[e.Key] = e.Value; } }
        if (updatesCd != null) { foreach (var e in updatesCd) { merged[e.Key] = e.Value; } }
        if (removedCd != null) { object dummy; foreach (var e in removedCd) { merged.TryRemove(e.Key, out dummy); } }
        return merged;
    }

    // Deserializes JSON into PowerShell native types (Hashtable, ArrayList, etc.)
    public override object Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) {
        switch (reader.TokenType) {
            case JsonTokenType.True: return true;
            case JsonTokenType.False: return false;
            case JsonTokenType.Number:
                // Try parsing from smallest to largest numeric type to match PowerShell native type semantics (e.g. Int32 for 1)
                if (reader.TryGetInt32(out int i)) return i;
                if (reader.TryGetInt64(out long l)) return l;
                if (reader.TryGetUInt32(out uint ui)) return ui;
                if (reader.TryGetUInt64(out ulong ul)) return (decimal)ul;
                if (reader.TryGetDecimal(out decimal dec)) return dec;
                if (reader.TryGetDouble(out double d)) return d;
                // Last-resort fallback for multi-segment numbers. NOTE: Do not replace this with ValueSequence operations (e.g. CopyTo or ToArray). PowerShell Add-Type compiler struggles with System.Memory/Span<T> extension methods (CS1061/CS1929). Multi-segment numbers are practically impossible in standard JSON (numbers are short tokens). Returning 0 for this impossible edge case is the safest compatible fallback.
                if (!reader.HasValueSequence) {
                    return System.Text.Encoding.UTF8.GetString(reader.ValueSpan.ToArray());
                }
                return 0;
            case JsonTokenType.String:
                // ISO 8601 starts with 'yyyy-MM-dd' so position 4 must be '-'. Note: TryGetDateTime only (not DateTimeOffset) to maintain backward compatibility with consuming modules that expect System.DateTime. NOTE: Do not use reader.ValueSpan here. PowerShell Add-Type compiler struggles with System.Memory/Span<T> extension methods (CS1061/CS1929).
                var str = reader.GetString();
                if (str != null && str.Length >= 10 && str[4] == '-' && str[0] >= '0' && str[0] <= '9') {
                    if (reader.TryGetDateTime(out DateTime dt)) return dt;
                }
                return str;
            case JsonTokenType.StartObject:
                // Map JSON objects to case-insensitive Hashtable to match PowerShell semantics. If __PSCustomObject__ marker is present, deserialize as PSCustomObject (PSObject) to preserve exact type.
                var ht = new Hashtable(StringComparer.OrdinalIgnoreCase);
                bool isPsCustomObject = false;
                // '~i' marker: all keys of the source dictionary were Int32; restore them as Int32 keys
                bool isIntKeys = false;
                // '~D'/'~m'/'~S' value wrappers: restore exact DateTime / Decimal / protect date-shaped strings
                bool isDateTimeValue = false;
                DateTime markerDateTime = default(DateTime);
                bool isDecimalValue = false;
                decimal markerDecimal = default(decimal);
                bool isStringValue = false;
                string markerString = null;
                while (reader.Read()) {
                    if (reader.TokenType == JsonTokenType.EndObject) {
                        if (isDateTimeValue) {
                            return markerDateTime;
                        }
                        if (isDecimalValue) {
                            return markerDecimal;
                        }
                        if (isStringValue) {
                            return markerString;
                        }
                        if (isPsCustomObject) {
                            PSObject pso = new PSObject();
                            foreach (DictionaryEntry entry in ht) {
                                pso.Properties.Add(new PSNoteProperty(entry.Key.ToString(), entry.Value));
                            }
                            return pso;
                        }
                        return ht;
                    }
                    string propName = reader.GetString();
                    reader.Read();
                    // Track '~C' class markers so callers can skip the RestoreClasses traversal when no classes are present
                    if (propName == "~C") { _sawClassMarker = true; }
                    // Intercept short marker to restore exact type. '~' is used as a rare single-byte property name to minimize JSON size without clashing with standard PS properties.
                    if (propName == "~" && reader.TokenType == JsonTokenType.True) {
                        isPsCustomObject = true;
                        continue;
                    }
                    // Int32 key marker: written only when ALL source keys were Int32, so a real "~i" string key never coexists with it
                    if (propName == "~i" && reader.TokenType == JsonTokenType.True) {
                        isIntKeys = true;
                        continue;
                    }
                    // DateTime wrapper written by WriteInternal to guarantee exact type restoration
                    if (propName == "~D" && reader.TokenType == JsonTokenType.String) {
                        string dtRaw = reader.GetString();
                        if (dtRaw != null && DateTime.TryParseExact(dtRaw, "O", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out DateTime dtParsed)) {
                            markerDateTime = dtParsed;
                            isDateTimeValue = true;
                            continue;
                        }
                    }
                    // Decimal wrapper written by WriteInternal to guarantee exact type and scale restoration
                    if (propName == "~m" && reader.TokenType == JsonTokenType.String) {
                        string decRaw = reader.GetString();
                        if (decRaw != null && decimal.TryParse(decRaw, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out decimal decParsed)) {
                            markerDecimal = decParsed;
                            isDecimalValue = true;
                            continue;
                        }
                    }
                    // String wrapper protecting date-shaped strings from legacy DateTime auto-detection
                    if (propName == "~S" && reader.TokenType == JsonTokenType.String) {
                        markerString = reader.GetString();
                        isStringValue = true;
                        continue;
                    }
                    // Intercept CLIXML wrapper to deserialize complex objects that were serialized via PSSerializer
                    if (propName == "__CLIXML__" && reader.TokenType == JsonTokenType.String) {
                        // Read CLIXML and consume the closing EndObject of the wrapper to leave reader in a valid state for the parent loop.
                        string clixml = reader.GetString();
                        reader.Read(); // Advance from String to EndObject
                        try {
                            return PSSerializer.Deserialize(clixml);
                        } catch {
                            // If CLIXML is corrupted, fallback to returning a hashtable with the raw string
                            var fallbackHt = new Hashtable(StringComparer.OrdinalIgnoreCase);
                            fallbackHt["__CLIXML__"] = clixml;
                            return fallbackHt;
                        }
                    }
                    // Restore Int32 keys when the '~i' marker was present
                    if (isIntKeys && int.TryParse(propName, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out int intKey)) {
                        ht[intKey] = Read(ref reader, typeof(object), options);
                    } else {
                        ht[propName] = Read(ref reader, typeof(object), options);
                    }
                }
                return ht;
            case JsonTokenType.StartArray:
                // Map JSON arrays to ArrayList, then convert to object[] for standard PowerShell array representation
                var list = new System.Collections.ArrayList();
                while (reader.Read()) {
                    if (reader.TokenType == JsonTokenType.EndArray) return list.ToArray();
                    list.Add(Read(ref reader, typeof(object), options));
                }
                return list.ToArray();
            default: return null;
        }
    }

    // Entry point for serialization. Manages depth tracking to prevent infinite loops.
    public override void Write(Utf8JsonWriter writer, object value, JsonSerializerOptions options) {
        if (value == null) { writer.WriteNullValue(); return; }
        if (_currentDepth > MaxDepth) {
            writer.WriteStringValue("__MAX_DEPTH_REACHED__");
            return;
        }
        _currentDepth++;
        try {
            WriteInternal(writer, value, options);
        } finally {
            _currentDepth--;
        }
    }

    // Core serialization logic. Unwraps PSObject and maps types to JSON efficiently.
    private void WriteInternal(Utf8JsonWriter writer, object value, JsonSerializerOptions options) {
        if (value == null) { writer.WriteNullValue(); return; }

        // Unwrap PSObject only when NOT PSCustomObject, otherwise we'd lose deserialized properties
        if (value is PSObject) {
            PSObject psoVal = (PSObject)value;
            if (!(psoVal.BaseObject is PSObject) && psoVal.BaseObject.GetType() != typeof(System.Management.Automation.PSCustomObject)) {
                // For deserialized collections (e.g., Hashtable+ValueCollection), PSSerializer wraps IE items in an ArrayList and stores the original keyed data in a SyncRoot NoteProperty. Unwrapping to BaseObject correctly serializes the array of values. Replacing it with SyncRoot would incorrectly promote the underlying Hashtable, causing it to be serialized and loaded as a Hashtable instead of an array.
                value = psoVal.BaseObject;
            }
        }

        Type t = value.GetType();
        int kind = GetTypeKind(t);

        // Serialize dictionaries based on their generic/non-generic nature
        if (kind == 1) {
            writer.WriteStartObject();
            // Snapshot entries and detect all-Int32 keys to emit the '~i' marker for exact key type restoration
            var dictEntries = new List<DictionaryEntry>();
            bool hasEntries = false;
            bool allIntKeys = true;
            foreach (DictionaryEntry entry in (IDictionary)value) {
                dictEntries.Add(entry);
                hasEntries = true;
                if (!(entry.Key is int)) { allIntKeys = false; }
            }
            if (hasEntries && allIntKeys) {
                // '~i' is a string property so it can never collide with an Int32 key
                writer.WritePropertyName("~i");
                writer.WriteBooleanValue(true);
            }
            foreach (DictionaryEntry entry in dictEntries) {
                writer.WritePropertyName(entry.Key == null ? "null" : entry.Key.ToString());
                Write(writer, entry.Value, options);
            }
            writer.WriteEndObject();
        } else if (kind == 2) {
            writer.WriteStartObject();
            // Snapshot entries and detect all-Int32 keys to emit the '~i' marker for exact key type restoration
            var genEntries = new List<dynamic>();
            bool hasGenEntries = false;
            bool allGenIntKeys = true;
            foreach (dynamic entry in (IEnumerable)value) {
                genEntries.Add(entry);
                hasGenEntries = true;
                if (!((object)entry.Key is int)) { allGenIntKeys = false; }
            }
            if (hasGenEntries && allGenIntKeys) {
                writer.WritePropertyName("~i");
                writer.WriteBooleanValue(true);
            }
            foreach (dynamic entry in genEntries) {
                writer.WritePropertyName(entry.Key == null ? "null" : entry.Key.ToString());
                Write(writer, entry.Value, options);
            }
            writer.WriteEndObject();
        // Serialize lists based on their generic/non-generic nature
        } else if (kind == 3) {
            writer.WriteStartArray();
            foreach (var item in (IList)value) {
                Write(writer, item, options);
            }
            writer.WriteEndArray();
        } else if (kind == 4) {
            writer.WriteStartArray();
            foreach (var item in (IEnumerable)value) {
                Write(writer, item, options);
            }
            writer.WriteEndArray();
        // Serialize PSCustomObject properties directly
        } else if (value is PSObject) {
            // Serialize PSObject properties directly without losing them. Add a short marker property to ensure it deserializes back as a PSObject (PSCustomObject), not a Hashtable.
            PSObject pso = (PSObject)value;
            writer.WriteStartObject();
            writer.WritePropertyName("~");
            writer.WriteBooleanValue(true);
            foreach (var prop in pso.Properties) {
                if (prop.IsGettable) {
                    writer.WritePropertyName(prop.Name);
                    Write(writer, prop.Value, options);
                }
            }
            writer.WriteEndObject();
        // Handle native primitive types and common .NET types explicitly for speed
        } else if (t == typeof(string)) {
            // Protect date-shaped strings with the '~S' wrapper so they are not auto-converted to DateTime on load
            string sVal = (string)value;
            if (sVal != null && sVal.Length >= 10 && sVal[4] == '-' && sVal[0] >= '0' && sVal[0] <= '9'
                && DateTime.TryParseExact(sVal, "O", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out DateTime sAsDt)) {
                writer.WriteStartObject();
                writer.WritePropertyName("~S");
                writer.WriteStringValue(sVal);
                writer.WriteEndObject();
            } else {
                writer.WriteStringValue(sVal);
            }
        } else if (t == typeof(DateTime)) {
            // Wrap DateTime in a '~D' marker object with round-trip "O" format to guarantee exact type restoration (DateTimeKind preserved)
            writer.WriteStartObject();
            writer.WritePropertyName("~D");
            writer.WriteStringValue(((DateTime)value).ToString("O", System.Globalization.CultureInfo.InvariantCulture));
            writer.WriteEndObject();
        } else if (t == typeof(DateTimeOffset)) {
            writer.WriteStringValue((DateTimeOffset)value);
        } else if (t == typeof(TimeSpan)) {
            writer.WriteStringValue(((TimeSpan)value).ToString());
        } else if (t == typeof(Guid)) {
            writer.WriteStringValue((Guid)value);
        } else if (t == typeof(decimal)) {
            // Wrap Decimal in a '~m' marker object to guarantee exact type/scale restoration regardless of numeric token formatting quirks
            writer.WriteStartObject();
            writer.WritePropertyName("~m");
            writer.WriteStringValue(((decimal)value).ToString("R", System.Globalization.CultureInfo.InvariantCulture));
            writer.WriteEndObject();
        } else if (t == typeof(bool)) {
            writer.WriteBooleanValue((bool)value);
        } else if (t == typeof(char)) {
            writer.WriteStringValue(value.ToString());
        } else if (t == typeof(int)) {
            writer.WriteNumberValue((int)value);
        } else if (t == typeof(long)) {
            writer.WriteNumberValue((long)value);
        } else if (t == typeof(double)) {
            double dv = (double)value;
            if (double.IsNaN(dv) || double.IsInfinity(dv)) { writer.WriteNullValue(); }
            else { writer.WriteNumberValue(dv); }
        } else if (t == typeof(float)) {
            float fv = (float)value;
            if (float.IsNaN(fv) || float.IsInfinity(fv)) { writer.WriteNullValue(); }
            else { writer.WriteNumberValue(fv); }
        } else if (t == typeof(byte)) {
            writer.WriteNumberValue((byte)value);
        } else if (t == typeof(sbyte)) {
            writer.WriteNumberValue((sbyte)value);
        } else if (t == typeof(short)) {
            writer.WriteNumberValue((short)value);
        } else if (t == typeof(ushort)) {
            writer.WriteNumberValue((ushort)value);
        } else if (t == typeof(uint)) {
            writer.WriteNumberValue((uint)value);
        } else if (t == typeof(ulong)) {
            writer.WriteNumberValue((ulong)value);
        } else if (t.IsPrimitive) {
            JsonSerializer.Serialize(writer, value, t, options);
        // Fallback to CLIXML for any complex object that cannot be natively mapped to JSON
        } else {
            // PowerShell classes and user-defined (non System/Microsoft namespace) types are serialized as a property map with a '~C' class-name marker so RestoreClasses can rehydrate real class instances after load. System.*/Microsoft.* types (X509Certificate2 etc.) keep the CLIXML fallback below.
            string typeNamespace = t.Namespace ?? string.Empty;
            bool isUserType = !typeNamespace.StartsWith("System", System.StringComparison.Ordinal) && !typeNamespace.StartsWith("Microsoft", System.StringComparison.Ordinal);
            if (isUserType) {
                PSObject psoType = PSObject.AsPSObject(value);
                writer.WriteStartObject();
                writer.WritePropertyName("~C");
                writer.WriteStringValue(t.FullName);
                foreach (var prop in psoType.Properties) {
                    if (prop.IsGettable) {
                        writer.WritePropertyName(prop.Name);
                        Write(writer, prop.Value, options);
                    }
                }
                writer.WriteEndObject();
            } else {
                // Fallback for complex types (X509Certificate2 etc.)
                try {
                    string clixml = PSSerializer.Serialize(value);
                    clixml = _xmlMinifyRegex.Replace(clixml, "><");
                    writer.WriteStartObject();
                    writer.WritePropertyName("__CLIXML__");
                    writer.WriteStringValue(clixml);
                    writer.WriteEndObject();
                } catch {
                    writer.WriteStringValue(value.ToString());
                }
            }
        }
    }
}
'@
}
# Verify the loaded converter actually contains the static helpers the load path depends on.
# Catches a file where the C# converter edits were not applied (methods missing after compilation).
foreach ($requiredConverterMethod in 'ResetClassMarkerDetection','HasReadClassMarkers','BuildConcurrentDictionary','BuildMergedDictionary','BuildHashtable','CollectClassNodes','RehydrateClassNode') {
    if (-not [PSObjectJsonConverter].GetMethod($requiredConverterMethod, [System.Reflection.BindingFlags]'Public, Static')) {
        throw "PSObjectJsonConverter is missing static method '$requiredConverterMethod' - the C# converter edits were not applied to this file. Apply them, then restart the PowerShell session and run again."
    }
}

# Start of main scriptblock to save database. Used by class object later
 $Script:HashtableDB1Class_SaveScriptBlock = {
    param(
        [object]   $thisObj,
        [object]   $mainSnap,
        [object]   $updatesSnap,
        [object]   $removedSnap
    )
    # Inner function of preserving old versions and rotating
    function _MoveOld {
        param(
            [string] $folder,
            [string] $baseName,
            [int]    $bakCount,
            [string] $TimeStamp
        )
        if ($bakCount -le 0) { return }
        $oldFolder = Join-Path $folder "OLD"
        if (-not [System.IO.Directory]::Exists($oldFolder)) {
            $null = [System.IO.Directory]::CreateDirectory($oldFolder)
        }
        # Renaming *.old to a timestamp extension
        $oldPath = "$(Join-Path $folder $baseName).old"
        if ([System.IO.File]::Exists($oldPath)) {
            $newBackupName = "$baseName.$TimeStamp"
            $dest = Join-Path $oldFolder $newBackupName
            for ($i = 0; $i -lt 5; $i++) {
                try {
                    if ([System.IO.File]::Exists($dest)) { [System.IO.File]::Delete($dest) }
                    [System.IO.File]::Move($oldPath, $dest)
                    break
                } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                    Start-Sleep -Milliseconds 100
                    if ($i -eq 4) { throw }
                }
            }
            Write-Host "Created backup: $newBackupName"
        }
        # All backup files for this backup. Matches current-format backups, legacy XML backups and cross-format archived JSON backups. Escape baseName to avoid regex injection.
        $rxBak = [regex]::new('^' + [regex]::Escape($baseName) + '\.\d{8}-\d{6}(\.(xml|json))?$')
        $backupFiles = [System.IO.Directory]::GetFiles($oldFolder, "$baseName.*") |
            ForEach-Object { [System.IO.FileInfo]::new($_) } |
            Where-Object { $rxBak.IsMatch($_.Name) }
        # Coerce to array so .Count is reliable for single-element results
        $backupFiles = @($backupFiles)
        if ($backupFiles.Count -gt $bakCount) {
            # Sort by Name (yyyyMMdd-HHmmss is lexicographically chronological)
            $filesToDelete = $backupFiles | Sort-Object Name | Select-Object -First ($backupFiles.Count - $bakCount)
            # Deleting oldest files with retry for high-load file locking
            foreach ($fileToDelete in $filesToDelete) {
                for ($i = 0; $i -lt 5; $i++) {
                    try {
                        [System.IO.File]::Delete($fileToDelete.FullName)
                        break
                    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                        Start-Sleep -Milliseconds 100
                    }
                }
            }
        }
    } # Of _MoveOld
    # Helper for resilient file ops with retry on IO contention (AV, indexer, etc.)
    function _RetryFileOp {
        param([scriptblock]$Op, [int]$Attempts = 5, [int]$DelayMs = 100)
        for ($i = 0; $i -lt $Attempts; $i++) {
            try { & $Op; return }
            catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                if ($i -eq ($Attempts - 1)) { throw }
                Start-Sleep -Milliseconds $DelayMs
            }
        }
    }
    try {
        $startDateTime = [System.Datetime]::Now
        $jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
        $jsonOptions.Converters.Add([PSObjectJsonConverter]::new())
        # Disable escaping of <, > and non-ASCII to reduce JSON size
        $jsonOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
        # Storage format: 'Json' (default) or 'Xml' (CLIXML compatibility mode). All file names are
        # parameterized by extension so the folder always holds files of a single format.
        if ($thisObj.StorageFormat -notin @('Json','Xml')) { throw "Invalid StorageFormat '$($thisObj.StorageFormat)' - use 'Json' or 'Xml'." }
        $ext = 'json'
        if ($thisObj.StorageFormat -eq 'Xml') { $ext = 'xml' }
        $tmpMain = $null
        $tmpUpdates = $null
        $tmpDeletes = $null
        # New data is saved to *.tmp files. Main file saved only if modified
        if ($thisObj.IsForceSaveMain) {
            $tmpMain = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.$ext.tmp"
            if ($ext -eq 'xml') {
                # CLIXML compatibility mode. Explicit depth is required: the parameterless Serialize
                # overload silently truncates nested objects at depth 2.
                [System.IO.File]::WriteAllText($tmpMain, [System.Management.Automation.PSSerializer]::Serialize($mainSnap, 100))
            } else {
                # OPTIMIZATION: System.Text.Json streaming directly to FileStream.
                # Stream is disposed in finally to release handle even on serialization failure.
                # 1MB buffer: fewer, larger write syscalls on multi-hundred-MB JSON files
                $stream = [System.IO.File]::Create($tmpMain, 1048576)
                try {
                    [System.Text.Json.JsonSerializer]::Serialize($stream, [object]$mainSnap, $jsonOptions)
                } finally {
                    $stream.Dispose()
                }
            }
        }
        $tmpUpdates = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.$ext.tmp"
        if ($ext -eq 'xml') {
            # CLIXML compatibility mode (explicit depth - see the main-file block above)
            [System.IO.File]::WriteAllText($tmpUpdates, [System.Management.Automation.PSSerializer]::Serialize($updatesSnap, 100))
        } else {
            $stream = [System.IO.File]::Create($tmpUpdates, 1048576)
            try {
                [System.Text.Json.JsonSerializer]::Serialize($stream, [object]$updatesSnap, $jsonOptions)
            } finally {
                $stream.Dispose()
            }
        }
        # Adding database parameters to a copy for serialization (avoid polluting live RemovedHT).
        # C# helper replaces the slow PowerShell copy loop; the type is process-wide, so it resolves
        # both on the calling thread and inside the background runspace
        $removedForSave = [PSObjectJsonConverter]::BuildHashtable($removedSnap)
        # Database parameters travel inside the deletes snapshot (read back by the load path)
        $removedForSave["___DATABASEPARAMS___"] = $thisObj.DatabaseParamsHT
        $tmpDeletes = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.$ext.tmp"
        if ($ext -eq 'xml') {
            # CLIXML compatibility mode (explicit depth - see the main-file block above)
            [System.IO.File]::WriteAllText($tmpDeletes, [System.Management.Automation.PSSerializer]::Serialize($removedForSave, 100))
        } else {
            $stream = [System.IO.File]::Create($tmpDeletes, 1048576)
            try {
                [System.Text.Json.JsonSerializer]::Serialize($stream, [object]$removedForSave, $jsonOptions)
            } finally {
                $stream.Dispose()
            }
        }
        # Database files names (extension depends on StorageFormat)
        $mainJson    = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.$ext"
        $updatesJson = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.$ext"
        $deletesJson = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.$ext"
        # Renaming current files to OLD if they are present.
        if ($thisObj.IsForceSaveMain -and [System.IO.File]::Exists($mainJson)) {
            $dest = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.old"
            _RetryFileOp { if ([System.IO.File]::Exists($dest)) { [System.IO.File]::Delete($dest) }; [System.IO.File]::Move($mainJson, $dest) }
        }
        if ([System.IO.File]::Exists($updatesJson)) {
            $dest = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.old"
            _RetryFileOp { if ([System.IO.File]::Exists($dest)) { [System.IO.File]::Delete($dest) }; [System.IO.File]::Move($updatesJson, $dest) }
        }
        if ([System.IO.File]::Exists($deletesJson)) {
            $dest = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.old"
            _RetryFileOp { if ([System.IO.File]::Exists($dest)) { [System.IO.File]::Delete($dest) }; [System.IO.File]::Move($deletesJson, $dest) }
        }
        # Renaming tmp files to the final extension (actual version saved)
        if ($thisObj.IsForceSaveMain) {
            $finalMain = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.$ext"
            _RetryFileOp { if ([System.IO.File]::Exists($finalMain)) { [System.IO.File]::Delete($finalMain) }; [System.IO.File]::Move($tmpMain, $finalMain) }
        }
        $finalUpdates = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.$ext"
        _RetryFileOp { if ([System.IO.File]::Exists($finalUpdates)) { [System.IO.File]::Delete($finalUpdates) }; [System.IO.File]::Move($tmpUpdates, $finalUpdates) }
        $finalDeletes = "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.$ext"
        _RetryFileOp { if ([System.IO.File]::Exists($finalDeletes)) { [System.IO.File]::Delete($finalDeletes) }; [System.IO.File]::Move($tmpDeletes, $finalDeletes) }
        # Moving OLD files to OLD folder for backup
        $Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        if ($thisObj.NumOfDbBackupsToKeep -gt 0) {
            if ($thisObj.IsForceSaveMain) {
                _MoveOld -folder $thisObj.DatabaseFolderPath -baseName "$($thisObj.DatabaseFileName)_main" -bakCount $thisObj.NumOfDbBackupsToKeep -TimeStamp $Timestamp
            }
            _MoveOld -folder $thisObj.DatabaseFolderPath -baseName "$($thisObj.DatabaseFileName)_updates" -bakCount $thisObj.NumOfDbBackupsToKeep -TimeStamp $Timestamp
            _MoveOld -folder $thisObj.DatabaseFolderPath -baseName "$($thisObj.DatabaseFileName)_deletes" -bakCount $thisObj.NumOfDbBackupsToKeep -TimeStamp $Timestamp
            # Backup rotation handled by _MoveOld based on file timestamps. Counter kept for diagnostic API.
            $thisObj.CurrentBackupNumber++
        } else {
            # If not required to backup - deleting old files
            foreach($old in @(
                "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.old",
                "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.old",
                "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.old")) {
                if ([System.IO.File]::Exists($old)) {
                    for ($i = 0; $i -lt 5; $i++) {
                        try { [System.IO.File]::Delete($old); break } catch [System.IO.IOException] { Start-Sleep -Milliseconds 100 }
                    }
                }
            }
        }
        # Cross-format cleanup: after a successful commit in the current format, archive or remove files of
        # the other format so only one format is ever present in the folder (prevents stale files from being
        # picked up by the json-first load order on the next run)
        $otherExt = 'xml'
        if ($ext -eq 'xml') { $otherExt = 'json' }
        $legacyFiles = @(
            "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_main.$otherExt",
            "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_updates.$otherExt",
            "$(Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName)_deletes.$otherExt"
        )
        $oldFolder = $null
        foreach ($legacyFile in $legacyFiles) {
            if (-not [System.IO.File]::Exists($legacyFile)) { continue }
            if ($thisObj.NumOfDbBackupsToKeep -gt 0) {
                # Move files of the other format to OLD folder, keeping the original extension
                if (-not $oldFolder) {
                    $oldFolder = Join-Path $thisObj.DatabaseFolderPath "OLD"
                    if (-not [System.IO.Directory]::Exists($oldFolder)) {
                        $null = [System.IO.Directory]::CreateDirectory($oldFolder)
                    }
                }
                $legacyBaseName = [System.IO.Path]::GetFileNameWithoutExtension($legacyFile)
                $destName = "$legacyBaseName.$TimeStamp.$otherExt"
                $dest = Join-Path $oldFolder $destName
                _RetryFileOp { if ([System.IO.File]::Exists($dest)) { [System.IO.File]::Delete($dest) }; [System.IO.File]::Move($legacyFile, $dest) }
                Write-Host "Archived legacy $otherExt file: $destName"
            } else {
                # Backup not configured - delete files of the other format to prevent reloading
                [System.IO.File]::Delete($legacyFile)
                Write-Host "Removed legacy $otherExt file: $([System.IO.Path]::GetFileName($legacyFile))"
            }
        }
        $endDateTime = [System.Datetime]::Now
        $thisObj.AsyncResults['Success'] = $true
        $thisObj.AsyncResults['Message'] = "Asynchronous save of database $($thisObj.DatabaseFileName) started $($startDateTime.ToString("yyyy.MM.dd HH:mm:ss")) completed in $([math]::Round((($endDateTime-$startDateTime).TotalSeconds),3)) sec."
    } catch {
        $thisObj.AsyncResults['Success'] = $false
        $thisObj.AsyncResults['Error']   = $_
        $thisObj.AsyncResults['Message'] = "Async save error: $($_.Exception.Message)"
        # Cleanup tmp files on error to prevent orphans
        foreach($p in @($tmpMain,$tmpUpdates,$tmpDeletes)){
            if ($p -and [System.IO.File]::Exists($p)) {
                for ($i = 0; $i -lt 3; $i++) {
                    try { [System.IO.File]::Delete($p); break } catch [System.IO.IOException] { Start-Sleep -Milliseconds 100 }
                }
            }
        }
    } finally {
        # Release the flag only on success path. On error keep it true to force next save to write main DB.
        if ($thisObj.AsyncResults -and $thisObj.AsyncResults['Success']) {
            $thisObj.IsForceSaveMain = $false
        }
    }
} # End of main save scriptblock

# Start of main scriptblock to load database. Used by class object later
 $Script:HashtableDB1Class_LoadScriptBlock = {
    param(
        [object] $thisObj
    )
    try {
        $startDateTime = [System.Datetime]::Now
        $fullPath = Join-Path $thisObj.DatabaseFolderPath $thisObj.DatabaseFileName

        $jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
        $jsonOptions.Converters.Add([PSObjectJsonConverter]::new())
        # Reset '~C' detection so the result can report whether any class instances exist in this load batch
        [PSObjectJsonConverter]::ResetClassMarkerDetection()

        # Optimized I/O: Using .NET File.Exists which is significantly faster than Get-Item -ErrorAction SilentlyContinue. Supports backward compatibility by checking for .json first, then falling back to legacy .xml
        $mainJsonPath = "$($fullPath)_main.json"
        $mainXmlPath = "$($fullPath)_main.xml"
        $MainFile2Load = $null
        if ([System.IO.File]::Exists($mainJsonPath)) {
            $MainFile2Load = [System.IO.FileInfo]::new($mainJsonPath)
        } elseif ([System.IO.File]::Exists($mainXmlPath)) {
            $MainFile2Load = [System.IO.FileInfo]::new($mainXmlPath)
        }
        $updatesJsonPath = "$($fullPath)_updates.json"
        $updatesXmlPath = "$($fullPath)_updates.xml"
        $UpdatesFile2Load = $null
        if ([System.IO.File]::Exists($updatesJsonPath)) {
            $UpdatesFile2Load = [System.IO.FileInfo]::new($updatesJsonPath)
        } elseif ([System.IO.File]::Exists($updatesXmlPath)) {
            $UpdatesFile2Load = [System.IO.FileInfo]::new($updatesXmlPath)
        }
        $deletesJsonPath = "$($fullPath)_deletes.json"
        $deletesXmlPath = "$($fullPath)_deletes.xml"
        $DeletesFile2Load = $null
        if ([System.IO.File]::Exists($deletesJsonPath)) {
            $DeletesFile2Load = [System.IO.FileInfo]::new($deletesJsonPath)
        } elseif ([System.IO.File]::Exists($deletesXmlPath)) {
            $DeletesFile2Load = [System.IO.FileInfo]::new($deletesXmlPath)
        }

        # Recovery logic. If JSON is missing, validate backups before restoring. If .tmp is corrupted, it falls back to .old without overwriting the good .old with bad .tmp.
        if ($null -eq $MainFile2Load) {
            foreach ($ext in @('.tmp', '.old')) {
                $backupFile = "$($fullPath)_main$ext"
                if ([System.IO.File]::Exists($backupFile)) {
                    try {
                        $testHT = $null
                        # Restore under the extension matching the content: CLIXML ('<') vs JSON ('{')
                        $isXmlContent = $false
                        try {
                            $stream = [System.IO.File]::OpenRead($backupFile)
                            try {
                                $testHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                            } finally {
                                $stream.Dispose()
                            }
                        } catch {
                            # Fallback to legacy XML deserialization if JSON fails
                            $testHT = [System.Management.Automation.PSSerializer]::Deserialize([System.IO.File]::ReadAllText($backupFile))
                            $isXmlContent = $true
                        }
                        if ($testHT -is [System.Collections.IDictionary]) {
                            Write-Warning "Main database missing. Restoring from $ext file."
                            $restoreExt = 'json'
                            if ($isXmlContent) { $restoreExt = 'xml' }
                            $destPath = "$($fullPath)_main.$restoreExt"
                            if ([System.IO.File]::Exists($destPath)) { [System.IO.File]::Delete($destPath) }
                            [System.IO.File]::Move($backupFile, $destPath)
                            $MainFile2Load = [System.IO.FileInfo]::new($destPath)
                            break
                        }
                    } catch {
                        Write-Warning "Failed to restore from $backupFile (corrupted). Trying next if available."
                    }
                }
            }
        }
        if ($null -eq $UpdatesFile2Load) {
            foreach ($ext in @('.tmp', '.old')) {
                $backupFile = "$($fullPath)_updates$ext"
                if ([System.IO.File]::Exists($backupFile)) {
                    try {
                        $testHT = $null
                        # Restore under the extension matching the content: CLIXML ('<') vs JSON ('{')
                        $isXmlContent = $false
                        try {
                            $stream = [System.IO.File]::OpenRead($backupFile)
                            try {
                                $testHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                            } finally {
                                $stream.Dispose()
                            }
                        } catch {
                            # Fallback to legacy XML deserialization if JSON fails
                            $testHT = [System.Management.Automation.PSSerializer]::Deserialize([System.IO.File]::ReadAllText($backupFile))
                            $isXmlContent = $true
                        }
                        if ($testHT -is [System.Collections.IDictionary]) {
                            Write-Warning "Updates database missing. Restoring from $ext file."
                            $restoreExt = 'json'
                            if ($isXmlContent) { $restoreExt = 'xml' }
                            $destPath = "$($fullPath)_updates.$restoreExt"
                            if ([System.IO.File]::Exists($destPath)) { [System.IO.File]::Delete($destPath) }
                            [System.IO.File]::Move($backupFile, $destPath)
                            $UpdatesFile2Load = [System.IO.FileInfo]::new($destPath)
                            break
                        }
                    } catch {
                        Write-Warning "Failed to restore from $backupFile (corrupted). Trying next if available."
                    }
                }
            }
        }
        if ($null -eq $DeletesFile2Load) {
            foreach ($ext in @('.tmp', '.old')) {
                $backupFile = "$($fullPath)_deletes$ext"
                if ([System.IO.File]::Exists($backupFile)) {
                    try {
                        $testHT = $null
                        # Restore under the extension matching the content: CLIXML ('<') vs JSON ('{')
                        $isXmlContent = $false
                        try {
                            $stream = [System.IO.File]::OpenRead($backupFile)
                            try {
                                $testHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                            } finally {
                                $stream.Dispose()
                            }
                        } catch {
                            # Fallback to legacy XML deserialization if JSON fails
                            $testHT = [System.Management.Automation.PSSerializer]::Deserialize([System.IO.File]::ReadAllText($backupFile))
                            $isXmlContent = $true
                        }
                        if ($testHT -is [System.Collections.IDictionary]) {
                            Write-Warning "Deletes database missing. Restoring from $ext file."
                            $restoreExt = 'json'
                            if ($isXmlContent) { $restoreExt = 'xml' }
                            $destPath = "$($fullPath)_deletes.$restoreExt"
                            if ([System.IO.File]::Exists($destPath)) { [System.IO.File]::Delete($destPath) }
                            [System.IO.File]::Move($backupFile, $destPath)
                            $DeletesFile2Load = [System.IO.FileInfo]::new($destPath)
                            break
                        }
                    } catch {
                        Write-Warning "Failed to restore from $backupFile (corrupted). Trying next if available."
                    }
                }
            }
        }
        # End of recovery logic

        # Format of the loaded main file ('Json'/'Xml'); drives cross-format migration after load
        $mainLoadedFormat = $null
        if ($null -ne $MainFile2Load) {
            if ($MainFile2Load.Extension -eq '.xml') { $mainLoadedFormat = 'Xml' } else { $mainLoadedFormat = 'Json' }
        }
        # Creating empty return result
        $resultData = @{
            Success = $false
            ErrorLevel = $null
            ErrorText = $null
            DataIsLoaded = $false
            MainHT = $null
            UpdatesHT = $null
            RemovedHT = $null
            DatabaseParamsHT = @{}
            ClassMarkersFound = $false
            LoadedFormat = $mainLoadedFormat
            MainFileLoadedDT = $null
            UpdatesFileLoadedDT = $null
            RemovedFileLoadedDT = $null
            LoadTime = $null
        }
        # If no main file
        if ($null -eq $MainFile2Load) {
            $resultData.ErrorLevel = "LFX1"
            $resultData.ErrorText = "Main database $fullPath file does not exist."
            return $resultData
        }
        # Default to no data is loaded
        $dataIsLoaded = $false
        $shouldLoadMain = ($null -eq $thisObj.MainFileLoadedDT) -or ($MainFile2Load.LastWriteTime -gt $thisObj.MainFileLoadedDT)
        $shouldLoadUpdates = ($null -eq $thisObj.UpdatesFileLoadedDT) -or ($UpdatesFile2Load -and $UpdatesFile2Load.LastWriteTime -gt $thisObj.UpdatesFileLoadedDT)
        $shouldLoadDeletes = ($null -eq $thisObj.RemovedFileLoadedDT) -or ($DeletesFile2Load -and $DeletesFile2Load.LastWriteTime -gt $thisObj.RemovedFileLoadedDT)
        # Loading main file if it is newer or never loaded
        if ($shouldLoadMain) {
            $loadSuccess = $false
            $fallbackFiles = @($MainFile2Load.FullName, "$($fullPath)_main.old")
            foreach ($tryFile in $fallbackFiles) {
                if (-not [System.IO.File]::Exists($tryFile)) { continue }
                try {
                    if ($tryFile.EndsWith(".json")) {
                        # 1MB read buffer: large files otherwise pay thousands of small-read syscalls
                        $stream = [System.IO.FileStream]::new($tryFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576)
                        try {
                            $resultData.MainHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                        } finally {
                            $stream.Dispose()
                        }
                    } else {
                        # .old files carry no format-defining extension - sniff the content instead:
                        # CLIXML starts with '<', JSON with '{'. Without this, a JSON-filled .old would be
                        # fed to PSSerializer and the fallback would always fail.
                        $rawContent = [System.IO.File]::ReadAllText($tryFile)
                        if ($rawContent.TrimStart().StartsWith('<')) {
                            $resultData.MainHT = [System.Management.Automation.PSSerializer]::Deserialize($rawContent)
                        } else {
                            $resultData.MainHT = [System.Text.Json.JsonSerializer]::Deserialize([string]$rawContent, [object], $jsonOptions)
                        }
                    }
                    if (-Not ($resultData.MainHT -is [System.Collections.IDictionary])) { throw "Invalid type" }
                    $loadSuccess = $true
                    if ($tryFile -ne $MainFile2Load.FullName) {
                        Write-Warning "Main database corrupted. Restored from .old"
                        [System.IO.File]::Copy($tryFile, $MainFile2Load.FullName, $true)
                    }
                    break
                } catch {
                    $resultData.MainHT = $null
                    $resultData.ErrorText = $_.Exception.Message
                }
            }
            if (-not $loadSuccess) {
                $resultData.Success = $false
                $resultData.ErrorLevel = "LFX2"
                $resultData.ErrorText = "Main database corrupted and no valid fallback found. Last error: $($resultData.ErrorText)"
                $resultData.DataIsLoaded = $false
                return $resultData
            }
            $dataIsLoaded = $true
            $resultData.MainFileLoadedDT = $MainFile2Load.LastWriteTime
        }
        # Loading updates file if it is newer or never loaded
        if ($UpdatesFile2Load -and $shouldLoadUpdates) {
            $loadSuccess = $false
            $fallbackFiles = @($UpdatesFile2Load.FullName, "$($fullPath)_updates.old")
            foreach ($tryFile in $fallbackFiles) {
                if (-not [System.IO.File]::Exists($tryFile)) { continue }
                try {
                    if ($tryFile.EndsWith(".json")) {
                        # 1MB read buffer: large files otherwise pay thousands of small-read syscalls
                        $stream = [System.IO.FileStream]::new($tryFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576)
                        try {
                            $resultData.UpdatesHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                        } finally {
                            $stream.Dispose()
                        }
                    } else {
                        # .old content sniffing: CLIXML starts with '<', JSON with '{' (see the main-file block)
                        $rawContent = [System.IO.File]::ReadAllText($tryFile)
                        if ($rawContent.TrimStart().StartsWith('<')) {
                            $resultData.UpdatesHT = [System.Management.Automation.PSSerializer]::Deserialize($rawContent)
                        } else {
                            $resultData.UpdatesHT = [System.Text.Json.JsonSerializer]::Deserialize([string]$rawContent, [object], $jsonOptions)
                        }
                    }
                    if (-Not ($resultData.UpdatesHT -is [System.Collections.IDictionary])) { throw "Invalid type" }
                    $loadSuccess = $true
                    if ($tryFile -ne $UpdatesFile2Load.FullName) {
                        Write-Warning "Updates database corrupted. Restored from .old"
                        [System.IO.File]::Copy($tryFile, $UpdatesFile2Load.FullName, $true)
                    }
                    break
                } catch {
                    $resultData.UpdatesHT = $null
                    $resultData.ErrorText = $_.Exception.Message
                }
            }
            if (-not $loadSuccess) {
                $resultData.Success = $false
                $resultData.ErrorLevel = "LFX4"
                $resultData.ErrorText = "Updates database corrupted and no valid fallback found. Last error: $($resultData.ErrorText)"
                $resultData.DataIsLoaded = $false
                return $resultData
            }
            $dataIsLoaded = $true
            $resultData.UpdatesFileLoadedDT = $UpdatesFile2Load.LastWriteTime
        }
        # Loading deletes file if it is newer or never loaded
        if ($DeletesFile2Load -and $shouldLoadDeletes) {
            $loadSuccess = $false
            $fallbackFiles = @($DeletesFile2Load.FullName, "$($fullPath)_deletes.old")
            foreach ($tryFile in $fallbackFiles) {
                if (-not [System.IO.File]::Exists($tryFile)) { continue }
                try {
                    if ($tryFile.EndsWith(".json")) {
                        # 1MB read buffer: large files otherwise pay thousands of small-read syscalls
                        $stream = [System.IO.FileStream]::new($tryFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576)
                        try {
                            $resultData.RemovedHT = [System.Text.Json.JsonSerializer]::Deserialize($stream, [object], $jsonOptions)
                        } finally {
                            $stream.Dispose()
                        }
                    } else {
                        # .old content sniffing: CLIXML starts with '<', JSON with '{' (see the main-file block)
                        $rawContent = [System.IO.File]::ReadAllText($tryFile)
                        if ($rawContent.TrimStart().StartsWith('<')) {
                            $resultData.RemovedHT = [System.Management.Automation.PSSerializer]::Deserialize($rawContent)
                        } else {
                            $resultData.RemovedHT = [System.Text.Json.JsonSerializer]::Deserialize([string]$rawContent, [object], $jsonOptions)
                        }
                    }
                    if (-Not ($resultData.RemovedHT -is [System.Collections.IDictionary])) { throw "Invalid type" }
                    $loadSuccess = $true
                    if ($tryFile -ne $DeletesFile2Load.FullName) {
                        Write-Warning "Deletes database corrupted. Restored from .old"
                        [System.IO.File]::Copy($tryFile, $DeletesFile2Load.FullName, $true)
                    }
                    break
                } catch {
                    $resultData.RemovedHT = $null
                    $resultData.ErrorText = $_.Exception.Message
                }
            }
            if (-not $loadSuccess) {
                $resultData.Success = $false
                $resultData.ErrorLevel = "LFX6"
                $resultData.ErrorText = "Deletes database corrupted and no valid fallback found. Last error: $($resultData.ErrorText)"
                $resultData.DataIsLoaded = $false
                return $resultData
            }
            $dataIsLoaded = $true
            $resultData.RemovedFileLoadedDT = $DeletesFile2Load.LastWriteTime
            # Restoring database params from special key
            $resultData.DatabaseParamsHT = $resultData.RemovedHT["___DATABASEPARAMS___"]
            if (-Not ($resultData.DatabaseParamsHT -is [System.Collections.IDictionary])) {
                $resultData.DatabaseParamsHT = @{}
            }
        }
        $resultData.DataIsLoaded = $dataIsLoaded
        $resultData.Success = $true
        # Report whether any '~C' class markers were seen during deserialization of this batch
        $resultData.ClassMarkersFound = [PSObjectJsonConverter]::HasReadClassMarkers()
        $endDateTime = [System.Datetime]::Now
        $resultData.LoadTime = ($endDateTime - $startDateTime).TotalSeconds
        return $resultData
    } catch {
        $resultData.Success = $false
        $resultData.ErrorLevel = "LFX8"
        $resultData.ErrorText = $_.Exception.Message
        $resultData.DataIsLoaded = $false
        return $resultData
    }
} # End of main load scriptblock

# Save transaction Log scriptblock
 $Script:HashtableDB1Class_SaveTxLogScriptBlock = {
    param(
        [object] $thisObj,
        [object] $keyToTick,
        [object]   $tickToKeys,
        [string]   $txLogFolder
    )
    # Determine ticks that have NOT been persisted yet
    $cutoffTick = $thisObj.LastTransactionLogSavedTimestamp
    $deltaChanges = @{}
    $firstTick = [long]::MaxValue
    $lastTick  = [long]::MinValue
    # Lock TickToKeys to prevent InvalidOperationException during concurrent Add/Remove
    [System.Threading.Monitor]::Enter($thisObj.TickToKeysLock)
    try {
        foreach ($tick in $tickToKeys.Keys) {
            if ($tick -le $cutoffTick) { continue }
            # Track min/max ticks during enumeration to avoid slow extra LINQ passes
            if ($tick -lt $firstTick) { $firstTick = $tick }
            if ($tick -gt $lastTick) { $lastTick = $tick }
            foreach ($entry in $tickToKeys[$tick]) {
                # $entry is Tuple<string, string> (Key, Op). Tuple instead of a PS hashtable literal:
                # direct .NET allocation without PSObject wrapping - much faster on bulk deltas
                $deltaChanges[$entry.Item1] = [System.Tuple]::Create($tick, $entry.Item2)
            }
        }
    } finally {
        [System.Threading.Monitor]::Exit($thisObj.TickToKeysLock)
    }
    # nothing new to write
    if ($deltaChanges.Count -eq 0) { return }
    # Build the transaction-log array using lightweight arrays instead of PSCustomObject for performance
    $txList = [System.Collections.Generic.List[object]]::new()
    # Cache MergedHT reference to avoid expensive property resolution in tight loop
    $mergedHT = $thisObj.MergedHT
    foreach ($kv in $deltaChanges.GetEnumerator()) {
        $key  = $kv.Key
        $tick = $kv.Value.Item1
        $op   = $kv.Value.Item2
        $value = $null
        if ($op -eq 'A') {
            $null = $mergedHT.TryGetValue($key, [ref]$value)
        }
        $txList.Add(@($op, $key, $value, $tick))
    }
    # Ensure destination folder exists
    if (-not [System.IO.Directory]::Exists($txLogFolder)) {
        $null = [System.IO.Directory]::CreateDirectory($txLogFolder)
    }
    $fileName = "$($thisObj.DatabaseFileName)_$firstTick`_$lastTick.txlog"
    $fullPath = Join-Path $txLogFolder $fileName
    $jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
    $jsonOptions.Converters.Add([PSObjectJsonConverter]::new())
    # Disable escaping of <, > and non-ASCII to reduce TxLog size
    $jsonOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    # 1MB write buffer: fewer larger write syscalls for big delta batches
    $stream = [System.IO.File]::Create($fullPath, 1048576)
    try {
        [System.Text.Json.JsonSerializer]::Serialize($stream, [object]$txList, $jsonOptions)
    } finally {
        $stream.Dispose()
    }
    # Update the "last saved" tick
    $thisObj.LastTransactionLogSavedTimestamp = $lastTick
    # Cleanup in-memory structures and old TxLog files according to retention
    if ($thisObj.TxLogRetentionDays -gt 0) {
        $cutoffDate = [datetime]::UtcNow.AddDays(-$thisObj.TxLogRetentionDays)
        $cutoffFileTime = $cutoffDate.ToFileTimeUtc()
        # Snapshot keys to avoid InvalidOperation during enumeration-modification.
        $ktRef = $thisObj.KeyToTick
        $keysSnapshot = @($ktRef.Keys)
        foreach ($k in $keysSnapshot) {
            $tickVal = [long]0
            if ($ktRef.TryGetValue($k, [ref]$tickVal) -and $tickVal -lt $cutoffFileTime) {
                $null = $ktRef.TryRemove($k, [ref]$tickVal)
            }
        }
        [System.Threading.Monitor]::Enter($thisObj.TickToKeysLock)
        try {
            $ticksSnapshot = @($thisObj.TickToKeys.Keys)
            foreach ($t in $ticksSnapshot) {
                if ($t -lt $cutoffFileTime) { $thisObj.TickToKeys.Remove($t) }
            }
        } finally {
            [System.Threading.Monitor]::Exit($thisObj.TickToKeysLock)
        }
        # File cleanup shares the same retention guard; cutoff derived from the already computed date
        $rx = [regex]::new('^' + [regex]::Escape($thisObj.DatabaseFileName) + '_(\d+)_(\d+)\.txlog$')
        $cutoff = $cutoffDate.ToLocalTime()
        # Regex check first (pure CPU, no I/O), GetLastWriteTime avoids FileInfo allocation
        foreach ($f in [System.IO.Directory]::GetFiles($txLogFolder, "*.txlog")) {
            $fileName = [System.IO.Path]::GetFileName($f)
            if ($rx.IsMatch($fileName) -and [System.IO.File]::GetLastWriteTime($f) -lt $cutoff) {
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    try {
                        [System.IO.File]::Delete($f)
                        Write-Verbose "Deleted old TxLog: $fileName"
                        break
                    } catch [System.IO.IOException] {
                        Start-Sleep -Milliseconds 100
                        if ($attempt -eq 2) {
                            Write-Warning "Failed to delete old TxLog $($f): $($_.Exception.Message)"
                        }
                    } catch {
                        Write-Warning "Failed to delete old TxLog $($f): $($_.Exception.Message)"
                        break
                    }
                }
            }
        }
    }
} # End of SaveTxLogScriptBlock

# Attempts to rehydrate a '~C' hashtable into a real class instance. Returns $null when not applicable or not possible.
 $Script:HashtableDB1Class_TryRehydrateScriptBlock = {
    param([object]$Node)
    if (-not ($Node -is [System.Collections.IDictionary])) { return $null }
    $className = $Node['~C']
    if (-not ($className -is [string])) { return $null }
    $targetType = $null
    try { $targetType = $className -as [type] } catch { $targetType = $null }
    if (-not $targetType) { return $null }
    $instance = $null
    try {
        $instance = New-Object -TypeName $targetType -ErrorAction Stop
    } catch {
        $instance = $null
        # No parameterless constructor: map constructor parameters from hashtable keys (case-insensitive), falling back to default values (0 for value types, $null for references)
        $ctors = @($targetType.GetConstructors() | Sort-Object { $_.GetParameters().Count })
        foreach ($ctor in $ctors) {
            $ctorArgs = @()
            foreach ($p in $ctor.GetParameters()) {
                $found = $null
                foreach ($bk in @($Node.Keys)) {
                    if ([string]::Equals("$bk", $p.Name, [System.StringComparison]::OrdinalIgnoreCase)) { $found = $bk; break }
                }
                if ($found) { $ctorArgs += $Node[$found] }
                elseif ($p.ParameterType.IsValueType) { $ctorArgs += [System.Activator]::CreateInstance($p.ParameterType) }
                else { $ctorArgs += $null }
            }
            try { $instance = $ctor.Invoke($ctorArgs); break } catch { $instance = $null }
        }
    }
    if ($null -eq $instance) { return $null }
    $mapped = $false
    foreach ($k in @($Node.Keys)) {
        if ("$k" -eq '~C') { continue }
        $prop = $instance.PSObject.Properties[$k]
        if ($prop -and $prop.IsSettable) {
            try {
                $instance."$k" = $Node[$k]
                $mapped = $true
            } catch {
                # Skip properties that fail conversion instead of aborting the whole instance
            }
        }
    }
    # If the type exposes a LoadFromData method, let it rebuild derived/internal state (e.g. hidden caches like RollingSet.nodeDict) from the raw property map
    $loaded = $false
    if ($instance.PSObject.Methods['LoadFromData']) {
        try { if ($instance.LoadFromData($Node)) { $loaded = $true } } catch { }
    }
    if ($mapped -or $loaded) { return $instance }
    return $null
}

# Restores PowerShell class instances from '~C' markers left by PSObjectJsonConverter. Iterative stack-based traversal (no recursion) - immune to PowerShell call-depth overflow. A visited set guards against cyclic references (e.g. graphs restored from CLIXML <Obj Ref> nodes by PSSerializer.Deserialize): an already-visited container is still rehydrated ('~C'), but is never descended into again, so the traversal always terminates on cyclic data.
 $Script:HashtableDB1Class_RestoreClassesScriptBlock = {
    param([object]$Node)
    if ($null -eq $Node) { return $null }
    $result = $Node
    # Reference-identity set of visited container nodes (hashtable/array/PSObject use reference equality)
    $visited = [System.Collections.Generic.HashSet[object]]::new()
    # Hard iteration limit as a final safety net, sized far above node counts of large databases
    $maxIterations = 5000000
    $iterations = 0
    # Frame: Parent (container or $null for the root), Slot (key / index / property name), Node, Phase (0=descend, 1=rehydrate)
    $stack = [System.Collections.Generic.Stack[hashtable]]::new()
    $stack.Push(@{ Parent = $null; Slot = $null; Node = $Node; Phase = 0 })
    while ($stack.Count -gt 0) {
        $iterations++
        if ($iterations -gt $maxIterations) {
            $peekNode = $stack.Peek().Node
            Write-Warning "RestoreClasses: iteration limit ($maxIterations) exceeded - possible cyclic reference. Current node type: $(if ($null -ne $peekNode) { $peekNode.GetType().FullName } else { 'null' })"
            break
        }
        $frame = $stack.Pop()
        $node = $frame.Node
        if ($null -eq $node) { continue }
        if ($frame.Phase -eq 1) {
            # Phase 1: children are already restored - rehydrate the class and replace it in the parent
            $rehydrated = & $Script:HashtableDB1Class_TryRehydrateScriptBlock $node
            if ($null -ne $rehydrated) {
                $parent = $frame.Parent
                $slot = $frame.Slot
                if ($null -eq $parent) {
                    $result = $rehydrated
                } elseif ($parent -is [System.Collections.IDictionary]) {
                    $parent[$slot] = $rehydrated
                } elseif ($parent -is [System.Array]) {
                    $parent[$slot] = $rehydrated
                } else {
                    try { $parent."$slot" = $rehydrated } catch { }
                }
            }
            continue
        }
        # Phase 0: descend into containers
        if ($node -is [System.Collections.IDictionary]) {
            $wasVisited = -not $visited.Add($node)
            # Push the rehydrate frame first so it pops after all children (LIFO). Re-visited (aliased/cyclic) hashtables still get rehydrated, but are not descended into again - their children are the same objects and are already restored.
            $stack.Push(@{ Parent = $frame.Parent; Slot = $frame.Slot; Node = $node; Phase = 1 })
            if (-not $wasVisited) {
                foreach ($k in @($node.Keys)) {
                    $child = $node[$k]
                    if ($null -ne $child) {
                        $stack.Push(@{ Parent = $node; Slot = $k; Node = $child; Phase = 0 })
                    }
                }
            }
        } elseif ($node -is [System.Array]) {
            $wasVisited = -not $visited.Add($node)
            if (-not $wasVisited) {
                for ($i = 0; $i -lt $node.Length; $i++) {
                    $child = $node[$i]
                    if ($null -ne $child) {
                        $stack.Push(@{ Parent = $node; Slot = $i; Node = $child; Phase = 0 })
                    }
                }
            }
        } elseif ($node -is [pscustomobject]) {
            $wasVisited = -not $visited.Add($node)
            if (-not $wasVisited) {
                foreach ($p in @($node.PSObject.Properties)) {
                    if ($p.IsSettable -and $null -ne $p.Value) {
                        $stack.Push(@{ Parent = $node; Slot = $p.Name; Node = $p.Value; Phase = 0 })
                    }
                }
            }
        }
    }
    # Note! Comma-wrap: prevents PowerShell output enumeration from collapsing an empty array root into $null
    return ,$result
} # End of RestoreClassesScriptBlock

# Async load composite: keeps ALL heavy work (deserialization, ConcurrentDictionary building, TxLog state reset,
# '~C' node collection) inside the background runspace, so the InvocationStateChanged event action in the main
# session stays lightweight and does not freeze the GUI script. Class rehydration itself cannot run here
# (user classes are not resolvable in this runspace) - collected nodes are rehydrated by the event action.
 $Script:HashtableDB1Class_LoadAsyncScriptBlock = {
    param([object]$thisObj, [object]$loadScriptBlock)
    # Phase 1: raw deserialization (JSON with legacy XML fallback) - identical to the synchronous path.
    # The load scriptblock is passed as an argument because $Script: scope of the main session does not
    # exist in the background runspace (AddScript re-parses scriptblock text in the pool session state).
    # Re-create it from text so it binds to this runspace, not to the main-session affinity of the object.
    $loadResult = & ([scriptblock]::Create($loadScriptBlock.ToString())) $thisObj
    if (-not ($loadResult.Success -and $loadResult.DataIsLoaded)) { return $loadResult }
    # Phase 2 (background runspace): build ConcurrentDictionaries and publish them to the live object.
    # The same cross-runspace mutation pattern is already used by the save path (AsyncResults, IsForceSaveMain).
    # Assignment order matters for concurrent readers: MergedHT is swapped last, so Get() keeps serving
    # the old consistent view until the very end of the swap.
    if ($null -ne $loadResult.MainHT) {
        $thisObj.MainHT = [PSObjectJsonConverter]::BuildConcurrentDictionary($loadResult.MainHT, $null)
    }
    if ($null -ne $loadResult.UpdatesHT) {
        $thisObj.UpdatesHT = [PSObjectJsonConverter]::BuildConcurrentDictionary($loadResult.UpdatesHT, $null)
    }
    if ($null -ne $loadResult.RemovedHT) {
        # Do not load the internal DB params marker into the live RemovedHT
        $thisObj.RemovedHT = [PSObjectJsonConverter]::BuildConcurrentDictionary($loadResult.RemovedHT, "___DATABASEPARAMS___")
        $thisObj.DatabaseParamsHT = $loadResult.DatabaseParamsHT
    } else {
        $thisObj.DatabaseParamsHT = @{}
    }
    $thisObj.MainFileLoadedDT = $loadResult.MainFileLoadedDT
    $thisObj.UpdatesFileLoadedDT = $loadResult.UpdatesFileLoadedDT
    $thisObj.RemovedFileLoadedDT = $loadResult.RemovedFileLoadedDT
    # Rebuild merged hashtable, then assign atomically (C# helper - fast)
    $thisObj.MergedHT = [PSObjectJsonConverter]::BuildMergedDictionary($thisObj.MainHT, $thisObj.UpdatesHT, $thisObj.RemovedHT)
    # Clear TxLog in-memory state since DB state is fully replaced by loaded data
    if ($thisObj.EnableTransactionLog) {
        $thisObj.KeyToTick.Clear()
        [System.Threading.Monitor]::Enter($thisObj.TickToKeysLock)
        try {
            $thisObj.TickToKeys.Clear()
        } finally {
            [System.Threading.Monitor]::Exit($thisObj.TickToKeysLock)
        }
        $thisObj.LastTransactionLogSavedTimestamp = 0
    }
    # Phase 3 (background, cheap): collect '~C' hashtable nodes for main-session rehydration.
    # Skipped entirely when the converter saw no '~C' markers during Phase 1 (same thread) - the
    # full-tree traversal is the most expensive post-load step for large class-free datasets.
    # Nodes are appended in DFS order (containers before children); the event action processes the list
    # in reverse so nested instances are rehydrated before their containers copy them out of raw hashtables.
    $pending = [PSObjectJsonConverter]::CollectClassNodes(@($loadResult.MainHT, $loadResult.UpdatesHT, $loadResult.DatabaseParamsHT))
    $loadResult['PendingClassNodes'] = $pending
    return $loadResult
} # End of LoadAsyncScriptBlock

# Reference class used to store persistent runspacepools and their results
class AsyncContainer {
    # Runspace pool (created on first use, reused across calls)
    [System.Management.Automation.Runspaces.RunspacePool] $Pool
    # Current PowerShell instance
    [PowerShell] $PSInstance
    # Registered InvocationStateChanged event job
    [System.Management.Automation.PSEventJob] $PsEventJob
    # Result of PSInstance.BeginInvoke()
    [System.IAsyncResult] $BeginInvokeResult
}
Class HashTableDB1 {
    # The main hashtable (usually big file). NEVER modify this hashtable directly!!!
    [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $MainHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Changes to hashtable since last full file. NEVER modify this hashtable directly!!!
    [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $UpdatesHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Merged hashtable in memory (main + changes). NEVER modify this hashtable directly!!!
    [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $MergedHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Removed keys hashtable (case-insensitive keys to match PowerShell hashtable semantics)
    [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $RemovedHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Datetime main database was last loaded/saved
    $MainFileLoadedDT = $null
    # Datetime updates database was last loaded/saved
    $UpdatesFileLoadedDT = $null
    # Datetime removed records database was last loaded/saved
    $RemovedFileLoadedDT = $null
    # Database parameters and setting to store in DB
    $DatabaseParamsHT = @{}
    # Name of files database
    $DatabaseFileName = "HashTableDB"
    # Storage format: 'Json' (default - fast, readable, type-fidelity markers) or 'Xml' (CLIXML compatibility
    # mode). After loading files of the other format the database is automatically resaved in the configured
    # format and the old-format files are archived to OLD\, so the folder always holds a single format.
    [string] $StorageFormat = 'Json'
    $DatabaseFolderPath = ".\"
    $ErrorLevel = $null
    $ErrorText = $null
    # Save this number of database backupds in OLD folder
    $NumOfDbBackupsToKeep = 0
    $CurrentBackupNumber = 0
    # Add this read permissions to database. Example @("S-1-2-0") local users. Array
    $DatabaseReadAccessControlListIdentifiers = $null
    # Readonly mode for client
    $ReadOnlyMode = $false
    # Synchronized hashtable for async operation results
    hidden [hashtable]$AsyncResults = $null
    [bool] $IsForceSaveMain = $false
    # Server Synchronization part
    # Enables DB sync
    [bool]   $EnableTransactionLog           = $false
    # Number of days to keep TXLogs
    [int]    $TxLogRetentionDays   = 3
    # Key -> tick (FileTimeUtc). ConcurrentDictionary for thread-safe Add/Remove/SaveTxLog interaction.
    [System.Collections.Concurrent.ConcurrentDictionary[string, long]] $KeyToTick = [System.Collections.Concurrent.ConcurrentDictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Lock object protecting TickToKeys (SortedDictionary is not thread-safe).
    hidden [object] $TickToKeysLock = [object]::new()
    # Tick -> list of <key,op> entries. SortedDictionary gives chronological iteration for TxLog.
    hidden [System.Collections.Generic.SortedDictionary[long, System.Collections.Generic.List[object]]] $TickToKeys = [System.Collections.Generic.SortedDictionary[long, System.Collections.Generic.List[object]]]::new()
    # Tick of the latest entry that has already been persisted to a TxLog file
    [long]   $LastTransactionLogSavedTimestamp  = 0
    # Last tick point written in a TxLog (retained for external API compatibility)
    [long]   $LastTxLogTick        = 0
    # Max lock file wait time (seconds)
    [int] $LockFileMaxWaitTime = 30
    # Object used for SaveToXMLAsync
    hidden [AsyncContainer] $AsynchronousSaveOperationState = [AsyncContainer]::new()
    # Object used for SaveTxToXMLAsync
    hidden [AsyncContainer] $AsynchronousTransactionLogSaveState = [AsyncContainer]::new()
    # Async-load tracking and persisntent pool
    hidden [AsyncContainer] $AsynchronousLoadOperationState = [AsyncContainer]::new()
    # Constant. PSEventJob (System.Management.Automation.Job) bad states indicating an error
    [System.Management.Automation.JobState[]] $BadEventJobStates = @(
        [System.Management.Automation.JobState]::Failed,
        [System.Management.Automation.JobState]::Blocked
    )
    # Constructor - initialize async components
    HashTableDB1() {
        $this.AsyncResults = [hashtable]::Synchronized(@{})
    }
    # Creates empty database
    [void] CreateEmptyDB() {
        $this.MainHT.Clear()
        $this.MergedHT.Clear()
        $this.UpdatesHT.Clear()
        $this.RemovedHT.Clear()
        $this.MainFileLoadedDT = $null
        $this.UpdatesFileLoadedDT = $null
        $this.RemovedFileLoadedDT = $null
        $this.DatabaseParamsHT = @{}
    }
    # Adds record to a database
    [void] Add($KeyName, $HashValue) {
        $this.UpdatesHT[$KeyName] = $HashValue
        $this.MergedHT[$KeyName] = $HashValue
        $null = $this.RemovedHT.TryRemove($KeyName, [ref]$null)
        # TxLog entries - store operation type "A"
        if ($this.EnableTransactionLog) {
            $nowTick = [datetime]::UtcNow.ToFileTimeUtc()
            $this.KeyToTick[$KeyName] = $nowTick
            # Atomic insert-or-get to avoid lost list on race
            $list = $null
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                if (-not $this.TickToKeys.TryGetValue($nowTick, [ref]$list)) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    $this.TickToKeys[$nowTick] = $list
                }
                # OPTIMIZATION: Use Tuple instead of PSCustomObject for massive speedup in tight loops
                $list.Add([System.Tuple]::Create($KeyName, 'A'))
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
        }
    }
    # Removes record from a database
    [void] Remove($KeyName) {
        $null = $this.MergedHT.TryRemove($KeyName, [ref]$null)
        $null = $this.UpdatesHT.TryRemove($KeyName, [ref]$null)
        $this.RemovedHT[$KeyName] = 1
        # TxLog entries - store operation type "R"
        if ($this.EnableTransactionLog) {
            $nowTick = [datetime]::UtcNow.ToFileTimeUtc()
            $this.KeyToTick[$KeyName] = $nowTick
            $list = $null
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                if (-not $this.TickToKeys.TryGetValue($nowTick, [ref]$list)) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    $this.TickToKeys[$nowTick] = $list
                }
                $list.Add([System.Tuple]::Create($KeyName, 'R'))
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
        }
    }
    # Adds secondary key to hashtable database
    [void] UpsertNestedHashTableKey($KeyName, $SecondaryKey, $SecondaryKeyValue=1) {
        # Atomic upsert via TryAdd + CAS TryUpdate pattern to prevent lost updates under concurrency
        $updated = $false
        $casRetries = 0
        while (-not $updated -and $casRetries -lt 100) {
            $casRetries++
            $currentValue = $null
            if (-not $this.MergedHT.TryGetValue($KeyName, [ref]$currentValue)) {
                # Key doesn't exist - try to add new hashtable
                $newValue = @{$SecondaryKey = $SecondaryKeyValue}
                if ($this.MergedHT.TryAdd($KeyName, $newValue)) {
                    $this.UpdatesHT[$KeyName] = $newValue
                    $null = $this.RemovedHT.TryRemove($KeyName, [ref]$null)
                    $updated = $true
                }
                continue
            }
            # Snapshot the value we just read - this is the CAS comparison value
            $originalValue = $currentValue
            if (-Not ($currentValue -is [hashtable])) {
                $newValue = @{$SecondaryKey = $SecondaryKeyValue}
            } else {
                # Copy-on-write to avoid mutating shared reference
                $newValue = @{}
                foreach ($k in $currentValue.Keys) { $newValue[$k] = $currentValue[$k] }
                $newValue[$SecondaryKey] = $SecondaryKeyValue
            }
            # CAS: only update if value hasn't changed since we read it. Third arg must be the ORIGINAL value, NOT $null (which would never match a non-null current value).
            if ($this.MergedHT.TryUpdate($KeyName, $newValue, $originalValue)) {
                $this.UpdatesHT[$KeyName] = $newValue
                $null = $this.RemovedHT.TryRemove($KeyName, [ref]$null)
                $updated = $true
            }
            # else: another thread modified - loop and retry
        }
        # Prevent silent data loss by throwing if CAS failed after 100 retries
        if (-not $updated) {
            throw "Failed to update key '$KeyName' after 100 retries due to concurrent modifications."
        }
        # TxLog entry if enabled
        if ($this.EnableTransactionLog) {
            $nowTick = [datetime]::UtcNow.ToFileTimeUtc()
            $this.KeyToTick[$KeyName] = $nowTick
            $list = $null
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                if (-not $this.TickToKeys.TryGetValue($nowTick, [ref]$list)) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    $this.TickToKeys[$nowTick] = $list
                }
                # OPTIMIZATION: Use Tuple instead of PSCustomObject
                $list.Add([System.Tuple]::Create($KeyName, 'A'))
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
        }
    }
    # Removes secondary key from hashtable database
    [void] RemoveNestedHashTableKey($KeyName, $SecondaryKey) {
        $updated = $false
        $casRetries = 0
        while (-not $updated -and $casRetries -lt 100) {
            $casRetries++
            $currentValue = $null
            if (-not $this.MergedHT.TryGetValue($KeyName, [ref]$currentValue) -or -not ($currentValue -is [hashtable])) {
                return
            }
            # Copy-on-write snapshot to avoid mutating the live reference
            $newVal = @{}
            foreach ($k in $currentValue.Keys) {
                if (-not [string]::Equals($k, $SecondaryKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $newVal[$k] = $currentValue[$k]
                }
            }
            if ($newVal.Count -eq 0) {
                $this.Remove($KeyName)
                return
            }
            # CAS: only update if value hasn't changed since we read it.
            if ($this.MergedHT.TryUpdate($KeyName, $newVal, $currentValue)) {
                $this.UpdatesHT[$KeyName] = $newVal
                $null = $this.RemovedHT.TryRemove($KeyName, [ref]$null)
                $updated = $true
            }
        }
        # Prevent silent data loss by throwing if CAS failed after 100 retries
        if (-not $updated) {
            throw "Failed to remove secondary key '$SecondaryKey' from '$KeyName' after 100 retries due to concurrent modifications."
        }
        # TxLog entry if enabled
        if ($this.EnableTransactionLog) {
            $nowTick = [datetime]::UtcNow.ToFileTimeUtc()
            $this.KeyToTick[$KeyName] = $nowTick
            $list = $null
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                if (-not $this.TickToKeys.TryGetValue($nowTick, [ref]$list)) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    $this.TickToKeys[$nowTick] = $list
                }
                # OPTIMIZATION: Use Tuple instead of PSCustomObject
                $list.Add([System.Tuple]::Create($KeyName, 'A'))
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
        }
    }
    # Gets record from database. TryGetValue instead of the raw indexer: the indexer throws
    # KeyNotFoundException on a missing key and PowerShell exception handling is expensive in hot read paths
    [object] Get($KeyName) {
        if ($null -eq $KeyName) { return $null }
        $value = $null
        try {
            if ($this.MergedHT.TryGetValue($KeyName, [ref]$value)) { return $value }
        } catch {
            return $null
        }
        return $null
    }
    # Returns all keys from database
    [object] GetAllKeys() {
        return  $this.MergedHT.Keys
    }
    # Returns all values from database
    [object] GetAllValues() {
        return  $this.MergedHT.Values
    }
    # Checks if database contains record with key
    [boolean] ContainsKey($KeyName) {
        return $this.MergedHT.ContainsKey($KeyName)
    }
    # Returns total number of changes to main database
    [int] GetPendingChangesCount() {
        return ($this.UpdatesHT.Count + $this.RemovedHT.Count)
    }
    [hashtable] Clone() {
        # Runtime type resolution: class method bodies bind type literals at compile time (before
        # Add-Type at the top of this file executes), so a direct [PSObjectJsonConverter] reference
        # here would break dot-sourcing in a fresh session
        $converterType = 'PSObjectJsonConverter' -as [type]
        if ($converterType) { return $converterType::BuildHashtable($this.MergedHT) }
        # Fallback for the unlikely case the converter type is not loaded
        $ht = @{}
        foreach ($k in $this.MergedHT.Keys) { $ht[$k] = $this.MergedHT[$k] }
        return $ht
    }
    # Consolidate changes to a main database and creates new updates database - thus saving full DB
    [void] CompactDatabase() {
        $dateTimeNow = [System.Datetime]::Now
        # Atomically swap references. MergedHT becomes MainHT. Concurrent writes to MergedHT are preserved and will be saved to main.json directly.
        $this.MainHT = $this.MergedHT
        # Replace UpdatesHT and RemovedHT with empty instances to reset change tracking. This avoids the race condition where concurrent writes to the old UpdatesHT could be lost during copy.
        $this.UpdatesHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.RemovedHT = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.MainFileLoadedDT = $dateTimeNow
        $this.UpdatesFileLoadedDT = $dateTimeNow
        $this.RemovedFileLoadedDT = $dateTimeNow
        $this.IsForceSaveMain = $true
        # Clear TxLog in-memory state because full state is now persisted in MainHT
        if ($this.EnableTransactionLog) {
            $this.KeyToTick.Clear()
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                $this.TickToKeys.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
        }
    }
    # Synchronous save - re-uses the exact same script block but runs it directly on the calling thread (no runspace, no event handling).
    [void] SaveToDisk() {
        if ($this.ReadOnlyMode) { return }
        $this.ErrorLevel = $null
        $this.ErrorText  = $null
        # Storage format extension for the main-file existence check
        $mainExt = 'json'
        if ($this.StorageFormat -eq 'Xml') { $mainExt = 'xml' }
        $mainPath = "$(Join-Path $this.DatabaseFolderPath $this.DatabaseFileName)_main.$mainExt"
        # Wait for previous async save BEFORE Consolidate to prevent its finally-block from resetting IsForceSaveMain that Consolidate sets
        $this.WaitForAsyncSaveToDisk()
        # If updates database is bigger than 30% of main database
        if ($this.MainHT.Count * 0.3 -lt $this.GetPendingChangesCount()) {
            $this.CompactDatabase()
        }
        if (-not [System.IO.File]::Exists($mainPath)) { $this.IsForceSaveMain = $true }
        # Snapshot references the live CD instances. ConcurrentDictionary guarantees atomic per-key reads, and CompactDatabase() swaps whole CD instances atomically, so iteration sees a consistent CD reference.
        $mainSnapshot    = $this.MainHT
        $updatesSnapshot = $this.UpdatesHT
        $removedSnapshot = $this.RemovedHT
        # Direct invocation of the shared script block
        try {
            & $Script:HashtableDB1Class_SaveScriptBlock $this $mainSnapshot $updatesSnapshot $removedSnapshot
            # Scriptblock catches its own errors into AsyncResults; propagate to class properties
            if ($this.AsyncResults -and -not $this.AsyncResults['Success']) {
                $this.ErrorLevel = "STX1"
                $this.ErrorText  = $this.AsyncResults['Message']
            } else {
                # Ensure ErrorLevel is explicitly set to 0 on success for consistent state checking
                $this.ErrorLevel = 0
            }
        } catch {
            $this.ErrorLevel = "STX1"
            $this.ErrorText  = $_.Exception.Message
        }
        # Syn saving TX Log
        if ($this.EnableTransactionLog) {
            $this.WaitForPendingTransactionLogOperations()
            Try {
                $ktSnap = $this.KeyToTick
                $tkSnap = $this.TickToKeys
                $TxLogsPath = Join-Path $this.DatabaseFolderPath "TxLog"
                & $Script:HashtableDB1Class_SaveTxLogScriptBlock $this $ktSnap $tkSnap $TxLogsPath
            } catch {
                $this.ErrorLevel = "STXT1"
                $this.ErrorText  = $_.Exception.Message
            }
        }
    }
    # Wait for previous async to finish
    [void] WaitForAsyncSaveToDisk() {
        # If async load still in progress - wait for it to finish.
        if ($this.AsynchronousSaveOperationState.BeginInvokeResult -and -not $this.AsynchronousSaveOperationState.BeginInvokeResult.IsCompleted) {
            $maxWait = [System.TimeSpan]::FromSeconds($this.LockFileMaxWaitTime)
            $start   = [datetime]::Now
            $jobFinished = $false
            Write-Host "$($this.DatabaseFileName) SaveToXMLAsync is still running. Waiting..." -NoNewline -ForegroundColor DarkGray
            while (-not $jobFinished) {
                $signaled = $this.AsynchronousSaveOperationState.BeginInvokeResult.AsyncWaitHandle.WaitOne(250)
                if ($signaled) {
                    $jobFinished = $true
                } else {
                    Write-Host "." -NoNewline -ForegroundColor DarkGray
                    if (([datetime]::Now - $start) -gt $maxWait) {
                        Write-Host ""
                        Write-Warning "WFASTX1. Async operation has exceeded allowed time. Stopping background process."
                        try {
                            if ($this.AsynchronousSaveOperationState.PSEventJob -and $this.AsynchronousSaveOperationState.PSEventJob.Name) {
                                Unregister-Event -SourceIdentifier $this.AsynchronousSaveOperationState.PSEventJob.Name -ErrorAction SilentlyContinue
                            }
                            if ($this.AsynchronousSaveOperationState.PSInstance) {
                                $this.AsynchronousSaveOperationState.PSInstance.BeginStop($null, $null)
                            }
                            if ($this.AsynchronousSaveOperationState.Pool -and -not $this.AsynchronousSaveOperationState.Pool.IsDisposed) {
                                $this.AsynchronousSaveOperationState.Pool.Close()
                                $this.AsynchronousSaveOperationState.Pool.Dispose()
                            }
                        } catch {}
                        $this.AsynchronousSaveOperationState.Pool = $null
                        $this.AsynchronousSaveOperationState.PSInstance = $null
                        $this.AsynchronousSaveOperationState.PsEventJob = $null
                        $this.AsynchronousSaveOperationState.BeginInvokeResult = $null
                        break
                    }
                }
            }
            Write-Host ""
            # If stream ended successfully give PSEventJob to finish max 2 sec
            if ($jobFinished) {
                $startEventWait = [datetime]::Now
                while ($this.AsynchronousSaveOperationState.PSEventJob -and ($this.AsynchronousSaveOperationState.PSEventJob.State -eq [System.Management.Automation.JobState]::NotStarted -or $this.AsynchronousSaveOperationState.PSEventJob.State -eq [System.Management.Automation.JobState]::Running)) {
                    if (([datetime]::Now - $startEventWait).TotalSeconds -gt 2) { break }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        # Checking previous job event
        if ($this.AsynchronousSaveOperationState.PSEventJob -and $this.AsynchronousSaveOperationState.PSEventJob.State -in $this.BadEventJobStates) {
            Write-Warning "WARNING! WFASTX2. Bad previous PSEventJob state = $($this.AsynchronousSaveOperationState.PSEventJob.State)."
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousSaveOperationState)
        } elseif ($this.AsynchronousSaveOperationState.PSEventJob -and $this.AsynchronousSaveOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Stopped -and $this.AsynchronousSaveOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Completed) {
            Write-Warning "WARNING! WFASTX3. Previous event job is not completed. Status $($this.AsynchronousSaveOperationState.PSEventJob.State)"
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousSaveOperationState)
        } elseif ($this.AsynchronousSaveOperationState.PSInstance -and $this.AsynchronousSaveOperationState.PSInstance.HadErrors) {
            Write-Warning "WARNING! WFASTX4.  Previous PSInstance had errors."
            $this.writeAsyncInstanceErrors($this.AsynchronousSaveOperationState.PSInstance, 'AsyncSave')
        }
        # The Event Action calls CleanupAsync on completion. We only null the references if they are already completed.
        if ($this.AsynchronousSaveOperationState.BeginInvokeResult -and $this.AsynchronousSaveOperationState.BeginInvokeResult.IsCompleted) {
            $this.AsynchronousSaveOperationState.PSInstance = $null
            $this.AsynchronousSaveOperationState.PsEventJob = $null
        }
    }
    # Asynchronously save database to XML files
    [void] SaveToDiskAsync() {
        if ($this.ReadOnlyMode) { return }
        $this.ErrorLevel = $null
        $this.ErrorText  = $null
        # Storage format extension for the main-file existence check
        $mainExt = 'json'
        if ($this.StorageFormat -eq 'Xml') { $mainExt = 'xml' }
        $mainPath = "$(Join-Path $this.DatabaseFolderPath $this.DatabaseFileName)_main.$mainExt"
        # Wait for previous async save BEFORE Consolidate to prevent its finally-block from resetting IsForceSaveMain that Consolidate sets
        $this.WaitForAsyncSaveToDisk()
        # If updates database is bigger than 30% of main
        if ($this.MainHT.Count * 0.3 -lt $this.GetPendingChangesCount()) {
            $this.CompactDatabase()
        }
        # If there is no main file - force creating it
        if (-not [System.IO.File]::Exists($mainPath)) { $this.IsForceSaveMain = $true }
        # Runspace to save async
        if (-Not $this.AsynchronousSaveOperationState.Pool -or $this.AsynchronousSaveOperationState.Pool.IsDisposed) {
            $poolSaveToXMLAsync = [runspacefactory]::CreateRunspacePool(1,1)
            $poolSaveToXMLAsync.Open()
            $this.AsynchronousSaveOperationState.Pool = $poolSaveToXMLAsync
        } else {
            $poolSaveToXMLAsync = $this.AsynchronousSaveOperationState.Pool
        }
        # Running async save
        try {
            $this.AsynchronousSaveOperationState.PSInstance = [PowerShell]::Create()
            $this.AsynchronousSaveOperationState.PSInstance.RunspacePool = $poolSaveToXMLAsync
            $null = $this.AsyncResults.Clear()
            # Pass references: snapshots are not cloned because CompactDatabase() swaps whole CD instances atomically.
            $null = $this.AsynchronousSaveOperationState.PSInstance.AddScript($Script:HashtableDB1Class_SaveScriptBlock).AddArgument($this).AddArgument($this.MainHT).AddArgument($this.UpdatesHT).AddArgument($this.RemovedHT)
            $asyncResult = $this.AsynchronousSaveOperationState.PSInstance.BeginInvoke()
            $msgData = @{
                AsyncResult = $asyncResult
                thisObj = $this
            }
            # Resources release
            $this.AsynchronousSaveOperationState.PSEventJob = Register-ObjectEvent -InputObject $this.AsynchronousSaveOperationState.PSInstance -EventName InvocationStateChanged -Action {
                    $PSInstance = $event.Sender
                    $msgData = $Event.MessageData
                    $localAsyncResult = $msgData.AsyncResult
                    $thisObj = $msgData.thisObj
                    try {
                        $null = $PSInstance.EndInvoke($localAsyncResult)
                    } catch {
                        $thisObj.ErrorLevel = "STXASNC1"
                        $thisObj.ErrorText  = $_.Exception.Message
                    } finally {
                        [HashTableDB1]::CleanupAsync([ref]$thisObj.AsynchronousSaveOperationState)
                    }
            } -MessageData $msgData
            $this.AsynchronousSaveOperationState.BeginInvokeResult = $asyncResult
            # Saving TX Log if enabled
            if ($this.EnableTransactionLog) {
                $this.SaveTransactionLogAsync()
            }
        } catch {
            $this.ErrorLevel = "ASYNC2"
            $this.ErrorText  = "Failed to start async save: $($_.Exception.Message)"
            # Dispose PSInstance on failure to prevent resource leak
            if ($this.AsynchronousSaveOperationState.PSInstance) {
                try { $this.AsynchronousSaveOperationState.PSInstance.Dispose() } catch {}
                $this.AsynchronousSaveOperationState.PSInstance = $null
            }
        }
    }
    # Wait for previous async to finish
    [void] WaitForPendingTransactionLogOperations() {
        # If async load still in progress - wait for it to finish.
        if ($this.AsynchronousTransactionLogSaveState.BeginInvokeResult -and -not $this.AsynchronousTransactionLogSaveState.BeginInvokeResult.IsCompleted) {
            $maxWait = [System.TimeSpan]::FromSeconds($this.LockFileMaxWaitTime)
            $start   = [datetime]::Now
            $jobFinished = $false
            Write-Host "$($this.DatabaseFileName) SaveTransactionLogAsync is still running. Waiting..." -NoNewline -ForegroundColor DarkGray
            while (-not $jobFinished) {
                $signaled = $this.AsynchronousTransactionLogSaveState.BeginInvokeResult.AsyncWaitHandle.WaitOne(250)
                if ($signaled) {
                    $jobFinished = $true
                } else {
                    Write-Host "." -NoNewline -ForegroundColor DarkGray
                    if (([datetime]::Now - $start) -gt $maxWait) {
                        Write-Host ""
                        Write-Warning "WFASTXTX1. Async operation has exceeded allowed time. Stopping background process."
                        # 1. Unregister the event so its Action won't try to wait for EndInvoke() and hang
                        if ($this.AsynchronousTransactionLogSaveState.PSEventJob -and $this.AsynchronousTransactionLogSaveState.PSEventJob.Name) {
                            try { Unregister-Event -SourceIdentifier $this.AsynchronousTransactionLogSaveState.PSEventJob.Name -ErrorAction SilentlyContinue } catch {}
                        }
                        # 2. Asynchronously send a command to stop the PSInstance (does not block the thread)
                        try {
                            if ($this.AsynchronousTransactionLogSaveState.PSInstance) {
                                $this.AsynchronousTransactionLogSaveState.PSInstance.BeginStop($null, $null)
                            }
                        } catch {}
                        # 3. FORCE-fully kill the RunspacePool. This will destroy the zombie thread.
                        try {
                            if ($this.AsynchronousTransactionLogSaveState.Pool -and -not $this.AsynchronousTransactionLogSaveState.Pool.IsDisposed) {
                                $this.AsynchronousTransactionLogSaveState.Pool.Close()
                                $this.AsynchronousTransactionLogSaveState.Pool.Dispose()
                            }
                        } catch {}
                        # 4. Null-out all references so the class will recreate the Pool on the next run
                        $this.AsynchronousTransactionLogSaveState.Pool = $null
                        $this.AsynchronousTransactionLogSaveState.PSInstance = $null
                        $this.AsynchronousTransactionLogSaveState.PsEventJob = $null
                        $this.AsynchronousTransactionLogSaveState.BeginInvokeResult = $null
                        break
                    }
                }
            }
            Write-Host ""
            if ($jobFinished) {
                $startEventWait = [datetime]::Now
                while ($this.AsynchronousTransactionLogSaveState.PSEventJob -and ($this.AsynchronousTransactionLogSaveState.PSEventJob.State -eq [System.Management.Automation.JobState]::NotStarted -or $this.AsynchronousTransactionLogSaveState.PSEventJob.State -eq [System.Management.Automation.JobState]::Running)) {
                    if (([datetime]::Now - $startEventWait).TotalSeconds -gt 2) { break }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        # Checking previous job event
        if ($this.AsynchronousTransactionLogSaveState.PSEventJob -and $this.AsynchronousTransactionLogSaveState.PSEventJob.State -in $this.BadEventJobStates) {
            Write-Warning "WARNING! WFASTXTX2. Bad previous PSEventJob state = $($this.AsynchronousTransactionLogSaveState.PSEventJob.State)."
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousTransactionLogSaveState)
        } elseif ($this.AsynchronousTransactionLogSaveState.PSEventJob -and $this.AsynchronousTransactionLogSaveState.PSEventJob.State -ne [System.Management.Automation.JobState]::Stopped -and $this.AsynchronousTransactionLogSaveState.PSEventJob.State -ne [System.Management.Automation.JobState]::Completed) {
            Write-Warning "WARNING! WFASTXTX3. Previous event job is not completed. Status $($this.AsynchronousTransactionLogSaveState.PSEventJob.State)"
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousTransactionLogSaveState)
        } elseif ($this.AsynchronousTransactionLogSaveState.PSInstance -and $this.AsynchronousTransactionLogSaveState.PSInstance.HadErrors) {
            Write-Warning "WARNING! WFASTXTX4.  Previous PSInstance had errors."
            $this.writeAsyncInstanceErrors($this.AsynchronousTransactionLogSaveState.PSInstance, 'AsyncSaveTx')
        }
        # Avoid manual disposal here to prevent race conditions with Register-ObjectEvent Action.
        if ($this.AsynchronousTransactionLogSaveState.BeginInvokeResult -and $this.AsynchronousTransactionLogSaveState.BeginInvokeResult.IsCompleted) {
            $this.AsynchronousTransactionLogSaveState.PSInstance = $null
            $this.AsynchronousTransactionLogSaveState.PsEventJob = $null
        }
    }
    [void]  writeAsyncInstanceErrors($psInst, [string]$Source = 'AsyncOp') {
        $collected = @()
        if ($psInst.HadErrors) {
            if ($psInst.Streams.Error.Count -gt 0) {
                foreach ($e in $psInst.Streams.Error) {
                    $collected += [pscustomobject]@{
                        Source   = 'ErrorStream'
                        Type     = $e.Exception.GetType().FullName
                        Message  = $e.Exception.Message
                        Category = $e.CategoryInfo.Category
                        Id       = $e.FullyQualifiedErrorId
                        Stack    = $e.ScriptStackTrace
                    }
                }
            }
            if ($psInst.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Failed) {
                $ex = $psInst.InvocationStateInfo.Reason
                if ($ex) {
                    $collected += [pscustomobject]@{
                        Source   = 'InvocationStateInfo'
                        Type     = $ex.GetType().FullName
                        Message  = $ex.Message
                        Category = $null
                        Id       = $null
                        Stack    = $ex.ScriptStackTrace
                    }
                }
            }
        }
        foreach ($err in $collected) {
            $msg = "[$Source] {0}: {1}" -f $err.Source, $err.Message
            if ($err.Stack) { $msg += "`nStackTrace:`n$($err.Stack)" }
            Write-Warning $msg
        }
    }
    # Asynchronously save transaction log
    [void] SaveTransactionLogAsync() {
        if ($this.ReadOnlyMode) { return }
        $this.ErrorLevel = $null
        $this.ErrorText  = $null
        $ktSnap = $this.KeyToTick
        $tkSnap = $this.TickToKeys
        # Ensure any previous async operation has finished
        $this.WaitForPendingTransactionLogOperations()
        # Runspace to save async
        if (-Not $this.AsynchronousTransactionLogSaveState.Pool -or $this.AsynchronousTransactionLogSaveState.Pool.IsDisposed) {
            $SaveTransactionLogAsyncPool = [runspacefactory]::CreateRunspacePool(1,1)
            $SaveTransactionLogAsyncPool.Open()
            $this.AsynchronousTransactionLogSaveState.Pool = $SaveTransactionLogAsyncPool
        } else {
            $SaveTransactionLogAsyncPool = $this.AsynchronousTransactionLogSaveState.Pool
        }
        try {
            $this.AsynchronousTransactionLogSaveState.PSInstance = [PowerShell]::Create()
            $this.AsynchronousTransactionLogSaveState.PSInstance.RunspacePool = $SaveTransactionLogAsyncPool
            $TxLogsPath = Join-Path $this.DatabaseFolderPath "TxLog"
            $null = $this.AsynchronousTransactionLogSaveState.PSInstance.AddScript($Script:HashtableDB1Class_SaveTxLogScriptBlock).AddArgument($this).AddArgument($ktSnap).AddArgument($tkSnap).AddArgument($TxLogsPath)
            $asyncResult = $this.AsynchronousTransactionLogSaveState.PSInstance.BeginInvoke()
            $msg = @{
                AsyncResult = $asyncResult
                ThisObject  = $this
            }
            # Resources release handler
            $this.AsynchronousTransactionLogSaveState.PSEventJob = Register-ObjectEvent -InputObject $this.AsynchronousTransactionLogSaveState.PSInstance -EventName InvocationStateChanged -Action {
                    $localPSInstance = $event.Sender
                    $iar    = $event.MessageData.AsyncResult
                    $thisObj = $event.MessageData.thisObject
                    try {
                        $null = $localPSInstance.EndInvoke($iar)
                    } catch {
                        $thisObj.ErrorLevel = "TXLOG2"
                        $thisObj.ErrorText  = $_.Exception.Message
                    } finally {
                        [HashTableDB1]::CleanupAsync([ref]$thisObj.AsynchronousTransactionLogSaveState)
                    }
            } -MessageData $msg
            $this.AsynchronousTransactionLogSaveState.BeginInvokeResult = $asyncResult
        } catch {
            $this.ErrorLevel = "TXLOG3"
            $this.ErrorText = "Failed to start async TxLog save: $($_.Exception.Message)"
        }
    }
    # Load database from 3 XML files to class memory
    [boolean] LoadFromDisk() {
        $this.ErrorLevel = $null
        $this.ErrorText = $null
        $this.WaitForAsyncLoadFromDisk()
        try {
            # Direct invocation of the shared load script block
            $loadResult = & $Script:HashtableDB1Class_LoadScriptBlock $this
            if (-not $loadResult.Success) {
                $this.ErrorLevel = $loadResult.ErrorLevel
                $this.ErrorText = $loadResult.ErrorText
                if ($loadResult.ErrorLevel -eq "LFX1") {
                    # Missing main DB on first run is normal: create empty state, reset error
                    $this.CreateEmptyDB()
                    $this.ErrorLevel = 0
                    $this.ErrorText = $null
                }
                return $false
            }
            # No errors. Setting errorlevel to 0
            $this.ErrorLevel = 0
            # If no data was loaded (files not newer), return false
            if (-not $loadResult.DataIsLoaded) {
                return $false
            }
            # Restore PS class instances ('~C' markers) only when the converter detected class markers in the
            # loaded files. Skipping the full-tree traversal is the main load-time optimization for class-free
            # datasets. Runs in the current session where user classes are defined, not in the async runspace.
            # C# traversal + C# rehydration with a PS fallback (parameterless-ctor types are handled natively;
            # exotic constructors fall back to the PS TryRehydrate scriptblock).
            if ($loadResult.ClassMarkersFound) {
                $converterType = 'PSObjectJsonConverter' -as [type]
                # Standard workaround for class method bodies: NO [PSObjectJsonConverter+...] type literals
                # here - class methods bind type literals at compile time, before Add-Type has executed.
                # System.Func is a BCL type (always resolvable); the scriptblock converts to the delegate at runtime.
                $typeResolver = [Func[string,Type]] { param($className) $className -as [type] }
                foreach ($rootHT in @($loadResult.MainHT, $loadResult.UpdatesHT, $loadResult.DatabaseParamsHT)) {
                    if ($null -eq $rootHT) { continue }
                    $pendingNodes = $converterType::CollectClassNodes(@($rootHT))
                    for ($i = $pendingNodes.Count - 1; $i -ge 0; $i--) {
                        $frame = $pendingNodes[$i]
                        $node = $frame[2]
                        $rehydrated = $converterType::RehydrateClassNode($node, $typeResolver)
                        if ($null -eq $rehydrated) { $rehydrated = & $Script:HashtableDB1Class_TryRehydrateScriptBlock $node }
                        if ($null -eq $rehydrated) { continue }
                        $parent = $frame[0]
                        if ($null -eq $parent) {
                            # Root itself was a class node: replace the root reference in the result
                            if ([object]::ReferenceEquals($rootHT, $loadResult.MainHT)) { $loadResult.MainHT = $rehydrated }
                            elseif ([object]::ReferenceEquals($rootHT, $loadResult.UpdatesHT)) { $loadResult.UpdatesHT = $rehydrated }
                            elseif ([object]::ReferenceEquals($rootHT, $loadResult.DatabaseParamsHT)) { $loadResult.DatabaseParamsHT = $rehydrated }
                            continue
                        }
                        $slot = $frame[1]
                        if ($parent -is [System.Collections.IDictionary]) { $parent[$slot] = $rehydrated }
                        elseif ($parent -is [System.Array]) { $parent[$slot] = $rehydrated }
                        else { try { $parent."$slot" = $rehydrated } catch { } }
                    }
                }
            }
            # Runtime type resolution for dictionary builders (kept from the previous optimization)
            $converterType = 'PSObjectJsonConverter' -as [type]
            if (-not $converterType) { throw "PSObjectJsonConverter type is not loaded. Add-Type failed or was skipped." }
            # Build all CDs as local variables, then assign atomically to prevent concurrent readers from seeing
            # partially populated collections. C# helpers replace the slow PowerShell copy loops.
            # NOTE: the converter type must be resolved at runtime ('-as [type]') - class method bodies
            # bind type literals at compile time, before Add-Type at the top of this file has executed.
            if ($null -ne $loadResult.MainHT) {
                $this.MainHT = $converterType::BuildConcurrentDictionary($loadResult.MainHT, $null)
            }
            if ($null -ne $loadResult.UpdatesHT) {
                $this.UpdatesHT = $converterType::BuildConcurrentDictionary($loadResult.UpdatesHT, $null)
            }
            if ($null -ne $loadResult.RemovedHT) {
                # Do not load the internal DB params marker into the live RemovedHT
                $this.RemovedHT = $converterType::BuildConcurrentDictionary($loadResult.RemovedHT, "___DATABASEPARAMS___")
                $this.DatabaseParamsHT = $loadResult.DatabaseParamsHT
            } else {
                $this.DatabaseParamsHT = @{ }
            }
            $this.MainFileLoadedDT = $loadResult.MainFileLoadedDT
            $this.UpdatesFileLoadedDT = $loadResult.UpdatesFileLoadedDT
            $this.RemovedFileLoadedDT = $loadResult.RemovedFileLoadedDT
            # Rebuild merged hashtable, then assign atomically (C# helper - fast).
            # $converterType was resolved above at runtime for the same compile-time binding reason.
            $this.MergedHT = $converterType::BuildMergedDictionary($this.MainHT, $this.UpdatesHT, $this.RemovedHT)
            # Clear TxLog in-memory state since DB state is fully replaced by loaded data
            if ($this.EnableTransactionLog) {
                $this.KeyToTick.Clear()
                [System.Threading.Monitor]::Enter($this.TickToKeysLock)
                try {
                    $this.TickToKeys.Clear()
                } finally {
                    [System.Threading.Monitor]::Exit($this.TickToKeysLock)
                }
                $this.LastTransactionLogSavedTimestamp = 0
            }
            # Cross-format migration: loaded files differ from the class StorageFormat - resave in the
            # current format; the save path archives the old-format files so the folder always holds one format
            if ($loadResult.LoadedFormat -and ($loadResult.LoadedFormat -ne $this.StorageFormat)) {
                $this.SaveToDisk()
            }
            return $true
        } catch {
            $this.ErrorLevel = "LTX8"
            $this.ErrorText = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
            $this.CreateEmptyDB()
            return $false
        }
    }
    # Wait for previous async to finish
    [void] WaitForAsyncLoadFromDisk() {
        # If async load still in progress - wait for it to finish.
        if ($this.AsynchronousLoadOperationState.BeginInvokeResult -and -not $this.AsynchronousLoadOperationState.BeginInvokeResult.IsCompleted) {
            $maxWait = [System.TimeSpan]::FromSeconds($this.LockFileMaxWaitTime)
            $start   = [datetime]::Now
            $jobFinished = $false
            Write-Host "$($this.DatabaseFileName) AsyncLoadFromDisk is still running. Waiting..." -NoNewline -ForegroundColor DarkGray
            while (-not $jobFinished) {
                $signaled = $this.AsynchronousLoadOperationState.BeginInvokeResult.AsyncWaitHandle.WaitOne(250)
                if ($signaled) {
                    $jobFinished = $true
                } else {
                    Write-Host "." -NoNewline -ForegroundColor DarkGray
                    if (([datetime]::Now - $start) -gt $maxWait) {
                        Write-Host ""
                        Write-Warning "WFALFX1. Async operation has exceeded allowed time. Stopping background process."
                        try {
                            if ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.Name) {
                                Unregister-Event -SourceIdentifier $this.AsynchronousLoadOperationState.PSEventJob.Name -ErrorAction SilentlyContinue
                            }
                            if ($this.AsynchronousLoadOperationState.PSInstance) {
                                $this.AsynchronousLoadOperationState.PSInstance.BeginStop($null, $null)
                            }
                            if ($this.AsynchronousLoadOperationState.Pool -and -not $this.AsynchronousLoadOperationState.Pool.IsDisposed) {
                                $this.AsynchronousLoadOperationState.Pool.Close()
                                $this.AsynchronousLoadOperationState.Pool.Dispose()
                            }
                        } catch {}
                        $this.AsynchronousLoadOperationState.Pool = $null
                        $this.AsynchronousLoadOperationState.PSInstance = $null
                        $this.AsynchronousLoadOperationState.PsEventJob = $null
                        $this.AsynchronousLoadOperationState.BeginInvokeResult = $null
                        break
                    }
                }
            }
            Write-Host ""
            if ($jobFinished) {
                $startEventWait = [datetime]::Now
                while ($this.AsynchronousLoadOperationState.PSEventJob -and ($this.AsynchronousLoadOperationState.PSEventJob.State -eq [System.Management.Automation.JobState]::NotStarted -or $this.AsynchronousLoadOperationState.PSEventJob.State -eq [System.Management.Automation.JobState]::Running)) {
                    if (([datetime]::Now - $startEventWait).TotalSeconds -gt 2) { break }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        # Checking previous job event
        if ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.State -in $this.BadEventJobStates) {
            Write-Warning "WARNING! WFALFX2. Bad previous PSEventJob state = $($this.AsynchronousLoadOperationState.PSEventJob.State)."
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousLoadOperationState)
        } elseif ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Stopped -and $this.AsynchronousLoadOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Completed) {
            Write-Warning "WARNING! WFALFX3. Previous event job is not completed. Status $($this.AsynchronousLoadOperationState.PSEventJob.State)"
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousLoadOperationState)
        } elseif ($this.AsynchronousLoadOperationState.PSInstance -and $this.AsynchronousLoadOperationState.PSInstance.HadErrors) {
            Write-Warning "WARNING! WFALFX4.  Previous PSInstance had errors."
            $this.writeAsyncInstanceErrors($this.AsynchronousLoadOperationState.PSInstance, 'AsyncLoad')
        }
        # FIXED Double Dispose: Avoid manual disposal here to prevent race conditions with Register-ObjectEvent Action.
        if ($this.AsynchronousLoadOperationState.BeginInvokeResult -and $this.AsynchronousLoadOperationState.BeginInvokeResult.IsCompleted) {
            $this.AsynchronousLoadOperationState.PSInstance = $null
            $this.AsynchronousLoadOperationState.PsEventJob = $null
        }
    }
    # Asynchronous load from XML files. Usually used for preloading large databases in background
    [void] LoadFromDiskAsync() {
        $this.ErrorLevel = $null; $this.ErrorText = $null; $this.WaitForAsyncLoadFromDisk()
        $PSInstance =$null
        # Runspace for async loading
        if (-Not $this.AsynchronousLoadOperationState.Pool -or $this.AsynchronousLoadOperationState.Pool.IsDisposed) {
            $poolLoadFromDiskAsync = [runspacefactory]::CreateRunspacePool(1,1)
            $poolLoadFromDiskAsync.Open()
            $this.AsynchronousLoadOperationState.Pool = $poolLoadFromDiskAsync
        } else {
            # Reusing the same pool every time
            $poolLoadFromDiskAsync = $this.AsynchronousLoadOperationState.Pool
        }
        # Checking previous job event
        if ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.State -in $this.BadEventJobStates) {
            Write-Warning "WARNING! LFXMLASNC1. Bad previous PSEventJob state = $($this.AsynchronousLoadOperationState.PSEventJob.State)."
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousLoadOperationState)
        } elseif ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Stopped -and $this.AsynchronousLoadOperationState.PSEventJob.State -ne [System.Management.Automation.JobState]::Completed) {
            Write-Warning "WARNING! LFXMLASNC2. Previous event job is not completed for some reason. Current status $($this.AsynchronousLoadOperationState.PSEventJob.State)"
            [HashTableDB1]::CleanupAsync([ref]$this.AsynchronousLoadOperationState)
        } elseif ($this.AsynchronousLoadOperationState.PSInstance -and $this.AsynchronousLoadOperationState.PSInstance.HadErrors) {
            Write-Warning "WARNING! LFXMLASNC3.  Previous PSInstance had errors."
            $this.writeAsyncInstanceErrors($this.AsynchronousLoadOperationState.PSInstance)
        }
        # FIXED Double Dispose: Avoid manual disposal here to prevent race conditions with Register-ObjectEvent Action.
        if ($this.AsynchronousLoadOperationState.BeginInvokeResult -and $this.AsynchronousLoadOperationState.BeginInvokeResult.IsCompleted) {
            $this.AsynchronousLoadOperationState.PSInstance = $null
            $this.AsynchronousLoadOperationState.PsEventJob = $null
        }
        try {
            $PSInstance = [PowerShell]::Create()
            $PSInstance.RunspacePool = $poolLoadFromDiskAsync
            $null = $this.AsyncResults.Clear()
            $null = $PSInstance.AddScript($Script:HashtableDB1Class_LoadAsyncScriptBlock).AddArgument($this).AddArgument($Script:HashtableDB1Class_LoadScriptBlock)
            $asyncResult = $PSInstance.BeginInvoke()
            # Assign PSInstance AFTER BeginInvoke succeeds so we don't leak a reference on throw
            $this.AsynchronousLoadOperationState.PSInstance = $PSInstance
            $msgData = @{
                thisObj = $this
                asyncResult  = $asyncResult
                # Pass the rehydrate scriptblock explicitly: Script: scope may be unavailable inside the event job
                tryRehydrateScriptBlock = $Script:HashtableDB1Class_TryRehydrateScriptBlock
                # Converter type name resolved at runtime inside the event action (class literal is
                # unavailable there): RehydrateClassNode / CollectClassNodes fast path for '~C' nodes
                converterTypeName = 'PSObjectJsonConverter'
            }
            $this.AsynchronousLoadOperationState.PSEventJob = Register-ObjectEvent -InputObject $PSInstance -EventName InvocationStateChanged -Action {
                $PSInstance = $event.Sender
                $messageData = $event.MessageData
                $thisObj = $messageData.thisObj
                $asyncResult = $messageData.asyncResult
                try {
                    # End the invocation properly. Guard against empty output array if scriptblock threw before return.
                    $loadResultArray = $PSInstance.EndInvoke($asyncResult)
                    if (-not $loadResultArray -or $loadResultArray.Count -eq 0) {
                        $thisObj.AsyncResults['Success'] = $false
                        $thisObj.AsyncResults['Error'] = 'EndInvoke returned no output'
                        $thisObj.AsyncResults['Message'] = "Async load error: EndInvoke returned no output"
                        $thisObj.ErrorLevel = "ALOAD2"
                        $thisObj.ErrorText = "EndInvoke returned no output"
                        return
                    }
                    $loadResult = $loadResultArray[0]
                    if ($loadResult.Success -and $loadResult.DataIsLoaded) {
                        # Process '~C' nodes collected by the background runspace (Phase 3) in reverse order
                        # (children before parents) so nested instances are rehydrated before their containers
                        # copy them out of raw hashtables. Covers MainHT, UpdatesHT and DatabaseParamsHT.
                        # Depth-1 nodes need live-CD patches: the raw top-level hashtables are NOT the live
                        # ConcurrentDictionaries (built in Phase 2 before rehydration ran).
                        $restoreSB = $messageData.tryRehydrateScriptBlock
                        $pendingNodes = $loadResult.PendingClassNodes
                        if ($pendingNodes -and $pendingNodes.Count -gt 0) {
                            # C# rehydration first (fast path), PS scriptblock as fallback for exotic
                            # constructors. The type resolver is a PS delegate because user classes
                            # are only resolvable in this (main session) context.
                            $converterType = 'PSObjectJsonConverter' -as [type]
                            # Same class-body workaround: BCL Func type literal, scriptblock converts at runtime
                            $typeResolver = [Func[string,Type]] { param($className) $className -as [type] }
                            $mainHTRaw = $loadResult.MainHT
                            $updatesHTRaw = $loadResult.UpdatesHT
                            for ($i = $pendingNodes.Count - 1; $i -ge 0; $i--) {
                                $frame = $pendingNodes[$i]
                                $node = $frame[2]
                                $rehydrated = $converterType::RehydrateClassNode($node, $typeResolver)
                                if ($null -eq $rehydrated -and $restoreSB) { $rehydrated = & $restoreSB $node }
                                if ($null -eq $rehydrated -or $null -eq $frame[0]) { continue }
                                $parent = $frame[0]
                                $slot = $frame[1]
                                $slotKey = [string]$slot
                                if ([object]::ReferenceEquals($parent, $mainHTRaw)) {
                                    # Top-level main value: patch MainHT; merged only when not overridden by updates/removals
                                    $thisObj.MainHT[$slotKey] = $rehydrated
                                    if (-not $thisObj.RemovedHT.ContainsKey($slotKey) -and -not ($updatesHTRaw -and $updatesHTRaw.ContainsKey($slotKey))) { $thisObj.MergedHT[$slotKey] = $rehydrated }
                                } elseif ([object]::ReferenceEquals($parent, $updatesHTRaw)) {
                                    # Top-level updates value: patch UpdatesHT and merged (unless tombstoned)
                                    $thisObj.UpdatesHT[$slotKey] = $rehydrated
                                    if (-not $thisObj.RemovedHT.ContainsKey($slotKey)) { $thisObj.MergedHT[$slotKey] = $rehydrated }
                                } elseif ($parent -is [System.Collections.IDictionary]) {
                                    # Nested container (incl. DatabaseParamsHT - shared by reference with Phase 2): patch in place
                                    $parent[$slot] = $rehydrated
                                } elseif ($parent -is [System.Array]) {
                                    $parent[$slot] = $rehydrated
                                } else {
                                    try { $parent."$slot" = $rehydrated } catch { }
                                }
                            }
                        }
                        # All ConcurrentDictionaries, timestamps, DatabaseParamsHT, MergedHT and TxLog state
                        # were already built and published by the background runspace (Phase 2). Rehydrated
                        # nested containers are shared by reference with the live CDs (patched in place above),
                        # and depth-1 slots were patched directly - no rebuild is needed here. This keeps the
                        # main-thread event action lightweight and removes the multi-second freeze on large datasets.
                        $thisObj.AsyncResults['Success'] = $true
                        $thisObj.AsyncResults['Message'] = "Database $($thisObj.DatabaseFileName) loaded Asynchronously in $( [math]::Round($loadResult.LoadTime,3)) sec."
                        $thisObj.ErrorLevel = 0
                        # Cross-format migration: loaded files differ from StorageFormat - start an async
                        # resave; the save path archives the old-format files so the folder holds one format.
                        # SaveToDiskAsync clears AsyncResults and repopulates them on completion, so a waiter
                        # blocks until the migration save has finished.
                        if ($loadResult.LoadedFormat -and ($loadResult.LoadedFormat -ne $thisObj.StorageFormat)) {
                            $thisObj.SaveToDiskAsync()
                        }
                    } elseif ($loadResult.Success) {
                        # Success but no new data to load (files not newer)
                        $thisObj.AsyncResults['Success'] = $true
                        $thisObj.AsyncResults['Message'] = "No new data to load"
                    } elseif ($loadResult.ErrorLevel -eq "LFX1") {
                        # Missing main DB on first run is normal: create empty state
                        $thisObj.CreateEmptyDB()
                        $thisObj.AsyncResults['Success'] = $true
                        $thisObj.AsyncResults['Message'] = "Database does not exist. Created empty state."
                        $thisObj.ErrorLevel = 0
                        $thisObj.ErrorText = $null
                    } else {
                        $thisObj.AsyncResults['Success'] = $false
                        $thisObj.AsyncResults['Error'] = $loadResult.ErrorText
                        $thisObj.AsyncResults['Message'] = "Load failed: $($loadResult.ErrorText)"
                        $thisObj.ErrorLevel = $loadResult.ErrorLevel
                        $thisObj.ErrorText = $loadResult.ErrorText
                    }
                } catch {
                    $thisObj.AsyncResults['Success'] = $false
                    $thisObj.AsyncResults['Error'] = $_.Exception.Message
                    $thisObj.AsyncResults['Message'] = "Async load error: $($_.Exception.Message)"
                    Write-Warning "Async operation finished with error: $($_.Exception.Message)"
                } finally {
                    [HashTableDB1]::CleanupAsync([ref]$thisObj.AsynchronousLoadOperationState)
                }
            } -MessageData $msgData
            $this.AsynchronousLoadOperationState.BeginInvokeResult = $asyncResult
        } catch {
            $this.ErrorLevel = "ALOAD1"
            $this.ErrorText = "Failed to start async load: $($_.Exception.Message)"
            # Dispose PSInstance on failure to prevent resource leak
            if ($PSInstance) {
                try { $PSInstance.Dispose() } catch {}
                $this.AsynchronousLoadOperationState.PSInstance = $null
            }
        }
    }
    # Creates database folder if it doesn't exist and sets read permissions for specified SID or write if it is specified.
    [void] EnsureDBFolderWithPermissions($SID, [bool]$AllowWrite = $false) {
        $this.ErrorLevel = $null
        $this.ErrorText = $null
        try {
            # Ensure the directory exists
            if (-not [System.IO.Directory]::Exists($this.DatabaseFolderPath)) {
                Write-Host "Creating database directory: $($this.DatabaseFolderPath)"
                $null = [System.IO.Directory]::CreateDirectory($this.DatabaseFolderPath)
            }
            if ($null -eq $SID) { return }
            # Get the current ACL (for the directory)
            $acl = Get-Acl -LiteralPath $this.DatabaseFolderPath
            # Create the access rule
            $userSid = New-Object System.Security.Principal.SecurityIdentifier($SID)
            # Base rule - only reading
            $rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
            # If modify is needed
            if ($AllowWrite) {
                $rights = $rights -bor [System.Security.AccessControl.FileSystemRights]::Modify
            }
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $userSid,                                   # IdentityReference - SID object
                $rights,                                    # File system rights
                'ContainerInherit, ObjectInherit',          # Inheritance flags
                'None',                                     # Propagation flags
                'Allow'                                     # Rule type
            )
            $writeBits = [System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Delete -bor [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
            # Check if the rule already exists. Do not break on exact match to ensure all mismatched rules are collected.
            $exists = $false
            $rulesToRemove = [System.Collections.ArrayList]::new()
            foreach ($r in $acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier])) {
                $sameSid   = $r.IdentityReference.Value -eq $SID
                $isAllow   = $r.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
                $isWriteNowAllowed = (($r.FileSystemRights -band $writeBits) -ne 0)
                # Exact match for desired state
                if ($sameSid -and $isAllow -and ($r.FileSystemRights -eq $rights) -and ($isWriteNowAllowed -eq $AllowWrite)) {
                    $exists = $true
                # Mismatched write state for same SID should be removed
                } elseif ($sameSid -and $isAllow -and ($isWriteNowAllowed -ne $AllowWrite)) {
                    $null = $rulesToRemove.Add($r)
                }
            }
            # Remove outside of iteration to prevent InvalidOperationException
            if ($rulesToRemove.Count -gt 0) {
                foreach ($rule in $rulesToRemove) {
                    $acl.RemoveAccessRule($rule) | Out-Null
                }
            }
            if (-not $exists) {
                $acl.AddAccessRule($accessRule)
            }
            # Apply changes if new rule added or mismatched rules were removed
            if ((-not $exists) -or $rulesToRemove.Count -gt 0) {
                Set-Acl -LiteralPath $this.DatabaseFolderPath -AclObject $acl
                Write-Host "Read$(if ($AllowWrite) {" and write"}) permissions for $($this.DatabaseFolderPath) granted for SID: $SID"
            } else {
                # Needed permissions already exist
                $this.ErrorLevel = 0
                return
            }
            $this.ErrorLevel = 0
        } catch {
            $this.ErrorLevel = "EDBFP1"
            $this.ErrorText = $_.Exception.Message
            Write-Error "Failed to ensure database folder with permissions: $($_.Exception.Message)"
        }
    }
    # Disposes class object
    [void] Dispose() {
        $this.WaitForAsyncSaveToDisk()
        $this.WaitForPendingTransactionLogOperations()
        $this.WaitForAsyncLoadFromDisk()
        if ($this.AsynchronousSaveOperationState.PSEventJob -and $this.AsynchronousSaveOperationState.PSEventJob.Name) {
            Unregister-Event -SourceIdentifier $this.AsynchronousSaveOperationState.PSEventJob.Name -ErrorAction SilentlyContinue
        }
        if ($this.AsynchronousSaveOperationState.PSInstance -is [System.IDisposable]) {
            $this.AsynchronousSaveOperationState.PSInstance.Dispose()
        }
        $this.AsynchronousSaveOperationState.PSInstance = $null
        if ($this.AsynchronousSaveOperationState.PsEventJob -is [System.IDisposable]) {
            $this.AsynchronousSaveOperationState.PsEventJob.Dispose()
        }
        $this.AsynchronousSaveOperationState.PsEventJob = $null
        if ($this.AsynchronousSaveOperationState.Pool -is [System.IDisposable] -and -Not $this.AsynchronousSaveOperationState.Pool.IsDisposed) {
            $this.AsynchronousSaveOperationState.Pool.Close()
            $this.AsynchronousSaveOperationState.Pool.Dispose()
        }
        $this.AsynchronousSaveOperationState.Pool = $null
        if ($this.AsynchronousTransactionLogSaveState.PSEventJob -and $this.AsynchronousTransactionLogSaveState.PSEventJob.Name) {
            Unregister-Event -SourceIdentifier $this.AsynchronousTransactionLogSaveState.PSEventJob.Name -ErrorAction SilentlyContinue
        }
        if ($this.AsynchronousTransactionLogSaveState.PSInstance -is [System.IDisposable]) {
            $this.AsynchronousTransactionLogSaveState.PSInstance.Dispose()
        }
        $this.AsynchronousTransactionLogSaveState.PSInstance = $null
        if ($this.AsynchronousTransactionLogSaveState.PsEventJob -is [System.IDisposable]) {
            $this.AsynchronousTransactionLogSaveState.PsEventJob.Dispose()
        }
        $this.AsynchronousTransactionLogSaveState.PsEventJob = $null
        if ($this.AsynchronousTransactionLogSaveState.Pool -is [System.IDisposable] -and -Not $this.AsynchronousTransactionLogSaveState.Pool.IsDisposed) {
            $this.AsynchronousTransactionLogSaveState.Pool.Close()
            $this.AsynchronousTransactionLogSaveState.Pool.Dispose()
        }
        $this.AsynchronousTransactionLogSaveState.Pool = $null
        if ($this.AsynchronousLoadOperationState.PSEventJob -and $this.AsynchronousLoadOperationState.PSEventJob.Name) {
            Unregister-Event -SourceIdentifier $this.AsynchronousLoadOperationState.PSEventJob.Name -ErrorAction SilentlyContinue
        }
        if ($this.AsynchronousLoadOperationState.PSInstance -is [System.IDisposable]) {
            $this.AsynchronousLoadOperationState.PSInstance.Dispose()
        }
        $this.AsynchronousLoadOperationState.PSInstance = $null
        if ($this.AsynchronousLoadOperationState.PsEventJob -is [System.IDisposable]) {
            $this.AsynchronousLoadOperationState.PsEventJob.Dispose()
        }
        $this.AsynchronousLoadOperationState.PsEventJob = $null
        if ($this.AsynchronousLoadOperationState.Pool -is [System.IDisposable] -and -Not $this.AsynchronousLoadOperationState.Pool.IsDisposed) {
            $this.AsynchronousLoadOperationState.Pool.Close()
            $this.AsynchronousLoadOperationState.Pool.Dispose()
        }
        $this.AsynchronousLoadOperationState.Pool = $null
        if ($null -ne $this.AsyncResults) {
            $null = $this.AsyncResults.Clear()
        }
        if ($null -ne $this.MainHT) { $this.MainHT.Clear(); $this.MainHT = $null }
        if ($null -ne $this.UpdatesHT) { $this.UpdatesHT.Clear(); $this.UpdatesHT = $null }
        if ($null -ne $this.MergedHT) { $this.MergedHT.Clear(); $this.MergedHT = $null }
        if ($null -ne $this.RemovedHT) { $this.RemovedHT.Clear(); $this.RemovedHT = $null }
        if ($null -ne $this.KeyToTick) {
            $this.KeyToTick.Clear()
            $this.KeyToTick = $null
        }
        if ($null -ne $this.TickToKeys) {
            [System.Threading.Monitor]::Enter($this.TickToKeysLock)
            try {
                $this.TickToKeys.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($this.TickToKeysLock)
            }
            $this.TickToKeys = $null
        }
    }
    # Clean up resources
    hidden static [void] CleanupAsync([ref]$obj) {
        if (-not $obj -or -not $obj.Value) { return }
        # PowerShell-instance: stop synchronously with bounded wait, then dispose
        if ($obj.Value.PSInstance) {
            try {
                if (-not $obj.Value.PSInstance.InvocationStateInfo.State -in @([System.Management.Automation.PSInvocationState]::Stopped, [System.Management.Automation.PSInvocationState]::Failed)) {
                    $obj.Value.PSInstance.BeginStop($null, $null)
                    # Bounded wait to let PSInstance actually stop before Dispose
                    $stopWait = [datetime]::Now
                    while ($obj.Value.PSInstance.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Stopping -and ([datetime]::Now - $stopWait).TotalSeconds -lt 3) {
                        [System.Threading.Thread]::Sleep(50)
                    }
                }
            } catch {}
            if ($obj.Value.PSInstance -is [System.IDisposable]) {
                try { $obj.Value.PSInstance.Dispose() } catch {}
            }
        }
        $obj.Value.PSInstance = $null
        # Events
        if ($obj.Value.PSEventJob -and $obj.Value.PSEventJob.Name) {
            try { Unregister-Event -SourceIdentifier $obj.Value.PSEventJob.Name -ErrorAction SilentlyContinue } catch {}
            if ($obj.Value.PSEventJob -is [System.IDisposable]) {
                try { $obj.Value.PSEventJob.Dispose() } catch {}
            }
        }
        $obj.Value.PSEventJob = $null
    }
}