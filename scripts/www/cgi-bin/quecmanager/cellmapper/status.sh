#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# status.sh — CGI Endpoint: CellMapper Service Status (GET only)
# =============================================================================
# Returns a comprehensive snapshot of the CellMapper integration state,
# including service health, account linkage, GPS source, buffer stats,
# adapter detection, and recent errors.
#
# Reads from:
#   - UCI quecmanager.cellmapper.* (config)
#   - /overlay/cellmapper/hash (account linkage)
#   - /tmp/qmanager_cellmapper.json (runtime state from collector daemon)
#   - /overlay/cellmapper/queue.db (SQLite buffer stats, via cellmapper_db.sh)
#
# Response: See JSON structure in source below.
#
# Endpoint: GET /cgi-bin/quecmanager/cellmapper/status.sh
# Install location: /www/cgi-bin/quecmanager/cellmapper/status.sh
# =============================================================================

qlog_init "cgi_cellmapper_status"
cgi_headers
cgi_handle_options

CM_HASH_FILE="/overlay/cellmapper/hash"
CM_STATE_FILE="/tmp/qmanager_cellmapper.json"
CM_DB_PATH="/overlay/cellmapper/queue.db"

# --- Enforce GET only --------------------------------------------------------
if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_error "method_not_allowed" "Use GET"
    exit 0
fi

qlog_info "CellMapper status requested"

# --- Load UCI config library and ensure defaults exist ----------------------
. /usr/lib/qmanager/cellmapper_uci.sh 2>/dev/null
ensure_cellmapper_config

# --- Read UCI values ---------------------------------------------------------
cm_enabled=$(cm_uci_get enabled 0)
cm_gps_source=$(cm_uci_get gps_source modem)
cm_username=$(cm_uci_get username "")
cm_linked_at=$(cm_uci_get linked_at "")

# Convert numeric 0/1 enabled to boolean string for jq
if [ "$cm_enabled" = "1" ]; then
    svc_enabled="true"
else
    svc_enabled="false"
fi

# --- Check account linkage ---------------------------------------------------
cm_linked="false"
if [ -f "$CM_HASH_FILE" ] && [ -s "$CM_HASH_FILE" ]; then
    cm_linked="true"
fi

# --- Read runtime state from collector daemon --------------------------------
# Defaults if state file is absent or malformed
collector_state="stopped"
uploader_state="idle"
last_measurement="null"
last_upload="null"
gps_fix="null"
errors_json="[]"

if [ -f "$CM_STATE_FILE" ] && [ -s "$CM_STATE_FILE" ]; then
    # Extract fields with safe fallbacks
    collector_state=$(jq -r '.collector_state // "stopped"' "$CM_STATE_FILE" 2>/dev/null)
    uploader_state=$(jq  -r '.uploader_state // "idle"' "$CM_STATE_FILE" 2>/dev/null)

    # last_measurement — keep as raw JSON object or null
    last_measurement=$(jq -c '.last_measurement // null' "$CM_STATE_FILE" 2>/dev/null)
    [ -z "$last_measurement" ] && last_measurement="null"

    # last_upload — keep as raw JSON object or null
    last_upload=$(jq -c '.last_upload // null' "$CM_STATE_FILE" 2>/dev/null)
    [ -z "$last_upload" ] && last_upload="null"

    # gps.fix from state file
    gps_fix=$(jq -c '.gps.fix // null' "$CM_STATE_FILE" 2>/dev/null)
    [ -z "$gps_fix" ] && gps_fix="null"

    # errors — last 20 entries
    errors_json=$(jq -c '[.errors // [] | .[-20:] | .[]]' "$CM_STATE_FILE" 2>/dev/null)
    [ -z "$errors_json" ] && errors_json="[]"

    qlog_debug "State file read: collector=$collector_state uploader=$uploader_state"
else
    qlog_debug "No state file found, using defaults"
fi

# Sanitize collector_state to allowed values
case "$collector_state" in
    running|paused|stopped|error|starting) ;;
    *) collector_state="stopped" ;;
esac

# Sanitize uploader_state to allowed values
case "$uploader_state" in
    running|idle|error) ;;
    *) uploader_state="idle" ;;
esac

# --- Read buffer stats from SQLite ------------------------------------------
pending_count=0
pending_size=0
oldest_age="null"

