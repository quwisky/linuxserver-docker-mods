# shellcheck shell=bash
#===============================================================================
# netns-watchdog -- detect a container stranded in a dead network namespace.
#
# THIS FILE IS DUPLICATED VERBATIM IN EVERY gluetun-portforward MOD.
# ci/check-shared-files.sh asserts the copies are byte-identical and runs from
# repo.yml, which has no paths filter -- so editing one copy and not the other
# fails CI even when only one mod's directory changed. Edit all copies together.
#
# No shebang: this is sourced, never executed. It is deliberately NOT executable,
# which also keeps it out of the executable-bit check CI applies to run/finish.
#
#-------------------------------------------------------------------------------
# The problem
#
# `network_mode: service:gluetun` joins gluetun's network namespace by container
# ID. When the gluetun container RESTARTS -- not merely reconnects -- that
# namespace is destroyed and a new one created. Docker never re-attaches this
# container, so it is stranded in the dead one: eth0 went with the veth pair,
# tun0 went with gluetun's tun fd, and only lo remains. The app is unreachable
# (its ports are published on gluetun) and nothing can route out. It stays that
# way until this container is restarted, at which point Docker re-resolves the
# network mode against gluetun's *current* sandbox.
#
# So the fix is to notice from the inside and exit PID 1, letting Docker's
# restart policy bring the container back attached correctly.
#
#-------------------------------------------------------------------------------
# Why the interface scan, and not a reachability probe
#
# The signal is THE ABSENCE OF ANY NON-LOOPBACK INTERFACE IN /sys/class/net.
# That is what makes this feature viable at all: a VPN reconnect tears down tun0
# but leaves eth0, so it cannot be confused with the orphaned state.
#
# Reachability of gluetun's control server is deliberately NOT the signal. It
# cannot distinguish a reconnect from an orphaning -- both look like "connection
# refused" -- and acting on it would halt the container every time the VPN
# blipped.
#
# The scan is pure bash against /sys. No iproute2, no jq, no package installs.
#
#-------------------------------------------------------------------------------
# Safety
#
# This can stop a container, so every uncertainty resolves towards doing nothing:
#
#   * Off unless GLUETUN_PF_NETNS_WATCHDOG is explicitly set truthy. Everything
#     below is inert until then, and netns_watchdog_check() returns immediately.
#   * A missing or unreadable /sys/class/net reports "network present". A
#     container without /sys mounted must never be halted on that basis.
#   * A grace period after service start, because the namespace is still being
#     set up early in container start.
#   * N consecutive failed checks, not one.
#   * A dry-run mode that logs the decision and halts nothing.
#===============================================================================

#-------------------------------------------------------------------------------
# Fallbacks. Both mods define these identically before sourcing this file, so in
# production none of these definitions ever take effect. They exist so the helper
# can be sourced on its own, which is how the unit tests exercise it -- and so a
# future mod that sources it without them still works rather than dying on an
# unbound command.
#-------------------------------------------------------------------------------
if ! declare -F log >/dev/null 2>&1; then
    log() { echo "[mod-gluetun-portforward] $*"; }
fi
if ! declare -F loud >/dev/null 2>&1; then
    loud() { echo "[mod-gluetun-portforward] **** $* ****"; }
fi
if ! declare -F truthy >/dev/null 2>&1; then
    truthy() { [[ ! ${1,,} =~ ^(0|false|no|off|disable|disabled)$ ]]; }
fi
if ! declare -F is_uint >/dev/null 2>&1; then
    is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
fi

#-------------------------------------------------------------------------------
# State. Initialised here so nothing is ever unset, matching ./run's convention.
# NETNS_WATCHDOG=0 is what guarantees that a mod which never calls
# netns_watchdog_configure() behaves exactly as it did before this file existed.
#-------------------------------------------------------------------------------
NETNS_WATCHDOG=0        # master switch, off until configure() says otherwise
NETNS_DRY_RUN=0
NETNS_STRIKES_MAX=4
NETNS_GRACE=60
NETNS_EXIT_CODE=70
NETNS_SYSFS="${NETNS_SYSFS:-/sys/class/net}"
NETNS_STRIKES=0         # consecutive failed checks; survives across poll iterations
NETNS_GRACE_LOGGED=0
NETNS_DRY_RUN_ANNOUNCED=0

