#!/usr/bin/env bash

set -u
set -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MIG_STATUS_VIEWER="$SCRIPT_DIR/scripts/mig-status-view.sh"
readonly PRESETS_FILE="$SCRIPT_DIR/presets.conf"
readonly APP_TITLE="GPU MIG Config"
readonly APP_HEIGHT=16
readonly APP_WIDTH=72
readonly MENU_HEIGHT=8
readonly STATUS_HEIGHT=32
readonly STATUS_WIDTH=100

UI_BACKEND=""

is_root_user() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]]
}

list_available_presets() {
	if [[ ! -f "$PRESETS_FILE" ]]; then
		return 1
	fi

	if [[ ! -r "$PRESETS_FILE" ]]; then
		return 1
	fi

	grep -E '^\[.+\]$' "$PRESETS_FILE" 2>/dev/null | sed 's/\[//g; s/\]//g' || return 1
}

parse_preset_config() {
	local preset_name="$1"
	local gpu_id="$2"

	if [[ ! -f "$PRESETS_FILE" ]]; then
		return 1
	fi

	awk -v pname="$preset_name" -v gpu="gpu$gpu_id" '
		BEGIN { in_section = 0; found = 0 }
		/^\[.+\]$/ {
			gsub(/\[|\]/, "")
			in_section = ($0 == pname)
			next
		}
		in_section && $0 ~ "^" gpu "=" {
			gsub("^" gpu "=", "")
			print $0
			found = 1
			exit
		}
		END { if (!found) print "-" }
	' "$PRESETS_FILE"
}

apply_preset() {
	local preset_name="$1"
	local output_msg=""
	local exit_code
	local total_ok=0
	local total_warn=0
	local total_err=0
	local total_skip=0
	local gpu_ok
	local gpu_warn
	local gpu_err
	local gpu_status

	if [[ ! -f "$PRESETS_FILE" ]]; then
		show_message "Error" "No se encontro el archivo de presets en:\n$PRESETS_FILE"
		return 1
	fi

	output_msg="Aplicando preset: $preset_name\n\n"

	for gpu_id in 0 1 2 3; do
		local mig_config
		gpu_ok=0
		gpu_warn=0
		gpu_err=0
		mig_config="$(parse_preset_config "$preset_name" "$gpu_id")"

		if [[ "$mig_config" == "-" ]]; then
			output_msg+="GPU $gpu_id: No configurada (saltada)\n"
			total_skip=$(( total_skip + 1 ))
			continue
		fi

		output_msg+="GPU $gpu_id: Configurando con MIGs: $mig_config\n"
		output_msg+="  - Limpiando estado MIG...\n"

		nvidia-smi mig -i "$gpu_id" -dci >/dev/null 2>&1
		exit_code=$?
		if (( exit_code != 0 && exit_code != 6 )); then
			output_msg+="  - [ERROR] No se pudo destruir CI en GPU $gpu_id (codigo $exit_code)\n"
			gpu_err=$(( gpu_err + 1 ))
			total_err=$(( total_err + 1 ))
			output_msg+="GPU $gpu_id: ERR\n\n"
			continue
		fi

		nvidia-smi mig -i "$gpu_id" -dgi >/dev/null 2>&1
		exit_code=$?
		if (( exit_code != 0 && exit_code != 6 )); then
			output_msg+="  - [ERROR] No se pudo destruir GI en GPU $gpu_id (codigo $exit_code)\n"
			gpu_err=$(( gpu_err + 1 ))
			total_err=$(( total_err + 1 ))
			output_msg+="GPU $gpu_id: ERR\n\n"
			continue
		fi

		output_msg+="  - Creando MIGs... "
		IFS=',' read -ra mig_ids <<< "$mig_config"
		for mig_id in "${mig_ids[@]}"; do
			mig_id="$(printf '%s\n' "$mig_id" | xargs)"
			if nvidia-smi mig -i "$gpu_id" -cgi "$mig_id" -C >/dev/null 2>&1; then
				output_msg+="    OK ($mig_id)..."
				gpu_ok=$(( gpu_ok + 1 ))
				total_ok=$(( total_ok + 1 ))
			else
				output_msg+="    [WARN] No se pudo crear MIG tipo $mig_id en GPU $gpu_id\n"
				gpu_warn=$(( gpu_warn + 1 ))
				total_warn=$(( total_warn + 1 ))
			fi
		done
		output_msg+="\n"

		if (( gpu_err > 0 )); then
			gpu_status="ERR"
		elif (( gpu_warn > 0 )); then
			gpu_status="WARN"
		else
			gpu_status="OK"
		fi

		output_msg+="GPU $gpu_id: $gpu_status (OK=$gpu_ok WARN=$gpu_warn ERR=$gpu_err)\n\n"
	done

	output_msg+="Resumen global:\n"
	output_msg+="  OK=$total_ok\n"
	output_msg+="  WARN=$total_warn\n"
	output_msg+="  ERR=$total_err\n"
	output_msg+="  SKIP=$total_skip\n"

	show_status_message "Resultado" "$output_msg"
	return 0
}

