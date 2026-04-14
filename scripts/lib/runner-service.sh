#!/usr/bin/env bash

set -euo pipefail

runner_staging_drop_in_dir() {
  echo "/etc/systemd/system/actions-runner.service.d"
}

runner_detect_service_name() {
  if [ -n "${RUNNER_SERVICE_NAME:-}" ]; then
    echo "${RUNNER_SERVICE_NAME%.service}"
    return 0
  fi

  if [ -e "/etc/systemd/system/actions-runner.service" ]; then
    echo "actions-runner"
    return 0
  fi

  local unit
  unit=$(
    find /etc/systemd/system -maxdepth 1 \( -type f -o -type l \) \
      -name 'actions.runner.*.service' -print 2>/dev/null \
      | sort \
      | head -1
  )

  if [ -n "$unit" ]; then
    basename "$unit" .service
    return 0
  fi

  echo "actions-runner"
}

runner_detect_service_unit() {
  echo "$(runner_detect_service_name).service"
}

runner_detect_drop_in_dir() {
  echo "/etc/systemd/system/$(runner_detect_service_unit).d"
}

runner_write_drop_in() {
  local filename="$1"
  local content="$2"
  local primary_dir staging_dir target

  primary_dir="$(runner_detect_drop_in_dir)"
  staging_dir="$(runner_staging_drop_in_dir)"

  mkdir -p "$primary_dir"
  target="${primary_dir}/${filename}"

  if [ ! -f "$target" ] || [ "$(cat "$target")" != "$content" ]; then
    printf '%s\n' "$content" > "$target"
  fi

  if [ "$staging_dir" != "$primary_dir" ]; then
    mkdir -p "$staging_dir"
    target="${staging_dir}/${filename}"
    if [ ! -f "$target" ] || [ "$(cat "$target")" != "$content" ]; then
      printf '%s\n' "$content" > "$target"
    fi
  fi
}

runner_sync_staged_drop_ins() {
  local service_name="$1"
  local staging_dir actual_dir file

  staging_dir="$(runner_staging_drop_in_dir)"
  actual_dir="/etc/systemd/system/${service_name}.service.d"

  [ -d "$staging_dir" ] || return 0
  mkdir -p "$actual_dir"

  shopt -s nullglob
  for file in "$staging_dir"/*.conf; do
    cp "$file" "${actual_dir}/$(basename "$file")"
  done
  shopt -u nullglob
}

runner_ensure_service_alias() {
  local service_name="$1"
  local alias_path target_path

  [ "$service_name" = "actions-runner" ] && return 0

  alias_path="/etc/systemd/system/actions-runner.service"
  target_path="/etc/systemd/system/${service_name}.service"

  if [ ! -e "$target_path" ]; then
    return 0
  fi

  if [ -L "$alias_path" ]; then
    local current_target
    current_target="$(readlink "$alias_path")"
    [ "$current_target" = "$target_path" ] && return 0
    rm -f "$alias_path"
  elif [ -e "$alias_path" ]; then
    return 0
  fi

  ln -s "$target_path" "$alias_path"
}