#-------------------------------------------------------------------------------
# netns_watchdog_configure(): env -> globals. Called from the mod's configure(),
# so that sourcing ./run with GLUETUN_PF_LIB_ONLY=1 still has no side effects.
#
# Clamps rather than fails, like the rest of the mod: refusing to run because
# someone typed "60s" is the wrong call for a background mod.
#-------------------------------------------------------------------------------
netns_watchdog_configure() {
    NETNS_SYSFS="${NETNS_SYSFS:-/sys/class/net}"
    NETNS_STRIKES=0
    NETNS_GRACE_LOGGED=0
    NETNS_DRY_RUN_ANNOUNCED=0

    # Unset or empty means off. Note this is NOT `truthy`, which treats an empty
    # value as true -- the default here has to be off, not on.
    NETNS_WATCHDOG=0
    if [[ -n ${GLUETUN_PF_NETNS_WATCHDOG:-} ]] && truthy "${GLUETUN_PF_NETNS_WATCHDOG}"; then
        NETNS_WATCHDOG=1
    fi

    NETNS_DRY_RUN=0
    if [[ -n ${GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN:-} ]] &&
        truthy "${GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN}"; then
        NETNS_DRY_RUN=1
    fi

    NETNS_STRIKES_MAX="${GLUETUN_PF_NETNS_WATCHDOG_STRIKES:-4}"
    if ! is_uint "${NETNS_STRIKES_MAX}" || ((NETNS_STRIKES_MAX < 1)); then
        loud "GLUETUN_PF_NETNS_WATCHDOG_STRIKES='${NETNS_STRIKES_MAX}' is not a number >= 1, using 4"
        NETNS_STRIKES_MAX=4
    fi

    NETNS_GRACE="${GLUETUN_PF_NETNS_WATCHDOG_GRACE:-60}"
    if ! is_uint "${NETNS_GRACE}"; then
        loud "GLUETUN_PF_NETNS_WATCHDOG_GRACE='${NETNS_GRACE}' is not a number, using 60"
        NETNS_GRACE=60
    fi

    # Must be non-zero, so `restart: on-failure` also brings the container back.
    # A zero here would look like a clean exit and on-failure would leave it
    # stopped -- the exact opposite of the point.
    NETNS_EXIT_CODE="${GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE:-70}"
    if ! is_uint "${NETNS_EXIT_CODE}" || ((NETNS_EXIT_CODE < 1 || NETNS_EXIT_CODE > 255)); then
        loud "GLUETUN_PF_NETNS_WATCHDOG_EXIT_CODE='${NETNS_EXIT_CODE}' is not a number 1-255, using 70"
        NETNS_EXIT_CODE=70
    fi
    return 0
}

# netns_watchdog_enabled -> 0 when the watchdog is armed.
netns_watchdog_enabled() { ((NETNS_WATCHDOG)); }

#-------------------------------------------------------------------------------
# netns_has_network -> 0 if any non-loopback interface exists.
#
# Pure bash: a glob over the sysfs directory, no external command. Prints
# nothing and sets no state, so it is safe to call from anywhere.
#
# A missing directory returns 0 (network present). Absence of evidence is not
# evidence of a dead namespace, and this is the one branch where guessing wrong
# stops someone's container.
#-------------------------------------------------------------------------------
netns_has_network() {
    local sysfs="${NETNS_SYSFS:-/sys/class/net}" entry name
    [[ -d ${sysfs} ]] || return 0

    for entry in "${sysfs}"/*; do
        # No nullglob here (setting shell options in a sourced helper would leak
        # into the caller), so an empty directory yields the literal pattern.
        [[ -e ${entry} ]] || continue
        name="${entry##*/}"
        case "${name}" in
            # bonding_masters is a control file the bonding module drops in this
            # directory, not an interface. Everything else here is one.
            lo | bonding_masters) continue ;;
        esac
        return 0
    done
    return 1
}

