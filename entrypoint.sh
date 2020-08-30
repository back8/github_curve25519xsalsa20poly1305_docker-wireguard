#!/usr/bin/env bash

function spawn {
    if [[ -z ${PIDS+x} ]]; then PIDS=(); fi
    "$@" &
    PIDS+=($!)
}

function join {
    if [[ ! -z ${PIDS+x} ]]; then
        for pid in "${PIDS[@]}"; do
            wait "${pid}"
        done
    fi
}

function on_kill {
    if [[ ! -z ${PIDS+x} ]]; then
        for pid in "${PIDS[@]}"; do
            kill "${pid}" 2> /dev/null
        done
    fi
    kill "${ENTRYPOINT_PID}" 2> /dev/null
}

function log {
    local LEVEL="$1"
    local MSG="$(date '+%D %T') [${LEVEL}] $2"
    case "${LEVEL}" in
        INFO*)      MSG="\x1B[94m${MSG}";;
        WARNING*)   MSG="\x1B[93m${MSG}";;
        ERROR*)     MSG="\x1B[91m${MSG}";;
        *)
    esac
    echo -e "${MSG}"
}

export ENTRYPOINT_PID="${BASHPID}"

trap "on_kill" EXIT
trap "on_kill" SIGINT

_WIREGUARD_CONFIG="/etc/wireguard/wg.conf"
PROXY_CONFIG="/etc/3proxy.cfg"
PROXY_LOG="/var/log/3proxy.log"

function gen_conf {
    if [[ \
        -n "${WIREGUARD_INTERFACE_PRIVATE_KEY}" && \
        -n "${WIREGUARD_INTERFACE_DNS}" && \
        -n "${WIREGUARD_INTERFACE_ADDRESS}" && \
        -n "${WIREGUARD_PEER_PUBLIC_KEY}" && \
        -n "${WIREGUARD_PEER_ALLOWED_IPS}" && \
        -n "${WIREGUARD_PEER_ENDPOINT}" \
    ]]; then
        echo "[Interface]" > "$1"
        echo "PrivateKey = ${WIREGUARD_INTERFACE_PRIVATE_KEY}" >> "$1"
        echo "DNS = ${WIREGUARD_INTERFACE_DNS}" >> "$1"
        echo "Address = ${WIREGUARD_INTERFACE_ADDRESS}" >> "$1"
        echo >> "$1"
        echo "[Peer]" >> "$1"
        echo "PublicKey = ${WIREGUARD_PEER_PUBLIC_KEY}" >> "$1"
        echo "AllowedIPs = ${WIREGUARD_PEER_ALLOWED_IPS}" >> "$1"
        echo "Endpoint = ${WIREGUARD_PEER_ENDPOINT}" >> "$1"
    else
        log "INFO" "Generating Warp config"
        warp > "$1"
    fi
}

if [ -n "${WIREGUARD_CONFIG}" ]; then
    cp -f "${WIREGUARD_CONFIG}" "${_WIREGUARD_CONFIG}"
else
    log "INFO" "Generating WireGuard config"
    gen_conf "${_WIREGUARD_CONFIG}"
fi

wg-quick up wg
log "INFO" "Spawn WireGuard"

declare -A PROXY_USERS

function check_and_add_proxy_user {
    local user="${!1}"
    local pass="${!2}"
    if [[ -z "${user}" ]]; then
        return 1
    fi
    if [[ -z "${pass}" ]]; then
        log "ERROR" "empty password for user ${user} is not allowed!"
        exit 1
    fi
    if [[ -n "${PROXY_USERS["${user}"]}" ]]; then
        log "WARNING" "duplicated user ${user}, overwriting previous password."
    fi
    PROXY_USERS["${user}"]="${pass}"
    log "INFO" "Add proxy user ${user}"
}

