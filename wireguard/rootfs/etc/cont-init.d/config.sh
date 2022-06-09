#!/command/with-contenv bashio
# ==============================================================================
# Home Assistant Community Add-on: WireGuard
# Creates the interface configuration
# ==============================================================================
declare -a list
declare addresses
declare allowed_ips
declare config
declare config_dir
declare dns
declare endpoint
declare filename
declare fwmark
declare host
declare interface
declare keep_alive
declare mtu
declare name
declare peer_private_key
declare peer_public_key
declare port
declare post_down
declare post_up
declare pre_down
declare pre_shared_key
declare pre_up
declare server_private_key
declare server_public_key
declare table

if ! bashio::fs.directory_exists '/ssl/wireguard'; then
    mkdir -p /ssl/wireguard ||
        bashio::exit.nok "Could not create wireguard storage folder!"
fi

# Get interface and config file location
interface="wg0"
if bashio::config.has_value "server.interface"; then
    interface=$(bashio::config "server.interface")
fi
config="/etc/wireguard/${interface}.conf"

# Start creation of configuration
echo "[Interface]" > "${config}"

# Check if at least 1 address is specified
if ! bashio::config.has_value 'server.addresses'; then
    bashio::exit.nok 'You need at least 1 address configured for the server'
fi

# Add all server addresses to the configuration
for address in $(bashio::config 'server.addresses'); do
    [[ "${address}" == *"/"* ]] || address="${address}/24"
    echo "Address = ${address}" >> "${config}"
done

# Add all server DNS addresses to the configuration
if bashio::config.has_value 'server.dns'; then
    for dns in $(bashio::config 'server.dns'); do
        echo "DNS = ${dns}" >> "${config}"
    done
else
    dns=$(bashio::dns.host)
    echo "DNS = ${dns}" >> "${config}"
fi

# Get the server's private key
if bashio::config.has_value 'server.private_key'; then
    server_private_key=$(bashio::config 'server.private_key')
else
    if ! bashio::fs.file_exists '/ssl/wireguard/private_key'; then
        umask 077 || bashio::exit.nok "Could not set a proper umask"
        wg genkey > /ssl/wireguard/private_key ||
            bashio::exit.nok "Could not generate private key!"
    fi
    server_private_key=$(</ssl/wireguard/private_key)
fi

# Get the server pubic key
if bashio::config.has_value 'server.public_key'; then
    server_public_key=$(bashio::config 'server.public_key')
else
    server_public_key=$(wg pubkey <<< "${server_private_key}")
fi

fwmark=$(bashio::config "server.fwmark")
mtu=$(bashio::config "server.mtu")
pre_down=$(bashio::config "server.pre_down")
pre_up=$(bashio::config "server.pre_up")
table=$(bashio::config "server.table")

# Pre Up & Down handling
if [[ "${pre_up}" = "off" ]]; then
    pre_up=""
fi
if [[ "${pre_down}" = "off" ]]; then
    pre_down=""
fi

