#!/usr/bin/env bash
# Initialise the submodules of the repository at $1, shallow and in parallel,
# leaving out every submodule whose path matches an EXCLUDE pattern.
#
# Environment (all optional):
#   EXCLUDE    newline-separated globs over the path from the root; `*` also
#              matches `/`, and a pattern without `/` matches the last path
#              component at any depth (default: none)
#   RECURSIVE  `true` descends into submodules of submodules (default: true)
#   DEPTH      history depth of each submodule; 0 = full (default: 1)
#   JOBS       submodules cloned at once (default: 8)
#   TOKEN      sent to github.com as an HTTP header for this process only,
#              never written to any git config
#
# Submodules are added a level at a time: every parent of a level runs its
# `git submodule update` at once, each cloning up to JOBS submodules, and the
# submodules it added become the next level's parents. An excluded submodule
# stays an empty directory, and nothing beneath it is visited.
set -euo pipefail

root="$(cd "${1:?usage: $0 <repository dir>}" && pwd)"
recursive="${RECURSIVE:-true}"
depth="${DEPTH:-1}"
jobs="${JOBS:-8}"

patterns=()
while IFS= read -r line; do
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	[[ -n "${line}" ]] && patterns+=("${line}")
done <<<"${EXCLUDE:-}"

# Config for every git the updates spawn, through the environment so that it
# is gone when this script exits. In a container job the workspace belongs to
# the runner's user but git runs as root, so git refuses every repository in
# it as unsafe unless safe.directory says otherwise; actions/checkout does the
# same for its own calls.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="*"
if [[ -n "${TOKEN:-}" ]]; then
	basic="$(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')"
	echo "::add-mask::${basic}"
	export GIT_CONFIG_COUNT=2
	export GIT_CONFIG_KEY_1="http.https://github.com/.extraheader"
	export GIT_CONFIG_VALUE_1="AUTHORIZATION: basic ${basic}"
fi

excluded() {
	local rel="$1" pattern
	for pattern in "${patterns[@]+"${patterns[@]}"}"; do
		if [[ "${pattern}" == */* ]]; then
			# shellcheck disable=SC2053  # the pattern is a glob on purpose
			[[ "${rel}" == ${pattern} ]] && return 0
		else
			# shellcheck disable=SC2053
			[[ "${rel##*/}" == ${pattern} ]] && return 0
		fi
	done
	return 1
}

# .gitmodules can retain declarations after a gitlink is removed. Like a plain
# submodule update, only update paths the index actually records as gitlinks.
# NUL-delimited index entries preserve spaces and git's quoting-sensitive paths;
# the exact comparison prevents a directory containing a gitlink from matching.
is_gitlink() {
	local dir="$1" path="$2" entry
	while IFS= read -r -d '' entry; do
		if [[ "${entry%% *}" == 160000 && "${entry#*$'\t'}" == "${path}" ]]; then
			return 0
		fi
	done < <(git -C "${dir}" ls-files --stage -z -- ":(literal)${path}")
	return 1
}

# update <parent rel> <submodule path>...: clone the given submodules of one
# parent, at the commits it records.
update() {
	local parent="$1"
	shift
	local args=(submodule update --init --jobs "${jobs}")
	((depth > 0)) && args+=(--depth "${depth}")
	git -C "${root}/${parent}" "${args[@]}" -- "$@"
}

level=(.)
total=0
skipped=0
while ((${#level[@]})); do
	next=()
	pids=()
	for parent in "${level[@]}"; do
		dir="${root}/${parent}"
		[[ -f "${dir}/.gitmodules" ]] || continue
		wanted=()
		while read -r _ path; do
			is_gitlink "${dir}" "${path}" || continue
			rel="${path}"
			[[ "${parent}" != . ]] && rel="${parent}/${path}"
			if excluded "${rel}"; then
				echo "skip ${rel}"
				skipped=$((skipped + 1))
			else
				wanted+=("${path}")
				next+=("${rel}")
			fi
		done < <(git -C "${dir}" config --file .gitmodules --get-regexp '^submodule\..*\.path$' || true)
		((${#wanted[@]})) || continue
		total=$((total + ${#wanted[@]}))
		update "${parent}" "${wanted[@]}" &
		pids+=($!)
	done
	for pid in "${pids[@]+"${pids[@]}"}"; do
		wait "${pid}"
	done
	[[ "${recursive}" == true ]] || break
	level=("${next[@]+"${next[@]}"}")
done

echo "checked out ${total} submodules, skipped ${skipped}"
