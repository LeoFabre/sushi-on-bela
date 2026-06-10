#!/usr/bin/env bash
# Create compatibility aliases between libevl's expected names and
# the kernel UAPI header definitions.
#
# libevl uses T_INBAND, T_WOSS, T_WEAK, T_WOLI (no EVL_ prefix)
# but the kernel UAPI defines EVL_T_INBAND, EVL_T_WOSS, etc.
#
# This script patches the kernel UAPI thread.h to add the unprefixed aliases.

set -euo pipefail

UAPI_THREAD="$1"

if [[ ! -f "${UAPI_THREAD}" ]]; then
    echo "ERROR: ${UAPI_THREAD} not found" >&2
    exit 1
fi

if grep -q "^#define T_INBAND" "${UAPI_THREAD}"; then
    echo "Compat aliases already present in ${UAPI_THREAD}"
    exit 0
fi

cat >> "${UAPI_THREAD}" << 'COMPAT'

/* Compatibility aliases — libevl uses unprefixed names */
#ifndef T_SUSP
#define T_SUSP    EVL_T_SUSP
#define T_PEND    EVL_T_PEND
#define T_DELAY   EVL_T_DELAY
#define T_WAIT    EVL_T_WAIT
#define T_READY   EVL_T_READY
#define T_DORMANT EVL_T_DORMANT
#define T_ZOMBIE  EVL_T_ZOMBIE
#define T_INBAND  EVL_T_INBAND
#define T_HALT    EVL_T_HALT
#define T_BOOST   EVL_T_BOOST
#define T_RRB     EVL_T_RRB
#define T_ROOT    EVL_T_ROOT
#define T_WEAK    EVL_T_WEAK
#define T_USER    EVL_T_USER
#define T_WOSS    EVL_T_WOSS
#define T_WOLI    EVL_T_WOLI
#define T_WOSX    EVL_T_WOSX
#define T_OBSERV  EVL_T_OBSERV
#define T_HMSIG   EVL_T_HMSIG
#define T_HMOBS   EVL_T_HMOBS
#define T_WOSO    EVL_T_WOSO
#define T_TIMEO   EVL_T_TIMEO
#define T_RMID    EVL_T_RMID
#define T_BREAK   EVL_T_BREAK
#define T_KICKED  EVL_T_KICKED
#define T_CANCELD EVL_T_CANCELD
#define T_BCAST   EVL_T_BCAST
#define T_SIGNAL  EVL_T_SIGNAL
#define T_NOMEM   EVL_T_NOMEM
#endif
COMPAT

echo "Added compat aliases to ${UAPI_THREAD}"
