# Local configuration storage

`DockStore` owns atomic JSON writes and serial disk access. `DockArchive` owns version recognition, migration, and field-level recovery. Both can run without AppKit.

The current format is version 4. It stores ordered dock configurations, stable IDs, enabled state, app entries/bookmarks, appearance, positioning, and per-dock behavior/manual collapse. Version 1 gains enabled state defaulting to true; version 1 and version 2 gain default-off advanced interactions. Versions 1 to 3 gain default-off window previews. Preview images, permission grants, and window descriptors are never saved. Automatic hiding, pointer state, running-process state, feedback, and animations are never serialized. Unknown future versions are refused.

Production startup uses `loadRecovering()`. Healthy records survive damaged neighbors; malformed fields are repaired separately, invalid app entries are skipped, repeated dock IDs are restored once, and repeated entry IDs get fresh identities. Original bytes are backed up before a migrated or repaired configuration can be saved. Settings reports the changes and backup path. Syntactically broken or unrecoverable files stay untouched and put that session into a read-only storage mode. `load()` remains a strict decoder for validation and tests.

The manager coalesces changed snapshots for 350 ms. The store checks revisions and normalized equality to prevent stale overwrites and unnecessary disk writes. Normal Quit flushes the latest state. Missing storage differs from an intentionally empty dock collection. Launch at Login belongs to ServiceManagement, and temporary hiding belongs to the current session; neither is copied into this file.

Tests use isolated temporary directories. The shared Xcode test scheme disables production persistence.
