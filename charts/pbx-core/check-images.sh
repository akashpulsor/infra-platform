#!/bin/bash

FILE="values.yaml"

echo "Extracting images from $FILE"
echo "--------------------------------------------------------"

# Extract repositories (remove quotes)
REPOS=($(grep -R "repository:" $FILE | awk '{print $2}' | tr -d '"' ))

# Extract tags (remove quotes)
TAGS=($(grep -R "tag:" $FILE | awk '{print $2}' | tr -d '"' ))

IMAGES=()

# Assemble image:tag pairs
for i in "${!REPOS[@]}"; do
    IMG="${REPOS[$i]}:${TAGS[$i]}"
    IMAGES+=("$IMG")
done

echo "Images detected:"
printf '%s\n' "${IMAGES[@]}"
echo "--------------------------------------------------------"

# Validate each image via docker pull
for IMG in "${IMAGES[@]}"; do
    echo "Checking → $IMG"

    if docker pull "$IMG" >/dev/null 2>&1; then
        echo "✔ EXISTS"
    else
        echo "❌ NOT FOUND"
    fi

    echo "--------------------------------------------------------"
done

