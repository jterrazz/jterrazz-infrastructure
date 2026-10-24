#!/bin/bash
# invariant: shared logging helpers. Source it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

info() { echo -e "${BLUE}→ $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}" >&2; }
section() { echo -e "\n${GREEN}▶ $1${NC}"; }