#-------------------------------------------------------------------------------
# netns_watchdog_halt -- write the exit code where s6 will read it, then bring
# the container down. Never returns.
#
# The halt is GRACEFUL: s6 runs the shutdown sequence, every service gets
# SIGTERM and every finish script runs, so the application closes its files
# properly. That is the advantage over an external `docker kill`.
#
# Verified against s6-overlay 3.2.1.0, which is what both linuxserver/qbittorrent
# and linuxserver/plex currently ship:
#   * /run/s6-linux-init-container-results/exitcode already exists at runtime;
#     the mkdir is insurance for a version that does not pre-create it.
#   * /run/s6/basedir/bin/halt does NOT exist at build time -- s6-linux-init
#     writes it at boot -- but is present at runtime, and the container really
#     does exit with the code written above.
#   * s6-svscanctl -t /run/service is the fallback for a layout that lacks the
#     basedir. It is not the primary because the primary is confirmed present.
#-------------------------------------------------------------------------------
netns_watchdog_halt() {
    loud "halting the container so docker re-attaches it to gluetun's namespace (exit ${NETNS_EXIT_CODE})"
    log "  -> this only recovers if the container has 'restart: unless-stopped' (or 'on-failure'). Without it, it just stops."
    log "  -> docker refuses to start a container whose 'network_mode: service:' target is down, so while gluetun is"
    log "     still starting the restart retries with backoff. That is correct -- it cannot leak while stopped."

    mkdir -p /run/s6-linux-init-container-results 2>/dev/null
    if ! echo "${NETNS_EXIT_CODE}" >/run/s6-linux-init-container-results/exitcode 2>/dev/null; then
        log "could not write the exit code; the container will still halt, with s6's own status"
    fi

    if [[ -x /run/s6/basedir/bin/halt ]]; then
        exec /run/s6/basedir/bin/halt
    fi
    loud "/run/s6/basedir/bin/halt is absent; falling back to s6-svscanctl"
    exec s6-svscanctl -t /run/service
}

#-------------------------------------------------------------------------------
# netns_watchdog_check -- call this as the FIRST statement of the poll loop.
#
# Ordering matters: when the namespace is dead every port-sync attempt fails
# anyway, so checking last would emit a wall of connection errors before the
# watchdog fired.
#
# Returns 0 in every case where the loop should carry on, which is all of them
# except the halt -- and that never returns.
#-------------------------------------------------------------------------------
netns_watchdog_check() {
    netns_watchdog_enabled || return 0

    if netns_has_network; then
        if ((NETNS_STRIKES > 0)); then
            loud "network namespace recovered after ${NETNS_STRIKES} strike(s); watchdog reset"
        fi
        NETNS_STRIKES=0
        NETNS_GRACE_LOGGED=0
        NETNS_DRY_RUN_ANNOUNCED=0
        return 0
    fi

    # SECONDS is time since this service started, and s6 restarts the service
    # after a failed halt, so the grace period re-arms on its own.
    if ((SECONDS < NETNS_GRACE)); then
        if ((!NETNS_GRACE_LOGGED)); then
            NETNS_GRACE_LOGGED=1
            log "no non-loopback interface yet, but still inside the ${NETNS_GRACE}s startup grace period"
        fi
        return 0
    fi

    NETNS_STRIKES=$((NETNS_STRIKES + 1))
    # Armed, this can log at most NETNS_STRIKES_MAX lines because the last one
    # halts. Dry run keeps counting forever, so stop logging at the threshold
    # rather than printing "strike 97/4" once a minute for the rest of time.
    if ((NETNS_STRIKES <= NETNS_STRIKES_MAX)); then
        loud "no non-loopback interface in ${NETNS_SYSFS} -- this container looks stranded in a dead network namespace (strike ${NETNS_STRIKES}/${NETNS_STRIKES_MAX})"
    fi
    ((NETNS_STRIKES >= NETNS_STRIKES_MAX)) || return 0

    if ((NETNS_DRY_RUN)); then
        if ((!NETNS_DRY_RUN_ANNOUNCED)); then
            NETNS_DRY_RUN_ANNOUNCED=1
            loud "DRY RUN: would halt the container now with exit ${NETNS_EXIT_CODE}; set GLUETUN_PF_NETNS_WATCHDOG_DRY_RUN=false to arm it"
        fi
        return 0
    fi

    netns_watchdog_halt
}