require_ui_backend() {
	if command -v whiptail >/dev/null 2>&1; then
		UI_BACKEND="whiptail"
		return 0
	fi

	if command -v dialog >/dev/null 2>&1; then
		UI_BACKEND="dialog"
		return 0
	fi

	cat <<'EOF'
No se ha encontrado una libreria TUI compatible.

Instala una de estas opciones:
  - Ubuntu/Debian: sudo apt install whiptail
  - RHEL/CentOS:   sudo yum install newt
  - Alternativa:   sudo yum install dialog
EOF
	return 1
}

show_message() {
	local title="$1"
	local message="$2"

	case "$UI_BACKEND" in
		whiptail)
			whiptail --title "$title" --msgbox "$message" "$APP_HEIGHT" "$APP_WIDTH"
			;;
		dialog)
			dialog --title "$title" --msgbox "$message" "$APP_HEIGHT" "$APP_WIDTH"
			;;
	esac
}

show_status_message() {
	local title="$1"
	local message="$2"
	local tmp_file=""

	tmp_file="$(mktemp 2>/dev/null)"
	if [[ -z "$tmp_file" ]]; then
		show_message "$title" "$message"
		return 0
	fi

	printf '%s\n' "$message" > "$tmp_file"

	case "$UI_BACKEND" in
		whiptail)
			whiptail --title "$title" --textbox "$tmp_file" "$STATUS_HEIGHT" "$STATUS_WIDTH"
			;;
		dialog)
			dialog --title "$title" --textbox "$tmp_file" "$STATUS_HEIGHT" "$STATUS_WIDTH"
			;;
	esac

	rm -f "$tmp_file"
}

show_menu() {
	local title="$1"
	local prompt="$2"
	shift 2

	local selection=""

	case "$UI_BACKEND" in
		whiptail)
			if ! selection="$(whiptail \
				--title "$title" \
				--menu "$prompt" \
				"$APP_HEIGHT" "$APP_WIDTH" "$MENU_HEIGHT" \
				"$@" \
				3>&1 1>&2 2>&3)"; then
				selection=""
			fi
			;;
		dialog)
			if ! selection="$(dialog \
				--stdout \
				--title "$title" \
				--menu "$prompt" \
				"$APP_HEIGHT" "$APP_WIDTH" "$MENU_HEIGHT" \
				"$@")"; then
				selection=""
			fi
			;;
	esac
	printf '%s\n' "$selection"
}

show_scrollable_menu() {
	local title="$1"
	local prompt="$2"
	local menu_height="$3"
	shift 3

	local selection=""

	case "$UI_BACKEND" in
		whiptail)
			if ! selection="$(whiptail \
				--title "$title" \
				--scrollbar \
				--menu "$prompt" \
				"$APP_HEIGHT" "$APP_WIDTH" "$menu_height" \
				"$@" \
				3>&1 1>&2 2>&3)"; then
				selection=""
			fi
			;;
		dialog)
			if ! selection="$(dialog \
				--stdout \
				--title "$title" \
				--menu "$prompt" \
				"$APP_HEIGHT" "$APP_WIDTH" "$menu_height" \
				"$@")"; then
				selection=""
			fi
			;;
	esac
	printf '%s\n' "$selection"
}

show_main_menu() {
	show_menu \
		"$APP_TITLE" \
		"Selecciona una opcion:" \
		"1" "Visualizar estado actual de MIG" \
		"2" "Modificar estado MIG" \
		"3" "Salir"
}