# Post Up & Down defaults
post_up="iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
post_down="iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"
if [[ $(</proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    bashio::log.warning
    bashio::log.warning "IP forwarding is disabled on the host system!"
    bashio::log.warning "You can still use WireGuard to access Hass.io,"
    bashio::log.warning "however, you cannot access your home network or"
    bashio::log.warning "the internet via the VPN tunnel."
    bashio::log.warning
    bashio::log.warning "Please consult the add-on documentation on how"
    bashio::log.warning "to resolve this."
    bashio::log.warning

    # Set fake placeholders for Up & Down commands
    post_up=""
    post_down=""
fi

# Load custom PostUp setting if provided
if bashio::config.has_value 'server.post_up'; then
    post_up=$(bashio::config 'server.post_up')
    if [[ "${post_up}" = "off" ]]; then
        post_up=""
    fi
fi

# Load custom PostDown setting if provided
if bashio::config.has_value 'server.post_down'; then
    post_down=$(bashio::config 'server.post_down')
    if [[ "${post_down}" = "off" ]]; then
        post_down=""
    fi
fi

# Finish up the main server configuration
{
    echo "PrivateKey = ${server_private_key}"

    # Adds server port to the configuration
    echo "ListenPort = 51820"

    # Custom routing table
    bashio::config.has_value "server.table" && echo "Table = ${table}"

    # Pre up & down
    bashio::config.has_value "server.pre_up" && echo "PreUp = ${pre_up}"
    bashio::config.has_value "server.pre_down" && echo "PreDown = ${pre_down}"

    # Post up & down
    bashio::var.has_value "${post_up}" && echo "PostUp = ${post_up}"
    bashio::var.has_value "${post_down}" && echo "PostDown = ${post_down}"

    # fwmark for outgoing packages
    bashio::config.has_value "server.fwmark" && echo "FwMark = ${fwmark}"

    # Custom MTU setting
    bashio::config.has_value "server.mtu" && echo "MTU = ${mtu}"

    # End configuration file with an empty line
    echo ""
} >> "${config}"

# Get DNS for client configurations
if bashio::config.has_value 'server.dns'; then
    dns=$(bashio::config "server.dns | join(\", \")")
fi

# Status API Storage
if ! bashio::fs.directory_exists '/var/lib/wireguard'; then
    mkdir -p /var/lib/wireguard \
        || bashio::exit.nok "Could not create status API storage folder"
fi

# Fetch all the peers
for peer in $(bashio::config 'peers|keys'); do

    name=$(bashio::config "peers[${peer}].name")

    # Check if at least 1 address is specified
    if ! bashio::config.has_value "peers[${peer}].addresses"; then
        bashio::exit.nok "You need at least 1 address configured for ${name}"
    fi

    config_dir="/ssl/wireguard/${name}"
    endpoint=$(bashio::config "peers[${peer}].endpoint")
    fwmark=$(bashio::config "peers[${peer}].fwmark")
    host=$(bashio::config 'server.host')
    port=$(bashio::addon.port "51820/udp")
    pre_shared_key=$(bashio::config "peers[${peer}].pre_shared_key")

    # Create directory for storing client configuration
    mkdir -p "${config_dir}" ||
        bashio::exit.nok "Failed creating client folder for ${name}"

    # Get the private key
    peer_private_key=""
    if bashio::config.has_value "peers[${peer}].private_key"; then
        peer_private_key=$(bashio::config "peers[${peer}].private_key")
    elif ! bashio::config.has_value "peers[${peer}].public_key"; then
        # If a public key is not provided, try get a private key from disk
        # or generate one if needed.
        if ! bashio::fs.file_exists "${config_dir}/private_key"; then
            umask 077 || bashio::exit.nok "Could not set a proper umask"
            wg genkey > "${config_dir}/private_key" ||
                bashio::exit.nok "Could not generate private key for ${name}!"
        fi
        peer_private_key=$(<"${config_dir}/private_key")
    fi

    # Get the public key
    peer_public_key=""
    if bashio::config.has_value "peers[${peer}].public_key"; then
        peer_public_key=$(bashio::config "peers[${peer}].public_key")
    elif bashio::var.has_value "${peer_private_key}"; then
        peer_public_key=$(wg pubkey <<< "${peer_private_key}")
    fi

    # Get peer addresses
    list=()
    for address in $(bashio::config "peers[${peer}].addresses"); do
        [[ "${address}" == *"/"* ]] || address="${address}/24"
        list+=("${address}")
    done
    addresses=$(IFS=", "; echo "${list[*]}")

    # Determine allowed IPs for server side config, by default use
    # peer defined addresses.
    list=()
    if bashio::config.has_value "peers[${peer}].allowed_ips"; then
        # Use allowed IP's defined by the user.
        for address in $(bashio::config "peers[${peer}].allowed_ips"); do
            [[ "${address}" == *"/"* ]] || address="${address}/32"
            list+=("${address}")
        done
    else
        for address in $(bashio::config "peers[${peer}].addresses"); do
            [[ "${address}" == *"/"* ]] || address="${address}/32"
            list+=("${address}")
        done
    fi
    allowed_ips=$(IFS=", "; echo "${list[*]}")

    # Determine persistent keep alive
    keep_alive=25
    if bashio::config.has_value "peers[${peer}].persistent_keep_alive"; then
        keep_alive=$(bashio::config "peers[${peer}].persistent_keep_alive")
    fi

    # Start writing peer information in server config
    {
        echo "[Peer]"
        echo "PublicKey = ${peer_public_key}"
        echo "AllowedIPs = ${allowed_ips}"
        echo "PersistentKeepalive = ${keep_alive}"
        bashio::config.has_value "peers[${peer}].pre_shared_key" \
            && echo "PreSharedKey = ${pre_shared_key}"
        bashio::config.has_value "peers[${peer}].endpoint" \
            && echo "Endpoint = ${endpoint}"
        echo ""
    } >> "${config}"

    # Generate client configuration

    # Determine allowed IPs for client configuration
    allowed_ips="0.0.0.0/0"
    if bashio::config.has_value "peers[${peer}].client_allowed_ips"; then
        allowed_ips=$(
            bashio::config "peers[${peer}].client_allowed_ips | join(\", \")"
        )
    fi

    # Write client configuration file
    {
        echo "[Interface]"
        bashio::fs.file_exists "${config_dir}/private_key" \
            && echo "PrivateKey = ${peer_private_key}"
        echo "Address = ${addresses}"
        echo "DNS = ${dns}"
        bashio::config.has_value "peers[${peer}].fwmark" \
            && echo "FwMark = ${fwmark}"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${server_public_key}"
        echo "Endpoint = ${host}:${port}"
        echo "AllowedIPs = ${allowed_ips}"
        echo "PersistentKeepalive = ${keep_alive}"
        echo ""
    } > "${config_dir}/client.conf"

    # Generate QR code with client configuration
    qrencode -t PNG -o "${config_dir}/qrcode.png" < "${config_dir}/client.conf"

    # Store client name for the status API based on public key
    filename=$(sha1sum <<< "${peer_public_key}" | awk '{ print $1 }')
    echo -n "${name}" > "/var/lib/wireguard/${filename}"
done
