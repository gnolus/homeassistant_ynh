#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

# App version
## yq is not a dependencie of yunohost package so tomlq command is not available
## (see https://github.com/YunoHost/yunohost/blob/dev/debian/control)
app_version=$(cat ../manifest.toml 2>/dev/null \
				| grep '^version = ' | cut -d '=' -f 2 \
				| cut -d '~' -f 1 | tr -d ' "') #2024.2.5

# Python required version
## jq is a dependencie of yunohost package
## (see https://github.com/YunoHost/yunohost/blob/dev/debian/control)
py_required_major=$(curl -Ls https://pypi.org/pypi/$app/$app_version/json \
						| jq -r '.info.requires_python' | cut -d '=' -f 2 \
						| rev | cut -d '.' -f2-  | rev) #3.11
py_required_version=$(curl -Ls https://www.python.org/ftp/python/ \
						| grep '>'$py_required_major  | cut -d '/' -f 2 \
						| cut -d '>' -f 2 | sort -rV | head -n 1) #3.11.8

# Fail2ban
failregex="^%(__prefix_line)s.*\[homeassistant.components.http.ban\] Login attempt or request with invalid authentication from.* \(<HOST>\).* Requested URL: ./auth/.*"

# Path
path_with_homeassistant="$install_dir/bin:$data_dir/bin:$PATH"

# Check if directory/file already exists (path in argument)
myynh_check_path () {
	[ -z "$1" ] && ynh_die "No argument supplied"
	[ ! -e "$1" ] || ynh_die "$1 already exists"
}

# Create directory only if not already exists (path in argument)
myynh_create_dir () {
	[ -z "$1" ] && ynh_die "No argument supplied"
	[ -d "$1" ] || mkdir -p "$1"
}

# Install specific python version
# usage: myynh_install_python --python="3.8.6"
# | arg: -p, --python=    - the python version to install
myynh_install_python () {
	# Declare an array to define the options of this helper.
	local legacy_args=u
	local -A args_array=( [p]=python= )
	local python
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	# Check python version from APT
	local py_apt_version=$(python3 --version | cut -d ' ' -f 2)

	# Usefull variables
	local python_major=${python%.*}

	# Check existing built version of python in /usr/local/bin
	if [ -e "/usr/local/bin/python$python_major" ]
	then
		local py_built_version=$(/usr/local/bin/python$python_major --version \
			| cut -d ' ' -f 2)
	else
		local py_built_version=0
	fi

	# Compare version
	if $(dpkg --compare-versions $py_apt_version ge $python)
	then
		# APT >= Required
		ynh_print_info "Using provided python3..."

		py_app_version="python3"

	else
		# Either python already built or to build

		if $(dpkg --compare-versions $py_built_version ge $python)
		then
			# Built >= Required
			ynh_print_info "Using already used python3 built version..."

			py_app_version="/usr/local/bin/python${py_built_version%.*}"

		else
			# APT < Minimal & Actual < Minimal => Build & install Python into /usr/local/bin
			ynh_print_info "Building python (may take a while)..."

			# Store current direcotry

			local MY_DIR=$(pwd)

			# Create a temp direcotry
			tmpdir="$(mktemp --directory)"
			cd "$tmpdir"

			# Download
			wget --output-document="Python-$python.tar.xz" \
				"https://www.python.org/ftp/python/$python/Python-$python.tar.xz" 2>&1

			# Extract
			tar xf "Python-$python.tar.xz"

			# Install
			cd "Python-$python"
			./configure --enable-optimizations
			ynh_hide_warnings make -j4
			ynh_hide_warnings make altinstall

			# Go back to working directory
			cd "$MY_DIR"

			# Clean
			ynh_safe_rm "$tmpdir"

			# Set version
			py_app_version="/usr/local/bin/python$python_major"
		fi
	fi
	# Save python version in settings

	ynh_app_setting_set --key=python --value="$python"
}

# Install/Upgrade Homeassistant in virtual environement
myynh_install_homeassistant () {
	# Requirements
	pip_required=$(curl -Ls https://pypi.org/pypi/$app/$app_version/json \
		| jq -r '.info.requires_dist[]' \
		| grep 'pip' \
		|| echo "pip" ) #pip (<23.1,>=21.0) if exist otherwise pip

	# Create the virtual environment
	ynh_exec_as_app $py_app_version -m venv --without-pip "$install_dir"

	# Run source in a 'sub shell'
	(
		# activate the virtual environment
		set +o nounset
		source "$install_dir/bin/activate"
		set -o nounset

		# add pip
		ynh_exec_as_app "$install_dir/bin/python3" -m ensurepip

		# install last version of pip
		ynh_hide_warnings ynh_exec_as_app "$install_dir/bin/pip3" --cache-dir "$data_dir/.cache" install --upgrade "$pip_required"

		# install last version of wheel
		ynh_hide_warnings ynh_exec_as_app "$install_dir/bin/pip3" --cache-dir "$data_dir/.cache" install --upgrade wheel

		# install last version of setuptools
		ynh_hide_warnings ynh_exec_as_app "$install_dir/bin/pip3" --cache-dir "$data_dir/.cache" install --upgrade setuptools

		# install last version of mysqlclient
		ynh_hide_warnings ynh_exec_as_app "$install_dir/bin/pip3" --cache-dir "$data_dir/.cache" install --upgrade mysqlclient

		# install Home Assistant
		ynh_hide_warnings ynh_exec_as_app "$install_dir/bin/pip3" --cache-dir "$data_dir/.cache" install --upgrade "$app==$app_version"
	)
}

# Upgrade the virtual environment directory
myynh_upgrade_venv_directory () {

	# Remove old python links before recreating them
	if [ -e "$install_dir/bin/" ]
	then
		find "$install_dir/bin/" -type l -name 'python*' \
			-exec bash -c 'rm --force "$1"' _ {} \;
	fi

	# Remove old python directories before recreating them
	if [ -e "$install_dir/lib/" ]
	then
		find "$install_dir/lib/" -mindepth 1 -maxdepth 1 -type d -name "python*" \
			-not -path "*/python${py_required_version%.*}" \
			-exec bash -c 'rm --force --recursive "$1"' _ {} \;
	fi
	if [ -e "$install_dir/include/site/" ]
	then
		find "$install_dir/include/site/" -mindepth 1 -maxdepth 1 -type d -name "python*" \
			-not -path "*/python${py_required_version%.*}" \
			-exec bash -c 'rm --force --recursive "$1"' _ {} \;
	fi

	# Upgrade the virtual environment directory
	ynh_exec_as_app $py_app_version -m venv --upgrade "$install_dir"
}

# Set permissions
myynh_set_permissions () {
	chown -R $app: "$install_dir"
	chmod u=rwX,g=rX,o= "$install_dir"
	chmod -R o-rwx "$install_dir"

	chown -R $app: "$data_dir"
	chmod u=rwX,g=rX,o= "$data_dir"
	chmod -R o-rwx "$data_dir"
	[ -e "$data_dir/bin/" ] && chmod -R +x "$data_dir/bin/"

	[ -e "$(dirname "$log_file")" ] && chown -R $app: "$(dirname "$log_file")"

	[ -e "/etc/sudoers.d/$app" ] && chown -R root: "/etc/sudoers.d/$app"

	# Upgade user groups
	user_groups=""
	[ $(getent group dialout) ] && user_groups="${user_groups} dialout"
	[ $(getent group gpio) ] && user_groups="${user_groups} gpio"
	[ $(getent group i2c) ] && user_groups="${user_groups} i2c"
	ynh_system_user_create --username="$app" --groups="$user_groups"
}
