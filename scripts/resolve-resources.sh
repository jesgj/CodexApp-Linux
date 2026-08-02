# shellcheck shell=bash

resolve_resources_dir() {
  local root_dir="$1"
  local configured_dir="${CODEX_RESOURCES_DIR:-}"
  local preferred_dir="$root_dir/build/app/ChatGPT Installer/ChatGPT.app/Contents/Resources"
  local app_root="$root_dir/build/app"
  local asar_path
  local -a candidates=()

  if [[ -n "$configured_dir" ]]; then
    if [[ ! -f "$configured_dir/app.asar" ]]; then
      printf 'CODEX_RESOURCES_DIR must contain app.asar: %s\n' "$configured_dir" >&2
      return 1
    fi
    realpath -e "$configured_dir"
    return
  fi

  if [[ -f "$preferred_dir/app.asar" ]]; then
    printf '%s\n' "$preferred_dir"
    return
  fi

  if [[ ! -d "$app_root" ]]; then
    printf 'App extraction directory not found: %s\n' "$app_root" >&2
    return 1
  fi

  while IFS= read -r -d '' asar_path; do
    candidates+=("$(dirname "$asar_path")")
  done < <(find "$app_root" -type f -path '*/Contents/Resources/app.asar' -print0 | sort -z)

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    return
  fi

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    printf 'No extracted app resources were found under %s\n' "$app_root" >&2
  else
    printf 'Multiple extracted app resources were found. Set CODEX_RESOURCES_DIR explicitly:\n' >&2
    printf '  %s\n' "${candidates[@]}" >&2
  fi
  return 1
}
