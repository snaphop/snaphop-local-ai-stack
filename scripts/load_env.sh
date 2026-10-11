#!/usr/bin/env bash
# Load KEY=VALUE lines literally.
# A password must not be evaluated as shell, and an already-set variable wins
# so the operator environment matches Compose precedence.

load_env_file() {
    local file="$1"
    local line key value first last
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|\#*) continue ;;
        esac
        case "$line" in
            'export '*) line="${line#export }" ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in
            [A-Za-z_][A-Za-z0-9_]*) ;;
            *) continue ;;
        esac
        if [ "${#value}" -ge 2 ]; then
            first="${value:0:1}"
            last="${value: -1}"
            if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
                value="${value:1:${#value}-2}"
            fi
        fi
        if [ -n "${!key+x}" ]; then
            continue
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$file"
}
