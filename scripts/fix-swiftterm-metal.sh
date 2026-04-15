#!/bin/bash
# Workaround for tuist/tuist#9111: Tuist adds .metal files as both Sources and Resources,
# causing "Unexpected duplicate tasks" build errors.
# This removes the duplicate "Shaders.metal in Sources" entry, keeping only Resources.

# Search known locations. Tuist may place the generated project under
# Tuist/.build/tuist-derived (classic) or .build/tuist-derived (cache build),
# and the cached binaries path varies across Tuist versions.
CANDIDATES=$(find . ~/.tuist ~/Library/Caches/tuist 2>/dev/null \
  -type f -name 'project.pbxproj' -path '*/SwiftTerm.xcodeproj/*' 2>/dev/null)

if [ -z "$CANDIDATES" ]; then
  echo "SwiftTerm project not found in any known location, skipping"
  exit 0
fi

fixed=0
for PBXPROJ in $CANDIDATES; do
  if grep -q "Shaders.metal in Sources" "$PBXPROJ"; then
    sed -i.bak '/Shaders\.metal in Sources/d' "$PBXPROJ"
    rm -f "${PBXPROJ}.bak"
    echo "Fixed: removed duplicate Shaders.metal from Sources in $PBXPROJ"
    fixed=$((fixed + 1))
  fi
done

if [ "$fixed" -eq 0 ]; then
  echo "No duplicate Metal entry found in any SwiftTerm project, skipping"
fi
