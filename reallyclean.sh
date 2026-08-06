#!/usr/bin/env bash
#
# reallyclean.sh — aggressive cleanup for .NET / .NET MAUI repositories
#
# Usage:
#   ./reallyclean.sh                 # default: dotnet clean + remove project bin/obj
#   ./reallyclean.sh rider           # Rider caches + deep cleanup
#   ./reallyclean.sh vscode          # VS Code / Visual Studio caches + deep cleanup
#   ./reallyclean.sh vstudio         # alias for vscode
#   ./reallyclean.sh deep            # user-level .NET/NuGet/temp cleanup
#
# Options:
#   -n, --dry-run   print actions without changing anything
#   -y, --yes       skip the destructive-action confirmation
#   -h, --help      show help
#
# Notes:
# - Run from the repository root.
# - Close Rider, Visual Studio, VS Code, dotnet watch, emulators, and build tools first.
# - "deep" removes disposable user-level state, caches, restored NuGet packages,
#   workload leftovers, and project-generated output. It does NOT uninstall SDKs,
#   runtimes, workloads, IDEs, signing identities, Android SDKs, Xcode, or Java.
# - A literal factory-fresh .NET installation requires uninstalling/reinstalling
#   those products and is intentionally outside this script.
#
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
START_DIR="$(pwd -P)"
MODE="default"
DRY_RUN=0
ASSUME_YES=0

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quote_cmd() {
  printf '%q ' "$@"
  printf '\n'
}

run() {
  if (( DRY_RUN )); then
    printf '[dry-run] '
    quote_cmd "$@"
  else
    "$@"
  fi
}

remove_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "Refusing to remove an empty path."
  [[ "$path" != "/" ]] || die "Refusing to remove /."
  [[ "$path" != "$HOME" ]] || die "Refusing to remove HOME."
  [[ "$path" != "$START_DIR" ]] || die "Refusing to remove repository root."
  [[ "$path" != "." && "$path" != ".." ]] || die "Refusing unsafe path: $path"

  if [[ -e "$path" || -L "$path" ]]; then
    if (( DRY_RUN )); then
      printf '[dry-run] rm -rf -- %q\n' "$path"
    else
      rm -rf -- "$path"
    fi
  fi
}

remove_glob() {
  local pattern="$1"
  local item
  shopt -s nullglob
  # Intentionally allow shell expansion here.
  for item in $pattern; do
    remove_path "$item"
  done
  shopt -u nullglob
}

have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) OS="unknown" ;;
  esac
}

