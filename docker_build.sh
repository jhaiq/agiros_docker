#!/bin/bash
# Unified multi-module Docker build script
# Supports building all Dockerfiles in agiros/ and app/ directories
# with multi-architecture support (amd64, arm64, riscv64).
#
# Usage:
#   ./docker_build.sh                                          # Build all modules (default stage)
#   ./docker_build.sh --list                                   # List available modules + stages
#   ./docker_build.sh --module agiros-ubuntu                   # Build specific module
#   ./docker_build.sh --module app-ubuntu --stage unitree      # Build specific module + stage
#   ./docker_build.sh --stage base                             # Build base stage across all modules
#   ./docker_build.sh --module agiros-ubuntu --platform linux/amd64 --push   # Push to registry

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# =============================================================================
# Colors
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
info()  { echo -e "${CYAN}[.]${NC} $*"; }

# =============================================================================
# Module definitions
# =============================================================================
# Each module maps to a Dockerfile + available stages + default stage

declare -A MODULES
MODULES["agiros-ubuntu"]="agiros/ubuntu/loong/Dockerfile.agiros-multistage"
MODULES["agiros-openeuler"]="agiros/openeuler/loong/Dockerfile.agiros-multistage"
MODULES["app-ubuntu"]="app/ubuntu/Dockerfile.app.all"
MODULES["app-openeuler"]="app/openeuler/Dockerfile.app.all"

declare -A MODULE_STAGES
MODULE_STAGES["agiros-ubuntu"]="base,dev,desktop,desktop-full"
MODULE_STAGES["agiros-openeuler"]="base,dev,desktop,desktop-full"
MODULE_STAGES["app-ubuntu"]="unitree,ur5,wheeltec"
MODULE_STAGES["app-openeuler"]="unitree,ur5,wheeltec"

declare -A MODULE_DEFAULT_STAGE
MODULE_DEFAULT_STAGE["agiros-ubuntu"]="desktop-full"
MODULE_DEFAULT_STAGE["agiros-openeuler"]="desktop-full"
MODULE_DEFAULT_STAGE["app-ubuntu"]="unitree"
MODULE_DEFAULT_STAGE["app-openeuler"]="unitree"

# =============================================================================
# Default values
# =============================================================================
PUSH=false
RETRY=true
PLATFORMS="linux/amd64,linux/arm64"
IMAGE_TAG="2606"
BUILD_ALL_MODULES=false
SELECTED_MODULE=""
SELECTED_STAGES=""
BUILD_ARGS=()

# =============================================================================
# CLI parsing
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --module|-m)
            SELECTED_MODULE="$2"
            shift 2
            ;;
        --stage|-s)
            SELECTED_STAGES="$2"
            shift 2
            ;;
        --platform|-p)
            PLATFORMS="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-retry)
            RETRY=false
            shift
            ;;
        --tag|-t)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --build-arg)
            # Pass-through: stored as-is for docker buildx --build-arg
            BUILD_ARGS+=("--build-arg" "$2")
            shift 2
            ;;
        --all-modules|-a)
            BUILD_ALL_MODULES=true
            shift
            ;;
        --list|-l)
            echo "Available modules:"
            for module in "${!MODULES[@]}"; do
                echo "  $module"
                echo "    Dockerfile: ${MODULES[$module]}"
                echo "    Stages:     ${MODULE_STAGES[$module]}"
                echo "    Default:    ${MODULE_DEFAULT_STAGE[$module]}"
            done
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --module, -m NAME      Build specific module (see --list)"
            echo "  --stage, -s STAGE      Build specific stage (default: module default)"
            echo "                         Multiple stages: --stage unitree,ur5,wheeltec"
            echo "  --platform, -p PLAT    Build platforms (default: linux/amd64,linux/arm64)"
            echo "  --push                 Push image to registry after build"
            echo "  --no-retry             Disable retry on network errors"
            echo "  --tag, -t TAG          Set image tag (default: 2606)"
            echo "  --build-arg KV         Pass build arg to Docker (repeatable)"
            echo "  --all-modules, -a      Build all modules"
            echo "  --list, -l             List available modules"
            echo "  --help, -h             Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                                            # Build all modules (default stage)"
            echo "  $0 --module agiros-ubuntu                     # Build specific module"
            echo "  $0 --module app-ubuntu --stage unitree         # Build specific stage"
            echo "  $0 --stage base                               # Build 'base' across all modules"
            echo "  $0 --module agiros-ubuntu --platform linux/amd64  # Single-arch local build"
            echo "  $0 --module agiros-ubuntu --push              # Build and push"
            echo "  $0 --module app-ubuntu --build-arg PARALLEL_JOBS=8  # With build args"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            err "Use --help for usage"
            exit 1
            ;;
    esac
