# R8 keep rules for the release build.
#
# Flutter shrinks release builds with R8, and AGP 8 defaults to R8 "full mode",
# which renames classes far more aggressively than the legacy mode. Anything
# looked up REFLECTIVELY BY NAME therefore has to be kept explicitly here —
# the compiler cannot see those references.

# WorkManager (androidx.work, pulled in for the background location worker)
# stores its state in a Room database. Room does not instantiate the database
# class directly: it takes the canonical name, appends "_Impl", and resolves the
# GENERATED implementation with Class.forName. Full-mode R8 renames that
# generated class, so the lookup throws and the app dies during startup inside
# WorkManager's content provider — before any Dart code runs, which is why it
# showed up as "the icon flashes and the app closes" with no visible screen:
#
#   java.lang.RuntimeException: Failed to create an instance of
#     class androidx.work.impl.WorkDatabase.canonicalName
#     at androidx.work.WorkManagerInitializer
#
# Keeping every RoomDatabase subclass (which covers the generated *_Impl, since
# it extends the abstract database class) with its no-arg constructor fixes it.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep @androidx.room.Database class * { *; }