if [[ -n "${SOCKS5_PROXY_PORT}" || -n "${HTTP_PROXY_PORT}" ]]; then

    # single user short-hand
    check_and_add_proxy_user PROXY_USER PROXY_PASS

    # backward compatibility
    check_and_add_proxy_user SOCKS5_USER SOCKS5_PASS

    # multi-user support
    USER_SEQ="1"
    USER_SEQ_END="false"
    while [[ "${USER_SEQ_END}" != "true" ]]; do
        check_and_add_proxy_user "PROXY_USER_${USER_SEQ}" "PROXY_PASS_${USER_SEQ}"
        STATUS=$?
        if [[ "${STATUS}" != 0 ]]; then
            USER_SEQ_END="true"
        fi
        USER_SEQ=$(( "${USER_SEQ}" + 1 ))
    done

    echo "nscache 65536" > "${PROXY_CONFIG}"
    for PROXY_USER in "${!PROXY_USERS[@]}"; do
        echo "users \"${PROXY_USER}:$(mycrypt "$(openssl rand -hex 16)" "${PROXY_USERS["${PROXY_USER}"]}")\"" >> "${PROXY_CONFIG}"
    done
    echo "log \"${PROXY_LOG}\" D" >> "${PROXY_CONFIG}"
    echo "logformat \"- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T\"" >> "${PROXY_CONFIG}"
    echo "rotate 30" >> "${PROXY_CONFIG}"
    echo "external 0.0.0.0" >> "${PROXY_CONFIG}"
    echo "internal 0.0.0.0" >> "${PROXY_CONFIG}"
    if [[ "${#PROXY_USERS[@]}" -gt 0 ]]; then
        echo "auth strong" >> "${PROXY_CONFIG}"
    fi
    echo "flush" >> "${PROXY_CONFIG}"
    for PROXY_USER in "${!PROXY_USERS[@]}"; do
        echo "allow \"${PROXY_USER}\"" >> "${PROXY_CONFIG}"
    done
    echo "maxconn 384" >> "${PROXY_CONFIG}"
    if [[ -n "${SOCKS5_PROXY_PORT}" ]]; then
        echo "socks -p${SOCKS5_PROXY_PORT}" >> "${PROXY_CONFIG}"
    fi
    if [[ -n "${HTTP_PROXY_PORT}" ]]; then
        echo "proxy -p${HTTP_PROXY_PORT}" >> "${PROXY_CONFIG}"
    fi

    log "INFO" "Write 3proxy config"

    spawn 3proxy "${PROXY_CONFIG}"
    log "INFO" "Spawn 3proxy"

    PROXY_ENABLED="true"
fi

if [[ -n "${ARIA2_PORT}" ]]; then
    cmd=(aria2c --enable-rpc --disable-ipv6 --rpc-listen-all --rpc-listen-port="${ARIA2_PORT}")
    if [[ -n "${ARIA2_PASS}" ]]; then
        cmd+=(--rpc-secret "${ARIA2_PASS}")
    fi
    if [[ -n "${ARIA2_PATH}" ]]; then
        cmd+=(--dir "${ARIA2_PATH}")
    fi
    if [[ -n "${ARIA2_ARGS}" ]]; then
        eval cmd\+\=\( ${ARIA2_ARGS} \)
    fi
    spawn "${cmd[@]}"
    log "INFO" "Spawn aria2c"
    ARIA2_ENABLED="true"
fi

log "INFO" "WireGuard become stable"

SUBNET=$(ip -o -f inet addr show dev eth0 | awk '{print $4}')
IPADDR=$(echo "${SUBNET}" | cut -f1 -d'/')
GATEWAY=$(route -n | grep 'UG[ \t]' | awk '{print $2}')
eval "$(ipcalc -np "${SUBNET}")"

ip -4 rule del not fwmark 51820 table 51820
ip -4 rule del table main suppress_prefixlength 0

ip -4 rule add prio 10 from "${IPADDR}" table 128
ip -4 route add table 128 to "${NETWORK}/${PREFIX}" dev eth0
ip -4 route add table 128 default via "${GATEWAY}"

ip -4 rule add prio 20 not fwmark 51820 table 51820
ip -4 rule add prio 20 table main suppress_prefixlength 0

log "INFO" "Updated iptables"

if [[ "${ARIA2_ENABLED}" == "true" && -n "${ARIA2_UP}" ]]; then
    spawn "${ARIA2_UP}"
    log "INFO" "Spawn aria2 up script: ${ARIA2_UP}"
fi

if [[ "${PROXY_ENABLED}" == "true" && -n "${PROXY_UP}" ]]; then
    spawn "${PROXY_UP}"
    log "INFO" "Spawn proxy up script: ${PROXY_UP}"
fi

if [[ -n "${WIREGUARD_UP}" ]]; then
    spawn "${WIREGUARD_UP}"
    log "INFO" "Spawn WireGuard up script: ${WIREGUARD_UP}"
fi

if [[ $# -gt 0 ]]; then
    log "INFO" "Execute command line: $@"
    "$@"
fi

if [[ $# -eq 0 || "${DAEMON_MODE}" == true ]]; then
    join
fi
