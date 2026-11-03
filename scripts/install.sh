#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scripts/build.sh
swift scripts/deploy.swift
