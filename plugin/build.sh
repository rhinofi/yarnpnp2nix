#!/usr/bin/env bash
set -ueo pipefail

yarn tsc --noEmit
yarn builder build plugin "${@}"