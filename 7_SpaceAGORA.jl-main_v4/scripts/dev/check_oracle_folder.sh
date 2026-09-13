#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash scripts/dev/check_oracle_folder.sh /full/path/to/folder [ORACLE options]' \
        '' \
        'Tests a temporary project copy before and after excluding the folder.' \
        'The original folder is never moved or deleted. Julia and rsync are required.' \
        'Default workload: --orbits 0.02 --timeseries-points 21 (including plots).' \
        'Extra ORACLE options override these defaults. --output-dir is managed here.' \
        'Reports and logs are retained in a printed temporary directory.' \
        'Exit codes: 0 = not required for tested run; 1 = excluded run failed;' \
        '            2 = inconclusive or invalid input.'
}

if [[ $# -eq 0 || ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/../.." && pwd -P)
requested_folder=$1
shift

if [[ ! -d "$requested_folder" ]]; then
    printf 'INCONCLUSIVE: folder does not exist: %s\n' "$requested_folder" >&2
    exit 2
fi
folder=$(cd -- "$requested_folder" && pwd -P)
if [[ "$folder" != "$project_root/"* ]]; then
    printf 'INCONCLUSIVE: choose a subfolder of %s\n' "$project_root" >&2
    exit 2
fi
relative_folder=${folder#"$project_root/"}
case "$relative_folder" in
    .git|.git/*|output|output/*)
        printf 'INCONCLUSIVE: .git and generated output are not copied into this test.\n' >&2
        exit 2
        ;;
esac
for argument in "$@"; do
    case "$argument" in
        --output-dir|--output-dir=*|--help|-h)
            printf 'INCONCLUSIVE: option is reserved by the checker: %s\n' "$argument" >&2
            exit 2
            ;;
    esac
done
for executable in julia rsync; do
    if ! command -v "$executable" >/dev/null 2>&1; then
        printf 'INCONCLUSIVE: required executable is unavailable: %s\n' "$executable" >&2
        exit 2
    fi
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/oracle-folder-check.XXXXXXXX")
copy_root="$work_dir/project"
printf 'Folder: %s\nReport directory: %s\n' "$folder" "$work_dir"
printf 'Copying project (excluding Git metadata, generated output, and SpaceAGORA.so)...\n'
if ! rsync -aL --exclude=/.git --exclude=/output --exclude=/SpaceAGORA.so \
    "$project_root/" "$copy_root/"; then
    printf 'INCONCLUSIVE: could not copy the project. See %s\n' "$work_dir" >&2
    exit 2
fi
if [[ ! -d "$copy_root/$relative_folder" ]]; then
    printf 'INCONCLUSIVE: selected folder is absent from the baseline copy.\n' >&2
    exit 2
fi

oracle_options=(--orbits 0.02 --timeseries-points 21 "$@")
printf 'ORACLE options:'
printf ' %q' "${oracle_options[@]}"
printf '\nEach run loads source afresh; compilation can take several minutes.\n'

run_case() {
    local label=$1
    (
        cd -- "$copy_root"
        GKSwstype=100 julia --startup-file=no --compiled-modules=no --pkgimages=no \
            --project="$copy_root" -e '
                project_root = realpath(pwd())
                include(joinpath(project_root, "examples", "oracle_laser_links.jl"))
                @assert realpath(pathof(SpaceAGORA)) == realpath(joinpath(project_root, "src", "SpaceAGORA.jl")) "Wrong SpaceAGORA source loaded"
                options = _parse_options(ARGS)
                summary = main(ARGS)
                @assert string(summary.retcode) in ("Success", "Terminated") "Simulation did not succeed"
                results = DataFrame(Arrow.Table(summary.feather_path))
                @assert length(results.time) >= 2 "Insufficient saved samples"
                @assert all(isfinite, results.time) && issorted(results.time) "Invalid saved time grid"
                @assert results.time[end] >= 0.99 * options.orbits * summary.target_period_s "Simulation stopped early"
                for filename in ("dv_RTN.png", "altitude_vs_time.png", "delta_sma.png", "orbits_XY.png")
                    image = joinpath(summary.results_dir, "images", filename)
                    @assert isfile(image) && filesize(image) > 0 "Missing plot: $filename"
                end
                println("CHECKER_RUN_OK")
            ' -- "${oracle_options[@]}" --output-dir "$work_dir/$label-output"
    ) >"$work_dir/$label.log" 2>&1
}

printf 'Running baseline with the folder present...\n'
if ! run_case baseline; then
    printf 'INCONCLUSIVE: baseline failed; this cannot establish whether the folder is required.\n'
    printf 'Baseline log: %s/baseline.log\n' "$work_dir"
    head -n 10 "$work_dir/baseline.log"
    exit 2
fi

mv -- "$copy_root/$relative_folder" "$work_dir/excluded-folder"
printf 'Baseline passed. Running again with %s absent from the copy...\n' "$relative_folder"
if run_case excluded; then
    printf 'NOT REQUIRED for the tested ORACLE run: %s\n' "$folder"
    result_code=0
else
    printf 'REQUIRED FOR THE TESTED RUN: removing %s made the second run fail.\n' "$folder"
    printf 'Inspect the excluded log for the cause; unrelated transient failures can also cause a failure.\n'
    head -n 10 "$work_dir/excluded.log"
    result_code=1
fi
printf 'Logs: %s/baseline.log and %s/excluded.log\n' "$work_dir" "$work_dir"
printf 'This is an execution check, not a sandbox or proof for every configuration.\n'
printf 'It does not compare numerical equivalence or test fresh dependency installation.\n'
printf 'Shared installed dependencies remain available. Original folder unchanged.\n'
exit "$result_code"