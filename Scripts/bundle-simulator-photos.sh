#!/bin/sh
set -eu

destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/SimulatorExamplePhotos"

# Remove stale fixtures if a build changes platform/configuration or fixtures disappear.
rm -rf "$destination"
if [ "$CONFIGURATION" = "Debug" ] && [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
    source="${SRCROOT}/SimulatorFixtures/Photos"
    if [ -d "$source" ]; then
        mkdir -p "$destination"
        # Copy media only; the exported folder names preserve the capture dates.
        find "$source" -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.mov' \) -exec sh -eu -c '
            source="$1"
            destination="$2"
            shift 2
            for photo do
                relative="${photo#"$source"/}"
                mkdir -p "$destination/$(dirname "$relative")"
                cp "$photo" "$destination/$relative"
            done
        ' sh "$source" "$destination" {} +
    fi
fi
