#!/usr/bin/env bash

OUTPUT_FILE="helm-templates-dump.txt"

# clean old output
> "$OUTPUT_FILE"

echo "Helm chart dump generated on $(date)" >> "$OUTPUT_FILE"
echo "Root directory: $(pwd)" >> "$OUTPUT_FILE"
echo "==================================================" >> "$OUTPUT_FILE"
echo >> "$OUTPUT_FILE"

# find all relevant files
find . \
  \( -name "*.yaml" -o -name "*.yml" -o -name "*.tpl" \) \
  -type f | sort | while read -r file; do

  echo "=====================$file=========================" >> "$OUTPUT_FILE"
  echo "FILE: $file" >> "$OUTPUT_FILE"
  echo "==================================================" >> "$OUTPUT_FILE"
  echo >> "$OUTPUT_FILE"

  cat "$file" >> "$OUTPUT_FILE"

  echo >> "$OUTPUT_FILE"
  echo >> "$OUTPUT_FILE"
done

echo "Done. Output written to $OUTPUT_FILE"

