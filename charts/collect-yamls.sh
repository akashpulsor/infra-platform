#!/usr/bin/env bash

ROOT_DIR=${1:-.}
OUTPUT_FILE=${2:-all-yamls.txt}

# Clear output file
> "$OUTPUT_FILE"

# Find and process yaml/yml files
find "$ROOT_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) | sort | while read -r file; do
  echo "############################################################" >> "$OUTPUT_FILE"
  echo "# FILE: $file" >> "$OUTPUT_FILE"
  echo "############################################################" >> "$OUTPUT_FILE"
  echo >> "$OUTPUT_FILE"
  cat "$file" >> "$OUTPUT_FILE"
  echo -e "\n\n" >> "$OUTPUT_FILE"
done

echo "✅ All YAML files written to $OUTPUT_FILE"

