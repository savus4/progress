# Simulator example photos

Put exported `photo_<date>_<time>_<UUID>` folders inside `Photos/` here.
This directory is outside the app target, and `Photos/` is ignored by Git.

The build phase copies the photos into **Debug + iOS Simulator** builds only.
Device and Release builds contain neither these assets nor the example-library code.
With fixtures present, the simulator uses a separate local Core Data store and
disables iCloud operations. Missing examples return on the next launch; edits to
existing examples are preserved. UI tests and unit tests do not enable this mode.

To replace the local fixture set:

```sh
mkdir -p SimulatorFixtures/Photos
cp -R /path/to/exported/Pics/. SimulatorFixtures/Photos/
```

Set the Run environment variable `SIMULATOR_EXAMPLE_PHOTOS=0` to use the normal
library and iCloud behavior. This leaves the example library stored separately.

These fixtures populate Work in Progress directly, not the system Photos library.
