#!/usr/bin/env bash

set -u
set -o pipefail

readonly REFRESH_SECONDS="${MIG_STATUS_REFRESH_SECONDS:-10}"
readonly MIN_WIDTH=60
readonly PLAIN_CONTENT_MAX_WIDTH=92

PLAIN_MODE=0
ROWS_MODE=0

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

truncate_text() {
	local text="$1"
	local max_width="$2"

	if (( ${#text} <= max_width )); then
		printf '%s\n' "$text"
		return 0
	fi

	if (( max_width <= 3 )); then
		printf '%s\n' "${text:0:max_width}"
		return 0
	fi

	printf '%s...\n' "${text:0:$(( max_width - 3 ))}"
}

center_text() {
	local text="$1"
	local width="$2"
	local text_len=${#text}
	local left_padding=0
	local right_padding=0

	if (( text_len >= width )); then
		printf '%s\n' "$text"
		return 0
	fi

	left_padding=$(( (width - text_len) / 2 ))
	right_padding=$(( width - text_len - left_padding ))

	printf '%s%s%s\n' "$(repeat_char "$left_padding" ' ')" "$text" "$(repeat_char "$right_padding" ' ')"
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

get_plain_view_width() {
	local configured_width="${MIG_STATUS_PLAIN_WIDTH:-}"
	local width

	if [[ "$configured_width" =~ ^[0-9]+$ ]] && (( configured_width >= 30 )); then
		printf '%s\n' "$configured_width"
		return 0
	fi

	width="$(tput cols 2>/dev/null || printf '100\n')"
	if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width < 30 )); then
		width=100
	fi

	printf '%s\n' "$width"
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
	local mig_mode
	local mig_layout
	local status_line
	local content_line
	local content_width=0
	local border_line
	local separator_line=""
	local plain_view_width
	local effective_content_max
	local box_width
	local left_padding
	local left_margin=""

	rows="$(get_gpu_rows)"

	if [[ -z "$rows" ]]; then
		printf '%s\n' "No se han detectado GPUs NVIDIA mediante nvidia-smi."
		return 0
	fi

	plain_view_width="$(get_plain_view_width)"
	effective_content_max=$(( plain_view_width - 12 ))
	if (( effective_content_max > PLAIN_CONTENT_MAX_WIDTH )); then
		effective_content_max=$PLAIN_CONTENT_MAX_WIDTH
	fi
	if (( effective_content_max < 24 )); then
		effective_content_max=24
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

		status_line="$(truncate_text "$status_line" "$effective_content_max")"
		if (( ${#status_line} > content_width )); then
			content_width=${#status_line}
		fi

		if [[ -n "$separator_line" ]]; then
			separator_line+=$'\n'
		fi
		separator_line+="$status_line"

		line_count=$(( line_count + 1 ))
	done <<< "$rows"

	if (( line_count == 0 )); then
		printf '%s\n' "No se han podido interpretar las GPUs detectadas."
		return 0
	fi

	if (( content_width < 24 )); then
		content_width=24
	fi

	box_width=$(( content_width + 4 ))
	left_padding=0
	if (( plain_view_width > box_width )); then
		left_padding=$(( (plain_view_width - box_width) / 2 ))
	fi
	left_margin="$(repeat_char "$left_padding" ' ')"

	border_line="+$(repeat_char "$(( content_width + 2 ))" '-')+"

	while IFS= read -r content_line; do
		printf '%s%s\n' "$left_margin" "$border_line"
		printf '%s| %s |\n' "$left_margin" "$(center_text "$content_line" "$content_width")"
		printf '%s%s\n\n' "$left_margin" "$border_line"
	done <<< "$separator_line"
}

render_status_rows() {
	local rows
	local gpu_index
	local gpu_model
	local mig_mode
	local mig_layout

	rows="$(get_gpu_rows)"

	if [[ -z "$rows" ]]; then
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
			printf '%s|%s|On|%s\n' "$gpu_index" "$gpu_model" "$mig_layout"
		else
			printf '%s|%s|Off|-\n' "$gpu_index" "$gpu_model"
		fi
	done <<< "$rows"
}

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--plain)
				PLAIN_MODE=1
				;;
			--rows)
				ROWS_MODE=1
				;;
		esac
		shift
	done
}

main() {
	local key=""

	parse_args "$@"

	if ! command -v nvidia-smi >/dev/null 2>&1; then
		if (( ROWS_MODE == 1 )); then
			return 0
		fi

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

	if (( ROWS_MODE == 1 )); then
		render_status_rows
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