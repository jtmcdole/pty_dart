find . -name "*.dart" -or -name "*.md" | xargs sed -i 's/[[:space:]]*$//'