if [ -f "$CM_DB_PATH" ] && command -v sqlite3 >/dev/null 2>&1; then
    . /usr/lib/qmanager/cellmapper_db.sh 2>/dev/null

    pending_count=$(cm_db_count_pending 2>/dev/null)
    [ -z "$pending_count" ] && pending_count=0

    pending_size=$(cm_db_size_pending 2>/dev/null)
    [ -z "$pending_size" ] && pending_size=0

    oldest_ts=$(cm_db_oldest_pending 2>/dev/null)
    if [ -n "$oldest_ts" ] && [ "$oldest_ts" != "NULL" ]; then
        now=$(date +%s)
        oldest_age=$(( now - oldest_ts ))
    fi

    qlog_debug "Buffer: count=$pending_count size=$pending_size oldest_age=$oldest_age"
else
    qlog_debug "SQLite not available or DB not yet created, buffer stats zeroed"
fi

# --- Detect Quectel adapter --------------------------------------------------
adapter_detected="false"
adapter_name="null"

# Check for known Quectel USB vendor IDs (2c7c) via /sys or lsusb fallback
if ls /sys/bus/usb/devices/*/idVendor 2>/dev/null | xargs grep -l "2c7c" 2>/dev/null | head -1 | grep -q .; then
    adapter_detected="true"
    # Try to read product name from sysfs
    _prd=$(ls /sys/bus/usb/devices/*/idVendor 2>/dev/null | \
        while read vf; do
            if grep -q "2c7c" "$vf" 2>/dev/null; then
                dir=$(dirname "$vf")
                cat "$dir/product" 2>/dev/null
                break
            fi
        done)
    if [ -n "$_prd" ]; then
        adapter_name="$_prd"
    else
        adapter_name="Quectel Modem"
    fi
elif command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi "2c7c"; then
    adapter_detected="true"
    adapter_name=$(lsusb 2>/dev/null | grep -i "2c7c" | head -1 | sed 's/.*2c7c:[^ ]* //' | tr -d '\n')
    [ -z "$adapter_name" ] && adapter_name="Quectel Modem"
fi

# Ensure adapter_name is proper JSON string or null
if [ "$adapter_detected" = "true" ] && [ -n "$adapter_name" ]; then
    adapter_name_json=$(jq -n --arg n "$adapter_name" '$n')
else
    adapter_name_json="null"
fi

# --- Encode nullable string fields for jq ------------------------------------
# account.username
if [ -n "$cm_username" ]; then
    username_json=$(jq -n --arg u "$cm_username" '$u')
else
    username_json="null"
fi

# account.linked_at
if [ -n "$cm_linked_at" ]; then
    linked_at_json="$cm_linked_at"
else
    linked_at_json="null"
fi

# --- Build final JSON response -----------------------------------------------
jq -n \
    --argjson enabled        "$svc_enabled" \
    --arg     col_state      "$collector_state" \
    --arg     upl_state      "$uploader_state" \
    --argjson last_meas      "$last_measurement" \
    --argjson last_up        "$last_upload" \
    --argjson linked         "$cm_linked" \
    --argjson username       "$username_json" \
    --argjson linked_at      "$linked_at_json" \
    --arg     gps_source     "$cm_gps_source" \
    --argjson gps_fix        "$gps_fix" \
    --argjson pend_count     "$pending_count" \
    --argjson pend_size      "$pending_size" \
    --argjson oldest_age     "$oldest_age" \
    --argjson adapter_det    "$adapter_detected" \
    --argjson adapter_name   "$adapter_name_json" \
    --argjson errors         "$errors_json" \
    '{
        success: true,
        service: {
            enabled:         $enabled,
            collector_state: $col_state,
            uploader_state:  $upl_state,
            last_measurement: $last_meas,
            last_upload:     $last_up
        },
        account: {
            linked:     $linked,
            username:   $username,
            linked_at:  $linked_at
        },
        gps: {
            source: $gps_source,
            fix:    $gps_fix
        },
        buffer: {
            pending_count:      $pend_count,
            pending_size_bytes: $pend_size,
            oldest_age_sec:     $oldest_age
        },
        adapter: {
            detected: $adapter_det,
            name:     $adapter_name
        },
        errors: $errors
    }'