show_mig_status_menu() {
	local status_rows=""
	local gpu_index
	local gpu_model
	local mig_state
	local mig_layout
	local status_output=""
	local title_line
	local model_line
	local instances_line
	local content_width=0
	local line
	local border_line
	local padded_line
	local usable_width
	local box_width
	local left_padding=0
	local left_margin=""

	if [[ ! -x "$MIG_STATUS_VIEWER" ]]; then
		show_message \
			"Estado actual de MIG" \
			"No se ha encontrado el visor de estado de MIG en:\n$MIG_STATUS_VIEWER"
		return 1
	fi

	if ! status_rows="$("$MIG_STATUS_VIEWER" --rows)"; then
		show_message \
			"Estado actual de MIG" \
			"No se ha podido consultar el estado de MIG en este momento."
		return 1
	fi

	if [[ -z "$status_rows" ]]; then
		show_message "Estado actual de MIG" "No se han recibido datos de estado MIG."
		return 0
	fi

	while IFS='|' read -r gpu_index gpu_model mig_state mig_layout; do
		gpu_index="${gpu_index:-}"
		gpu_model="${gpu_model:-desconocido}"
		mig_state="${mig_state:-Off}"
		mig_layout="${mig_layout:--}"

		if [[ -z "$gpu_index" ]]; then
			continue
		fi

		title_line="GPU $gpu_index - MIG $mig_state"
		model_line="Modelo: $gpu_model"
		instances_line="Instancias: $mig_layout"

		for line in "$title_line" "$model_line" "$instances_line"; do
			if (( ${#line} > content_width )); then
				content_width=${#line}
			fi
		done
	done <<< "$status_rows"

	if (( content_width < 28 )); then
		content_width=28
	fi

	usable_width=$(( STATUS_WIDTH - 8 ))
	if (( usable_width < 40 )); then
		usable_width=40
	fi

	box_width=$(( content_width + 4 ))
	if (( usable_width > box_width )); then
		left_padding=$(( (usable_width - box_width) / 2 ))
	fi
	printf -v left_margin '%*s' "$left_padding" ''

	border_line="+$(printf '%*s' $(( content_width + 2 )) '' | tr ' ' '-')+"

	while IFS='|' read -r gpu_index gpu_model mig_state mig_layout; do
		gpu_index="${gpu_index:-}"
		gpu_model="${gpu_model:-desconocido}"
		mig_state="${mig_state:-Off}"
		mig_layout="${mig_layout:--}"

		if [[ -z "$gpu_index" ]]; then
			continue
		fi

		title_line="GPU $gpu_index - MIG $mig_state"
		model_line="Modelo: $gpu_model"
		instances_line="Instancias: $mig_layout"

		if [[ -n "$status_output" ]]; then
			status_output+=$'\n\n'
		fi

		status_output+="$left_margin$border_line"
		status_output+=$'\n'

		for line in "$title_line" "$model_line" "$instances_line"; do
			printf -v padded_line '%-*s' "$content_width" "$line"
			status_output+="$left_margin| $padded_line |"
			status_output+=$'\n'
		done

		status_output+="$left_margin$border_line"
	done <<< "$status_rows"

	if [[ -z "$status_output" ]]; then
		show_message "Estado actual de MIG" "No se han podido interpretar las GPUs detectadas."
		return 0
	fi

	show_status_message "Estado actual de MIG" "$status_output"
}

show_preset_load_menu() {
	local presets=()
	local preset_list
	local option=""

	if [[ ! -f "$PRESETS_FILE" ]]; then
		show_message \
			"Carga de presets" \
			"No se encontro el archivo de presets.\n\nRuta esperada:\n$PRESETS_FILE"
		return 1
	fi

	preset_list="$(list_available_presets)" || preset_list=""

	if [[ -z "$preset_list" ]]; then
		show_message \
			"Carga de presets" \
			"No se encontraron presets disponibles en:\n$PRESETS_FILE\n\nVerifica que el archivo contiene secciones [nombre_preset]."
		return 0
	fi

	while IFS= read -r preset_name; do
		if [[ -n "$preset_name" ]]; then
			presets+=("$preset_name" "Cargar preset: $preset_name")
		fi
	done <<< "$preset_list"

	if (( ${#presets[@]} == 0 )); then
		show_message \
			"Carga de presets" \
			"No se encontraron presets disponibles."
		return 0
	fi

	presets+=("v" "Volver")

	while true; do
		option="$(show_menu \
			"Carga de presets" \
			"Selecciona un preset para aplicar:" \
			"${presets[@]}")"

		case "$option" in
			v|"")
				break
				;;
			*)
				if grep -q "^\[$option\]$" "$PRESETS_FILE"; then
					apply_preset "$option"
				else
					show_message "Error" "No se encontro el preset: $option"
				fi
				;;
		esac
	done
}

show_manual_configuration_menu() {
	show_message \
		"Configuracion manual" \
		"Aqui ira la configuracion manual de MIG.\n\nDe momento solo queda montado el flujo y el punto de entrada del submenu."
}

show_modify_mig_menu() {
	local option=""

	while true; do
		option="$(show_menu \
			"Modificar estado MIG" \
			"Selecciona una opcion:" \
			"1" "Carga de presets" \
			"2" "Configuracion manual" \
			"3" "Volver")"

		case "$option" in
			1)
				show_preset_load_menu
				;;
			2)
				show_manual_configuration_menu
				;;
			3|"")
				break
				;;
			*)
				show_message "Opcion no valida" "La opcion seleccionada no es valida."
				;;
		esac
	done
}

main() {
	local option=""

	require_ui_backend || exit 1

	if ! is_root_user; then
		show_message \
			"Permisos insuficientes" \
			"Estas ejecutando la herramienta sin root.\n\nPodras visualizar estado, pero para modificar MIG debes lanzar con sudo/root."
	fi

	while true; do
		option="$(show_main_menu)"

		case "$option" in
			1)
				show_mig_status_menu
				;;
			2)
				if is_root_user; then
					show_modify_mig_menu
				else
					show_message \
						"Permisos insuficientes" \
						"La modificacion de MIG requiere sudo/root.\n\nVuelve a ejecutar la herramienta con privilegios elevados."
				fi
				;;
			3|"")
				break
				;;
			*)
				show_message "Opcion no valida" "La opcion seleccionada no es valida."
				;;
		esac
	done

	if [[ "$UI_BACKEND" == "dialog" ]]; then
		clear
	fi
}

main "$@"