done

# If no module specified and not --all-modules explicitly, build all
if [ -z "$SELECTED_MODULE" ] && [ "$BUILD_ALL_MODULES" = false ]; then
    BUILD_ALL_MODULES=true
fi

# Validate selected module if specified
if [ -n "$SELECTED_MODULE" ]; then
    if [ -z "${MODULES[$SELECTED_MODULE]:-}" ]; then
        err "Unknown module: $SELECTED_MODULE"
        err "Use --list to see available modules"
        exit 1
    fi
fi

# =============================================================================
# Infrastructure setup
# =============================================================================

# Step 1: Initialize git submodules
log "Step 1: Initializing git submodules..."
if [ -f .gitmodules ]; then
    if git submodule status 2>/dev/null | grep -q "^\-"; then
        info "Initializing submodules..."
        git submodule update --init --recursive
        log "Submodules initialized"
    else
        log "Submodules already initialized"
    fi
else
    info "No .gitmodules found, skipping submodule init"
fi

# Step 2: Setup binfmt for cross-arch builds
setup_binfmt() {
    local host_arch
    host_arch="$(uname -m)"
    local host_platform=""
    case "$host_arch" in
        x86_64)  host_platform="linux/amd64" ;;
        aarch64|arm64) host_platform="linux/arm64" ;;
        armv7l)  host_platform="linux/arm/v7" ;;
        armv6l)  host_platform="linux/arm/v6" ;;
        riscv64) host_platform="linux/riscv64" ;;
    esac
    [ -n "$host_platform" ] || warn "Unknown host arch (${host_arch})"

    local need_binfmt=false
    local install_archs=()

    IFS=',' read -ra platform_items <<< "$PLATFORMS"
    for raw_platform in "${platform_items[@]}"; do
        local platform arch
        platform="$(echo "$raw_platform" | xargs)"
        arch="${platform#linux/}"
        arch="${arch%%/*}"
        [ -z "$arch" ] && continue

        # Skip if matches host arch (native builds don't need binfmt)
        if [ -n "$host_platform" ]; then
            local host_arch2="${host_platform#linux/}"
            host_arch2="${host_arch2%%/*}"
            [ "$arch" = "$host_arch2" ] && continue
        fi

        need_binfmt=true
        [[ " ${install_archs[*]} " != *" ${arch} "* ]] && install_archs+=("$arch")
    done

    if [ "$need_binfmt" = true ]; then
        local install_arg
        install_arg="$(IFS=,; echo "${install_archs[*]}")"
        log "Installing binfmt handlers for: ${install_arg}"
        if ! docker run --privileged --rm tonistiigi/binfmt --install "${install_arg}"; then
            warn "binfmt install failed — cross-arch builds may fail under emulation."
        else
            log "binfmt handlers installed"
        fi
    else
        log "Host platform matches target; binfmt not required"
    fi
}

log "Step 2: Setting up binfmt for cross-arch builds..."
setup_binfmt

# Step 3: Ensure buildx builder exists
setup_buildx() {
    if [ "$PUSH" = true ]; then
        # For multi-arch push, use docker-container driver with network=host
        local builder_name="agiros-multiarch"

        # Check if builder exists and remove it to ensure fresh config
        if docker buildx ls 2>/dev/null | grep -q "${builder_name}"; then
            log "Removing existing buildx builder '${builder_name}' to refresh config..."
            docker buildx rm "${builder_name}" >/dev/null 2>&1 || true
        fi

        # Create buildkit config for insecure registry if needed
        local buildkit_config=""
        if [ ! -f /etc/docker/buildx.toml ]; then
            log "Creating buildkit config for insecure registries..."
            sudo mkdir -p /etc/docker
            sudo tee /etc/docker/buildx.toml > /dev/null << 'EOF'
[registry."docker.agiros.org.cn"]
  http = true
  insecure = true
EOF
        fi
        buildkit_config="--config /etc/docker/buildx.toml"

        log "Creating buildx builder '${builder_name}' (docker-container, network=host)"
        # shellcheck disable=SC2086
        docker buildx create \
            --name "${builder_name}" \
            --driver docker-container \
            --driver-opt network=host \
            ${buildkit_config} \
            --use || {
            err "Failed to create buildx builder"
            exit 1
        }

        docker buildx inspect --bootstrap "${builder_name}" >/dev/null 2>&1 || {
            err "Failed to bootstrap buildx builder"
            exit 1
        }
        log "Buildx builder ready"
    else
        # Local build: use default docker driver
        docker buildx use default 2>/dev/null || true
        log "Using default docker builder (local build)"
    fi
}

