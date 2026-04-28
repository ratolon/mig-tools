#!/usr/bin/env bash

set -u
set -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MIG_STATUS_VIEWER="$SCRIPT_DIR/scripts/mig-status-view.sh"
readonly APP_TITLE="GPU MIG Config"
readonly APP_HEIGHT=16
readonly APP_WIDTH=72
readonly MENU_HEIGHT=8
readonly STATUS_HEIGHT=24
readonly STATUS_WIDTH=100

UI_BACKEND=""

is_root_user() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]]
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
	local option=""
	local gpu_index
	local gpu_model
	local mig_state
	local mig_layout
	local detail_message
	local description
	local menu_items=()

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
		gpu_model="${gpu_model:-}"
		mig_state="${mig_state:-Off}"
		mig_layout="${mig_layout:--}"

		if [[ -z "$gpu_index" ]]; then
			continue
		fi

		description="MIG $mig_state"
		if [[ "$mig_state" == "On" ]]; then
			description+=" | $mig_layout"
		fi

		menu_items+=("$gpu_index" "$description")
	done <<< "$status_rows"

	if (( ${#menu_items[@]} == 0 )); then
		show_message "Estado actual de MIG" "No se han podido interpretar las GPUs detectadas."
		return 0
	fi

	while true; do
		option="$(show_menu \
			"Estado actual de MIG" \
			"Selecciona una GPU para ver detalle:" \
			"${menu_items[@]}" \
			"v" "Volver")"

		case "$option" in
			v|"")
				break
				;;
			*)
				detail_message=""
				while IFS='|' read -r gpu_index gpu_model mig_state mig_layout; do
					if [[ "$gpu_index" == "$option" ]]; then
						detail_message="GPU $gpu_index\nModelo: $gpu_model\nMIG: $mig_state"
						if [[ "$mig_state" == "On" ]]; then
							detail_message+="\nInstancias: $mig_layout"
						fi
						break
					fi
				done <<< "$status_rows"

				if [[ -z "$detail_message" ]]; then
					detail_message="No se ha encontrado informacion para la GPU seleccionada."
				fi

				show_message "Detalle de GPU" "$detail_message"
				;;
		esac
	done
}

show_preset_load_menu() {
	show_message \
		"Carga de presets" \
		"Aqui ira la carga de presets de MIG.\n\nDe momento solo queda montado el flujo y el punto de entrada del submenu."
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