parse_args() {
  local positional=()
  while (($#)); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      default|rider|vscode|vstudio|deep) positional+=("$1") ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
    shift
  done

  ((${#positional[@]} <= 1)) || die "Choose only one cleanup mode."
  if ((${#positional[@]} == 1)); then
    MODE="${positional[0]}"
  fi
  [[ "$MODE" != "vstudio" ]] || MODE="vscode"
}

validate_repository_root() {
  [[ "$START_DIR" != "/" ]] || die "Do not run this script from /."
  [[ "$START_DIR" != "$HOME" ]] || die "Do not run this script from your home directory."

  local marker_found=0
  shopt -s nullglob globstar
  local markers=(
    "$START_DIR"/*.sln
    "$START_DIR"/*.slnx
    "$START_DIR"/*.csproj
    "$START_DIR"/**/*.sln
    "$START_DIR"/**/*.slnx
    "$START_DIR"/**/*.csproj
    "$START_DIR"/global.json
    "$START_DIR"/Directory.Build.props
  )
  shopt -u globstar nullglob

  ((${#markers[@]} > 0)) && marker_found=1
  (( marker_found )) || die "No .NET solution/project marker found below: $START_DIR"
}

confirm_destructive() {
  [[ "$MODE" == "default" ]] && return
  (( DRY_RUN || ASSUME_YES )) && return

  printf '\nMode "%s" removes user-level caches outside this repository.\n' "$MODE"
  printf 'Close IDEs and build processes before continuing.\n'
  printf 'Type CLEAN to continue: '
  local answer
  read -r answer
  [[ "$answer" == "CLEAN" ]] || die "Cancelled."
}

stop_build_servers() {
  have dotnet || return 0
  log "Stopping .NET/MSBuild build servers"
  run dotnet build-server shutdown || true
}

dotnet_clean() {
  if ! have dotnet; then
    warn "dotnet was not found; skipping dotnet clean."
    return
  fi

  log "Running dotnet clean"
  if compgen -G "$START_DIR/*.slnx" >/dev/null; then
    local f
    for f in "$START_DIR"/*.slnx; do run dotnet clean "$f" --nologo || true; done
  elif compgen -G "$START_DIR/*.sln" >/dev/null; then
    local f
    for f in "$START_DIR"/*.sln; do run dotnet clean "$f" --nologo || true; done
  elif compgen -G "$START_DIR/*.csproj" >/dev/null; then
    local f
    for f in "$START_DIR"/*.csproj; do run dotnet clean "$f" --nologo || true; done
  else
    # Let dotnet discover a project when the root only contains nested projects.
    run dotnet clean --nologo || true
  fi
}

clean_project_outputs() {
  log "Removing generated project output"
  local dir
  while IFS= read -r -d '' dir; do
    remove_path "$dir"
  done < <(
    find "$START_DIR" -depth -type d \
      \( -name bin -o -name obj -o -name TestResults -o -name AppPackages \
         -o -name Publish -o -name publish -o -name artifacts \) \
      -not -path '*/.git/*' -print0
  )

  # Common repository-local caches and generated MAUI artifacts.
  local local_paths=(
    "$START_DIR/.vs"
    "$START_DIR/.vscode/.ropeproject"
    "$START_DIR/.vscode/.react"
    "$START_DIR/.idea/.idea."*
    "$START_DIR/.ionide"
    "$START_DIR/.fake"
    "$START_DIR/.paket"
    "$START_DIR/.dotnet"
    "$START_DIR/.nuget"
    "$START_DIR/.local"
    "$START_DIR/.cache"
    "$START_DIR/.sass-cache"
    "$START_DIR/.maui"
    "$START_DIR/.xamarin"
    "$START_DIR/.mono"
    "$START_DIR/.DS_Store"
  )
  local p
  for p in "${local_paths[@]}"; do
    [[ "$p" == "$START_DIR/.vscode" ]] && continue
    remove_glob "$p"
  done

  # Preserve VS Code settings/tasks/extensions recommendations; remove only known generated state.
  remove_path "$START_DIR/.vscode/.browse.VC.db"
  remove_path "$START_DIR/.vscode/ipch"
  remove_path "$START_DIR/.vscode/.csharp"
}

clean_nuget_and_dotnet_user_state() {
  log "Clearing NuGet caches and restored packages"
  if have dotnet; then
    run dotnet nuget locals all --clear || true
  elif have nuget; then
    run nuget locals all -clear || true
  else
    warn "Neither dotnet nor nuget was found; clearing conventional paths only."
  fi

  # Conventional NuGet paths, including custom HOME-level state.
  remove_path "$HOME/.nuget/packages"
  remove_path "$HOME/.local/share/NuGet/v3-cache"
  remove_path "$HOME/.local/share/NuGet/plugins-cache"
  remove_path "$HOME/.cache/NuGet"
  remove_path "$HOME/.cache/NuGetScratch"
  remove_path "$HOME/Library/Caches/NuGet"
  remove_path "$HOME/Library/Caches/NuGetScratch"

  log "Clearing disposable .NET CLI state"
  local dotnet_paths=(
    "$HOME/.dotnet/.store"
    "$HOME/.dotnet/store"
    "$HOME/.dotnet/toolResolverCache"
    "$HOME/.dotnet/sdk-advertising"
    "$HOME/.dotnet/workloads"
    "$HOME/.dotnet/.workloadAdvertisingManifestSentinel"*
    "$HOME/.dotnet/.workloadSetUpdateSentinel"*
    "$HOME/.dotnet/.firstUseSentinel"
    "$HOME/.dotnet/.telemetry"
    "$HOME/.local/share/dotnet/sdk-advertising"
    "$HOME/.local/share/dotnet/workloads"
    "$HOME/Library/Application Support/dotnet/sdk-advertising"
    "$HOME/Library/Application Support/dotnet/workloads"
  )
  local p
  for p in "${dotnet_paths[@]}"; do remove_glob "$p"; done

  if have dotnet && dotnet workload clean --help >/dev/null 2>&1; then
    log "Removing orphaned workload components"
    run dotnet workload clean || true
  fi
}

clean_dotnet_temp() {
  log "Removing known .NET, NuGet, MSBuild, Roslyn, Xamarin, and MAUI temporary files"

  local roots=()
  [[ -n "${TMPDIR:-}" ]] && roots+=("${TMPDIR%/}")
  [[ -n "${TEMP:-}" ]] && roots+=("${TEMP%/}")
  [[ -n "${TMP:-}" ]] && roots+=("${TMP%/}")
  roots+=("/tmp")

  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    [[ "$root" != "/" && "$root" != "$HOME" ]] || continue

    # Delete only known disposable names, owned by the current user when supported.
    local find_owner=()
    if find "$root" -maxdepth 0 -user "$(id -u)" >/dev/null 2>&1; then
      find_owner=(-user "$(id -u)")
    fi

    local item
    while IFS= read -r -d '' item; do
      remove_path "$item"
    done < <(
      find "$root" -maxdepth 2 "${find_owner[@]}" \
        \( -iname 'NuGetScratch*' \
        -o -iname 'MSBuildTemp*' \
        -o -iname 'VBCSCompiler*' \
        -o -iname 'Roslyn*' \
        -o -iname '.NETCoreApp*' \
        -o -iname 'dotnet-*' \
        -o -iname 'clr-debug-pipe-*' \
        -o -iname 'CoreFxPipe_*' \
        -o -iname 'xamarin-*' \
        -o -iname 'maui-*' \
        -o -iname 'MonoDevelop-*' \
        -o -iname 'servicehub-*' \) \
        -print0 2>/dev/null
    )
  done
}

clean_maui_platform_build_state() {
  log "Removing user-level MAUI/Xamarin build caches"
  local paths=(
    "$HOME/.local/share/Xamarin"
    "$HOME/.cache/Xamarin"
    "$HOME/Library/Caches/Xamarin"
    "$HOME/Library/Caches/com.xamarin."*
    "$HOME/Library/Developer/Xamarin"
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Caches/com.apple.dt.Xcode"
    "$HOME/AppData/Local/Xamarin"
    "$HOME/AppData/Local/Temp/Xamarin"
  )
  local p
  for p in "${paths[@]}"; do remove_glob "$p"; done
}

clean_rider() {
  log "Removing Rider caches (all installed versions)"
  warn "This includes Rider indexes and Local History stored in cache/system directories."

  case "$OS" in
    macos)
      remove_glob "$HOME/Library/Caches/JetBrains/Rider*"
      remove_glob "$HOME/Library/Logs/JetBrains/Rider*"
      remove_glob "$HOME/Library/Application Support/JetBrains/Rider*/caches"
      remove_glob "$HOME/Library/Application Support/JetBrains/Rider*/index"
      remove_glob "$HOME/Library/Application Support/JetBrains/Rider*/resharper-host"
      ;;
    linux)
      remove_glob "$HOME/.cache/JetBrains/Rider*"
      remove_glob "$HOME/.local/share/JetBrains/Rider*/caches"
      remove_glob "$HOME/.local/share/JetBrains/Rider*/index"
      remove_glob "$HOME/.local/share/JetBrains/Rider*/resharper-host"
      ;;
    windows)
      remove_glob "$LOCALAPPDATA/JetBrains/Rider*/caches"
      remove_glob "$LOCALAPPDATA/JetBrains/Rider*/index"
      remove_glob "$LOCALAPPDATA/JetBrains/Rider*/log"
      remove_glob "$LOCALAPPDATA/JetBrains/Rider*/resharper-host"
      ;;
  esac

  remove_glob "$START_DIR/.idea"
}

clean_visual_studio_and_code() {
  log "Removing Visual Studio and VS Code caches"
  warn "This removes IDE caches, indexes, logs, and workspace storage—not settings or extensions."

  remove_path "$START_DIR/.vs"
  remove_path "$START_DIR/.vscode/.browse.VC.db"
  remove_path "$START_DIR/.vscode/ipch"
  remove_path "$START_DIR/.vscode/.csharp"

  case "$OS" in
    macos)
      # Visual Studio for Mac / MonoDevelop caches.
      remove_glob "$HOME/Library/Caches/VisualStudio"
      remove_glob "$HOME/Library/Caches/VisualStudio/"*
      remove_glob "$HOME/Library/Caches/MonoDevelop-"*
      remove_glob "$HOME/Library/Logs/VisualStudio"
      remove_glob "$HOME/Library/Application Support/VisualStudio/"*/Cache
      # VS Code disposable caches and workspace state.
      remove_path "$HOME/Library/Application Support/Code/Cache"
      remove_path "$HOME/Library/Application Support/Code/CachedData"
      remove_path "$HOME/Library/Application Support/Code/CachedExtensions"
      remove_path "$HOME/Library/Application Support/Code/CachedExtensionVSIXs"
      remove_path "$HOME/Library/Application Support/Code/Code Cache"
      remove_path "$HOME/Library/Application Support/Code/GPUCache"
      remove_path "$HOME/Library/Application Support/Code/logs"
      remove_path "$HOME/Library/Application Support/Code/User/workspaceStorage"
      ;;
    linux)
      remove_path "$HOME/.config/Code/Cache"
      remove_path "$HOME/.config/Code/CachedData"
      remove_path "$HOME/.config/Code/CachedExtensions"
      remove_path "$HOME/.config/Code/CachedExtensionVSIXs"
      remove_path "$HOME/.config/Code/Code Cache"
      remove_path "$HOME/.config/Code/GPUCache"
      remove_path "$HOME/.config/Code/logs"
      remove_path "$HOME/.config/Code/User/workspaceStorage"
      remove_path "$HOME/.cache/Code"
      ;;
    windows)
      # Git Bash/MSYS usually exposes LOCALAPPDATA and APPDATA as POSIX paths.
      [[ -n "${LOCALAPPDATA:-}" ]] && {
        remove_glob "$LOCALAPPDATA/Microsoft/VisualStudio/"*/ComponentModelCache
        remove_glob "$LOCALAPPDATA/Microsoft/VisualStudio/"*/ImageLibrary
        remove_glob "$LOCALAPPDATA/Microsoft/VisualStudio/"*/Cache
        remove_glob "$LOCALAPPDATA/Microsoft/VSCommon/"*/MEFCacheBackup
        remove_glob "$LOCALAPPDATA/Temp/VSFeedbackIntelliCodeLogs"
        remove_glob "$LOCALAPPDATA/Temp/servicehub"
      }
      [[ -n "${APPDATA:-}" ]] && {
        remove_path "$APPDATA/Code/Cache"
        remove_path "$APPDATA/Code/CachedData"
        remove_path "$APPDATA/Code/CachedExtensions"
        remove_path "$APPDATA/Code/CachedExtensionVSIXs"
        remove_path "$APPDATA/Code/Code Cache"
        remove_path "$APPDATA/Code/GPUCache"
        remove_path "$APPDATA/Code/logs"
        remove_path "$APPDATA/Code/User/workspaceStorage"
      }
      ;;
  esac
}

deep_clean() {
  stop_build_servers
  dotnet_clean
  clean_project_outputs
  clean_nuget_and_dotnet_user_state
  clean_dotnet_temp
  clean_maui_platform_build_state
}

main() {
  parse_args "$@"
  detect_os
  validate_repository_root
  confirm_destructive

  log "Repository: $START_DIR"
  log "Mode: $MODE"
  (( DRY_RUN )) && log "Dry run enabled"

  case "$MODE" in
    default)
      stop_build_servers
      dotnet_clean
      clean_project_outputs
      ;;
    deep)
      deep_clean
      ;;
    rider)
      clean_rider
      deep_clean
      ;;
    vscode)
      clean_visual_studio_and_code
      deep_clean
      ;;
    *)
      die "Internal error: unsupported mode '$MODE'"
      ;;
  esac

  log "Cleanup complete"
  if [[ "$MODE" != "default" ]]; then
    printf '\nNext build will restore packages, regenerate indexes, and may re-download workload data.\n'
    printf 'Suggested verification: dotnet --info && dotnet workload list && dotnet restore\n'
  fi
}

main "$@"