log "Step 3: Setting up Docker Buildx..."
setup_buildx

# =============================================================================
# Build function
# =============================================================================
build_single() {
    local module="$1"
    local stage="$2"
    local dockerfile="${MODULES[$module]}"
    local module_stages="${MODULE_STAGES[$module]}"
    local default_stage="${MODULE_DEFAULT_STAGE[$module]}"

    # Validate stage
    if ! echo "$module_stages" | tr ',' '\n' | grep -qx "$stage"; then
        err "Invalid stage '$stage' for module '$module'. Valid: ${module_stages}"
        return 1
    fi

    # Auto-injected build args
    local auto_args=(
        --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    )
    if git rev-parse --short HEAD &>/dev/null; then
        auto_args+=(--build-arg "GIT_COMMIT=$(git rev-parse --short HEAD)")
    fi
    if [ -n "${IMAGE_TAG:-}" ]; then
        auto_args+=(--build-arg "IMAGE_TAG=${IMAGE_TAG}")
    fi

    local tag="${module}-${stage}:${IMAGE_TAG}"

    echo ""
    echo "=========================================="
    echo "  Module:   $module"
    echo "  Stage:    $stage"
    echo "  Dockerfile: $dockerfile"
    echo "  Tag:      $tag"
    echo "  Platforms: $PLATFORMS"
    echo "=========================================="

    # Prepare build args (handle empty BUILD_ARGS)
    local build_args=()
    if [ ${#BUILD_ARGS[@]} -gt 0 ]; then
        build_args=("${BUILD_ARGS[@]}")
    fi

    if [ "$PUSH" = true ]; then
        # Multi-arch push
        info "Pushing to registry..."
        docker buildx build \
            -f "$dockerfile" \
            --target "$stage" \
            --platform "$PLATFORMS" \
            "${auto_args[@]}" \
            "${build_args[@]}" \
            -t "$tag" \
            --push \
            "." || return 1
        log "Pushed: $tag"
    else
        # Local build (--load only supports single platform)
        local platform_count
        platform_count=$(echo "$PLATFORMS" | tr ',' '\n' | wc -l | xargs)
        if [ "$platform_count" -gt 1 ]; then
            local first_platform
            first_platform=$(echo "$PLATFORMS" | cut -d',' -f1 | xargs)
            warn "Local build with --load supports single platform only."
            warn "Building for ${first_platform}. Use --push for multi-arch."
            docker buildx build \
                -f "$dockerfile" \
                --target "$stage" \
                --platform "$first_platform" \
                "${auto_args[@]}" \
                "${build_args[@]}" \
                -t "$tag" \
                --load \
                "." || return 1
        else
            docker buildx build \
                -f "$dockerfile" \
                --target "$stage" \
                --platform "$PLATFORMS" \
                "${auto_args[@]}" \
                "${build_args[@]}" \
                -t "$tag" \
                --load \
                "." || return 1
        fi
        log "Built: $tag"
    fi
    return 0
}

# =============================================================================
# Retry function
# =============================================================================
retry_build() {
    local module="$1"
    local stage="$2"
    local max_attempts=3
    local attempt=1
    local delay=5
    local log_file="/tmp/docker_build_${module}_${stage}_$(date +%s).log"

    while [ $attempt -le $max_attempts ]; do
        info "Build attempt $attempt of $max_attempts for $module:$stage..."

        build_single "$module" "$stage" 2>&1 | tee "$log_file"
        local exit_code=${PIPESTATUS[0]}

        if [ $exit_code -eq 0 ]; then
            log "Build successful: $module:$stage"
            rm -f "$log_file"
            return 0
        fi

        # Check for network errors
        if grep -qE "(EOF|timeout|connection|network|short read|failed to fetch|Connection timed out|unable to access)" "$log_file"; then
            if [ "$RETRY" = true ] && [ $attempt -lt $max_attempts ]; then
                warn "Network error. Waiting ${delay}s before retry..."
                sleep "$delay"
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                info "Cleaning buildx cache..."
                docker buildx prune -f 2>/dev/null || true
            else
                err "Network error after $attempt attempt(s): $module:$stage"
                rm -f "$log_file"
                return 1
            fi
        else
            err "Build error (non-network): $module:$stage"
            err "Log: $log_file"
            return 1
        fi
    done

    err "Build failed after $max_attempts attempts: $module:$stage"
    rm -f "$log_file"
    return 1
}

# =============================================================================
# Module resolution
# =============================================================================
resolve_build_targets() {
    local -n targets_ref=$1
    targets_ref=()

    if [ -n "$SELECTED_MODULE" ]; then
        # Single module
        if [ -n "$SELECTED_STAGES" ]; then
            IFS=',' read -ra stages <<< "$SELECTED_STAGES"
            for stg in "${stages[@]}"; do
                stg=$(echo "$stg" | xargs)
                targets_ref+=("$SELECTED_MODULE:$stg")
            done
        else
            targets_ref+=("$SELECTED_MODULE:${MODULE_DEFAULT_STAGE[$SELECTED_MODULE]}")
        fi
    elif [ "$BUILD_ALL_MODULES" = true ]; then
        for module in "${!MODULES[@]}"; do
            if [ -n "$SELECTED_STAGES" ]; then
                IFS=',' read -ra stages <<< "$SELECTED_STAGES"
                for stg in "${stages[@]}"; do
                    stg=$(echo "$stg" | xargs)
                    # Only add if module supports this stage
                    if echo "${MODULE_STAGES[$module]}" | tr ',' '\n' | grep -qx "$stg"; then
                        targets_ref+=("$module:$stg")
                    fi
                done
            else
                targets_ref+=("$module:${MODULE_DEFAULT_STAGE[$module]}")
            fi
        done
    fi

    # Deduplicate
    local -A seen
    local deduped=()
    for t in "${targets_ref[@]}"; do
        [ -z "${seen[$t]:-}" ] && deduped+=("$t") && seen[$t]=1
    done
    targets_ref=("${deduped[@]}")

    if [ ${#targets_ref[@]} -eq 0 ]; then
        err "No build targets resolved."
        err "Use --list to see available modules, or --help for usage."
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Unified Docker Build${NC}"
echo -e "${GREEN}============================================${NC}"
info "Platforms  : ${PLATFORMS}"
info "Tag        : ${IMAGE_TAG}"
info "Push       : ${PUSH}"
echo ""

# Resolve targets
declare -a BUILD_TARGETS
resolve_build_targets BUILD_TARGETS

total=${#BUILD_TARGETS[@]}
current=0
failed=()
successful=()

for target in "${BUILD_TARGETS[@]}"; do
    current=$((current + 1))
    module="${target%%:*}"
    stage="${target##*:}"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    info "[$current/$total] Building ${module}:${stage}"
    echo -e "${GREEN}============================================${NC}"

    if [ "$RETRY" = true ]; then
        if retry_build "$module" "$stage"; then
            successful+=("$target")
        else
            failed+=("$target")
        fi
    else
        if build_single "$module" "$stage"; then
            successful+=("$target")
        else
            failed+=("$target")
        fi
    fi
done

# Summary
echo ""
echo "=========================================="
echo -e "${GREEN}Build Summary${NC}"
echo "=========================================="
info "Total:     $total"
info "Success:   ${#successful[@]}"
info "Failed:    ${#failed[@]}"
echo ""

if [ ${#successful[@]} -gt 0 ]; then
    log "Successfully built:"
    for target in "${successful[@]}"; do
        echo "  - $target"
    done
fi

if [ ${#failed[@]} -gt 0 ]; then
    err "Failed builds:"
    for target in "${failed[@]}"; do
        echo "  - $target"
    done
    exit 1
fi

echo ""
log "=== Build Complete ==="