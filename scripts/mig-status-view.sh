#!/usr/bin/env bash

set -u
set -o pipefail

readonly REFRESH_SECONDS="${MIG_STATUS_REFRESH_SECONDS:-10}"
readonly MIN_WIDTH=60

PLAIN_MODE=0

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

get_terminal_width() {
	local width

	width="$(tput cols 2>/dev/null || printf '100\n')"
	if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width < MIN_WIDTH )); then
		width="$MIN_WIDTH"
	fi

	printf '%s\n' "$width"
}

repeat_char() {
	local count="$1"
	local char="$2"
    local output=""

	while (( ${#output} < count )); do
		output+="$char"
	done

	printf '%s\n' "${output:0:count}"
}

print_box_content() {
	local text="$1"
	local inner_width="$2"
	local line

	while IFS= read -r line; do
		printf '| %-'"${inner_width}"'s |\n' "$line"
	done < <(printf '%s\n' "$text" | fold -s -w "$inner_width")
}

render_box() {
	local width="$1"
	shift

	local inner_width=$(( width - 4 ))
	local border
	local line

	border="+$(repeat_char $(( width - 2 )) '-')+"
	printf '%s\n' "$border"

	for line in "$@"; do
		print_box_content "$line" "$inner_width"
	done

	printf '%s\n' "$border"
}

get_gpu_rows() {
	nvidia-smi --query-gpu=index,name,mig.mode.current --format=csv,noheader,nounits 2>/dev/null
}

get_mig_layout_from_l_output() {
	local gpu_index="$1"
	local layout

	layout="$(nvidia-smi -L 2>/dev/null | awk -v idx="$gpu_index" '
		$1 == "GPU" {
			current = ""
			if ($2 ~ /^[0-9]+:$/) {
				gsub(":", "", $2)
				current = $2
			}
			next
		}
		$1 == "MIG" && current == idx {
			profile = $2
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", profile)
			if (profile != "") {
				print profile
			}
		}
	' | paste -sd ',' - | sed 's/,/, /g')"

	printf '%s\n' "$layout"
}

get_mig_layout_from_mig_cli() {
	local gpu_index="$1"

	nvidia-smi mig -lgi -i "$gpu_index" 2>/dev/null | grep -Eo '([0-9]+c\.)?[0-9]+g\.[0-9]+gb' | paste -sd ',' - | sed 's/,/, /g'
}

get_mig_layout() {
	local gpu_index="$1"
	local layout

	layout="$(get_mig_layout_from_l_output "$gpu_index")"

	if [[ -z "$layout" ]]; then
		layout="$(get_mig_layout_from_mig_cli "$gpu_index")"
	fi

	if [[ -z "$layout" ]]; then
		printf '%s\n' "sin instancias creadas"
		return 0
	fi

	printf '%s\n' "$layout"
}

render_dashboard() {
	local width
	local rows
	local line_count=0
	local gpu_index
	local gpu_model
	local mig_mode
	local mig_layout

	width="$(get_terminal_width)"
	rows="$(get_gpu_rows)"

	clear
	printf 'Estado actual de MIG\n'
	printf 'Refresco automatico cada %ss. Pulsa q para volver.\n\n' "$REFRESH_SECONDS"

	if [[ -z "$rows" ]]; then
		render_box "$width" "No se han detectado GPUs NVIDIA mediante nvidia-smi."
		return 0
	fi

	while IFS=',' read -r gpu_index gpu_model mig_mode; do
		gpu_index="$(trim "$gpu_index")"
		gpu_model="$(trim "$gpu_model")"
		mig_mode="$(trim "$mig_mode")"

		if [[ -z "$gpu_index" ]]; then
			continue
		fi

		if [[ "$mig_mode" == "Enabled" ]]; then
			mig_layout="$(get_mig_layout "$gpu_index")"
			render_box "$width" \
				"GPU $gpu_index | Modelo: $gpu_model" \
				"MIG: On" \
				"MIGs: $mig_layout"
		else
			render_box "$width" \
				"GPU $gpu_index | Modelo: $gpu_model" \
				"MIG: Off"
		fi

		printf '\n'
		line_count=$(( line_count + 1 ))
	done <<< "$rows"

	if (( line_count == 0 )); then
		render_box "$width" "No se han podido interpretar las GPUs detectadas."
	fi
}

render_plain_status() {
	local rows
	local line_count=0
	local gpu_index
	local gpu_model
	local mig_mode
	local mig_layout
	local status_line
	local decoration_width
	local decoration_line

	rows="$(get_gpu_rows)"

	if [[ -z "$rows" ]]; then
		printf '%s\n' "No se han detectado GPUs NVIDIA mediante nvidia-smi."
		return 0
	fi

	while IFS=',' read -r gpu_index gpu_model mig_mode; do
		gpu_index="$(trim "$gpu_index")"
		mig_mode="$(trim "$mig_mode")"

		if [[ -z "$gpu_index" ]]; then
			continue
		fi

		if [[ "$mig_mode" == "Enabled" ]]; then
			mig_layout="$(get_mig_layout "$gpu_index")"
			status_line="GPU $gpu_index - MIG On - $mig_layout"
		else
			status_line="GPU $gpu_index - MIG Off"
		fi

		decoration_width=${#status_line}
		if (( decoration_width < 24 )); then
			decoration_width=24
		fi

		decoration_line="$(repeat_char "$decoration_width" "-")"
		printf '%s\n' "$decoration_line"
		printf '%s\n' "$status_line"
		printf '%s\n\n' "$decoration_line"

		line_count=$(( line_count + 1 ))
	done <<< "$rows"

	if (( line_count == 0 )); then
		printf '%s\n' "No se han podido interpretar las GPUs detectadas."
	fi
}

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--plain)
				PLAIN_MODE=1
				;;
		esac
		shift
	done
}

main() {
	local key=""

	parse_args "$@"

	if ! command -v nvidia-smi >/dev/null 2>&1; then
		if (( PLAIN_MODE == 1 )); then
			printf '%s\n' "nvidia-smi no esta disponible en este sistema."
			return 0
		fi

		clear
		render_box "$(get_terminal_width)" "nvidia-smi no esta disponible en este sistema." "Pulsa cualquier tecla para volver."
		read -r -s -n 1 key < /dev/tty
		clear
		return 0
	fi

	if (( PLAIN_MODE == 1 )); then
		render_plain_status
		return 0
	fi

	while true; do
		render_dashboard

		if read -r -s -n 1 -t "$REFRESH_SECONDS" key < /dev/tty; then
			case "$key" in
				q|Q)
					clear
					break
					;;
			esac
		fi
	done
}

main "$@"